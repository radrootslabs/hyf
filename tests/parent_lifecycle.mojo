"""Governed test-only POSIX process/pipe lifecycle and deadline helpers.

ADR-0012 D29, ADR-0014 D33 FX06/FX08 and ADR-0015 D35 LC01-LC06 require
*parent-enforced*, finite startup/read/write/wait deadlines, exception-safe
cleanup/reaping for provider fixture children and ``run_stdio_entrypoint``, a
truthful wait-error taxonomy, byte caps enforced inside each read chunk and a
non-opening numeric descriptor census. A child ``alarm(2)`` watchdog is
defense in depth, never the parent's lifecycle proof.

Mojo's ``std.os.Pipe`` wrapper does not expose stable raw descriptors for
``poll(2)``-based bounded I/O, so this module owns the required POSIX surface
directly. It is test-only tooling: it changes no HYF product policy.

Ownership rules:

* ``make_pipe``/``fork_pid`` create resources owned by the calling test.
* ``terminate_owned`` only signals a pid this process forked and has not yet
  reaped, so a reused PID can never be targeted by a repeated teardown.
* ``PipedChildState`` is the single shared mutable lifecycle record for one
  owned fixture child; every copy of a provider handle shares it, so cleanup is
  idempotent across the ``with`` manager, the body handle and repeated calls.
* No broad ``pkill``/name matching is performed anywhere.

This toolchain exposes ``std.ffi.get_errno``/``ErrNo``, so the wait-error
taxonomy classifies a negative ``waitpid`` by real ``EINTR`` (retain and
retry ownership), ``ECHILD`` (no waitable owned child remains) and every other
errno (``wait_error``, never completed cleanup).
"""

from std.collections import List
from std.ffi import (
    ErrNo,
    c_int,
    c_uint,
    c_ssize_t,
    c_size_t,
    external_call,
    get_errno,
)
from std.sys._libc import close
from std.time import perf_counter_ns


comptime WNOHANG: Int = 1
comptime POLLIN: Int = 1
comptime POLLOUT: Int = 4
comptime POLLERR: Int = 8
comptime POLLHUP: Int = 16
comptime POLLNVAL: Int = 32
comptime SIGALRM: Int = 14
comptime SIGPIPE: Int = 13
comptime SIGKILL: Int = 9
comptime SIGTERM: Int = 15
comptime SIG_IGN: Int = 1
comptime F_GETFD: Int = 1
comptime CENSUS_MAX_FDS: Int = 1048576

comptime FIXTURE_DEFAULT_DEADLINE_MS: Int = 20000
comptime TERMINATION_GRACE_MS: Int = 2000
comptime LIFECYCLE_POLL_SLICE_MS: Int = 25


def now_ms() -> Int:
    return Int(perf_counter_ns() // 1_000_000)


# ── Raw descriptor helpers ──────────────────────────────────────────────────


@fieldwise_init
struct PipeFds(Copyable, Movable):
    var read_fd: Int
    var write_fd: Int

    def __copyinit__(out self, existing: Self):
        self.read_fd = existing.read_fd
        self.write_fd = existing.write_fd


@fieldwise_init
struct PipeTriple(Copyable, Movable):
    var stdin_pipe: PipeFds
    var stdout_pipe: PipeFds
    var stderr_pipe: PipeFds

    def __copyinit__(out self, existing: Self):
        self.stdin_pipe = existing.stdin_pipe.copy()
        self.stdout_pipe = existing.stdout_pipe.copy()
        self.stderr_pipe = existing.stderr_pipe.copy()


def close_pipe(pipe: PipeFds):
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)


def make_three_pipes(inject_fail_after: Int = -1) raises -> PipeTriple:
    """Create three owned pipes, closing earlier ones if any creation fails.

    ``inject_fail_after`` is a test-only control: when >= 0 a failure is
    raised after that many successful pipes. The injected failure and a real
    ``make_pipe`` failure share the same rollback handler.
    """
    var fds = InlineArray[Int, 6](fill=-1)
    try:
        for index in range(3):
            if inject_fail_after >= 0 and index == inject_fail_after:
                raise Error("lifecycle: injected pipe creation failure")
            var pipe = make_pipe()
            fds[index * 2] = pipe.read_fd
            fds[index * 2 + 1] = pipe.write_fd
    except:
        for slot in range(6):
            close_fd(fds[slot])
        raise
    return PipeTriple(
        PipeFds(fds[0], fds[1]),
        PipeFds(fds[2], fds[3]),
        PipeFds(fds[4], fds[5]),
    )


def fork_owned_or_close(
    pipe: PipeFds, inject_failure: Bool = False
) raises -> Int:
    """Fork the owned child, closing both pipe ends if the fork fails.

    A real ``fork`` failure and the test-only injected failure share the same
    rollback handler, so partial-startup cleanup is execution-proven.
    """
    try:
        if inject_failure:
            raise Error("lifecycle: injected fork failure")
        return fork_pid()
    except:
        close_pipe(pipe.copy())
        raise
    return -1


def fork_owned_or_close3(
    pipes: PipeTriple, inject_failure: Bool = False
) raises -> Int:
    """Fork the stdio child, closing all three pipe pairs if the fork fails."""
    try:
        if inject_failure:
            raise Error("lifecycle: injected fork failure")
        return fork_pid()
    except:
        close_pipe(pipes.stdin_pipe.copy())
        close_pipe(pipes.stdout_pipe.copy())
        close_pipe(pipes.stderr_pipe.copy())
        raise
    return -1


def ignore_sigpipe():
    """Ignore SIGPIPE so a peer-close race surfaces as EPIPE, not parent death.

    Inherited across ``fork``, so owned fixture children get the same bounded
    write-failure behaviour instead of dying on an interrupted report write.
    """
    _ = external_call["signal", Int](c_int(SIGPIPE), c_int(SIG_IGN))


def make_pipe() raises -> PipeFds:
    ignore_sigpipe()
    var fds = InlineArray[c_int, 2](fill=0)
    if Int(external_call["pipe", c_int](fds.unsafe_ptr())) != 0:
        raise Error("lifecycle: pipe failed")
    return PipeFds(Int(fds[0]), Int(fds[1]))


def close_fd(fd: Int):
    if fd >= 0:
        _ = close(c_int(fd))


def fork_pid() raises -> Int:
    var pid = Int(external_call["fork", c_int]())
    if pid < 0:
        raise Error("lifecycle: fork failed")
    return pid


def child_exit(code: Int):
    _ = external_call["_exit", c_int](c_int(code))


def dup2_fd(oldfd: Int, newfd: Int) -> Int:
    return Int(external_call["dup2", c_int](c_int(oldfd), c_int(newfd)))


def kill_pid(pid: Int, sig: Int) -> Int:
    return Int(external_call["kill", c_int](c_int(pid), c_int(sig)))


def owned_pid() -> Int:
    return Int(external_call["getpid", c_int]())


def set_alarm(seconds: Int) -> Int:
    return Int(external_call["alarm", c_uint](c_uint(seconds)))


def sleep_ms(ms: Int):
    if ms > 0:
        _ = external_call["usleep", c_int](c_int(ms * 1000))


def poll_fd(fd: Int, events: Int, timeout_ms: Int) -> Int:
    """Poll one descriptor.

    Returns the ``revents`` mask, ``0`` on timeout and ``-1`` on a real
    ``poll(2)`` error so callers can distinguish a read-phase error from an
    ordinary timeout instead of collapsing both to ``0``.
    """
    var cell = InlineArray[Int32, 2](fill=0)
    cell[0] = Int32(fd)
    cell[1] = Int32(events)
    var n = Int(
        external_call["poll", c_int](
            cell.unsafe_ptr(), c_uint(1), c_int(timeout_ms)
        )
    )
    if n < 0:
        return -1
    if n == 0:
        return 0
    return (Int(cell[1]) >> 16) & 0xFFFF


@fieldwise_init
struct PollThree(Movable):
    """Bounded three-descriptor ``poll(2)`` result; ``count`` is -1 on error."""

    var count: Int
    var r0: Int
    var r1: Int
    var r2: Int


def poll_three(
    fd0: Int,
    events0: Int,
    fd1: Int,
    events1: Int,
    fd2: Int,
    events2: Int,
    timeout_ms: Int,
) -> PollThree:
    """Poll exactly three descriptors with one finite timeout."""
    var cell = InlineArray[Int32, 12](fill=0)
    cell[0] = Int32(fd0)
    cell[1] = Int32(events0)
    cell[2] = Int32(fd1)
    cell[3] = Int32(events1)
    cell[4] = Int32(fd2)
    cell[5] = Int32(events2)
    var n = Int(
        external_call["poll", c_int](
            cell.unsafe_ptr(), c_uint(3), c_int(timeout_ms)
        )
    )
    if n < 0:
        return PollThree(-1, 0, 0, 0)
    if n == 0:
        return PollThree(0, 0, 0, 0)
    return PollThree(
        n,
        (Int(cell[1]) >> 16) & 0xFFFF,
        (Int(cell[3]) >> 16) & 0xFFFF,
        (Int(cell[5]) >> 16) & 0xFFFF,
    )


def read_fd(fd: Int, buf: UnsafePointer[Byte, ...], max_bytes: Int) -> Int:
    while True:
        var n = Int(
            external_call["read", c_ssize_t](fd, buf, c_size_t(max_bytes))
        )
        if n >= 0 or get_errno() != ErrNo.EINTR:
            return n


def _write_fd(fd: Int, ptr: UnsafePointer[UInt8, ...], n: Int) -> Int:
    while True:
        var written = Int(
            external_call["write", c_ssize_t](fd, ptr, c_size_t(n))
        )
        if written >= 0 or get_errno() != ErrNo.EINTR:
            return written


def write_raw(fd: Int, text: String) -> Int:
    """Best-effort blocking write of a small bounded string (no deadline)."""
    var n = _write_fd(fd, text.as_bytes().unsafe_ptr(), text.byte_length())
    return n


def write_raw_bytes(fd: Int, bytes: List[UInt8]) -> Int:
    """Best-effort blocking write of raw bytes (test-only split controls)."""
    if len(bytes) == 0:
        return 0
    return _write_fd(fd, bytes.unsafe_ptr(), len(bytes))


comptime WRITE_CHUNK_BYTES: Int = 512


def write_fd_bounded(fd: Int, data: String, deadline_ms: Int) -> String:
    """Write ``data`` with a parent-enforced deadline.

    Chunks are capped at ``PIPE_BUF``-safe size so a ``POLLOUT`` readiness
    never lets a blocking write stall past the deadline. Returns ``""`` on
    success or a bounded reason such as ``write_deadline_expired`` /
    ``write_pipe_closed``.
    """
    var total = data.byte_length()
    var sent = 0
    var start = now_ms()
    while sent < total:
        if now_ms() - start >= deadline_ms:
            return "write_deadline_expired"
        var ev = poll_fd(fd, POLLOUT, LIFECYCLE_POLL_SLICE_MS)
        if ev < 0:
            return "write_poll_error"
        if ev == 0:
            continue
        if (ev & (POLLERR | POLLHUP | POLLNVAL)) != 0:
            return "write_pipe_closed"
        var chunk = min(WRITE_CHUNK_BYTES, total - sent)
        var slice = data[byte = sent : sent + chunk]
        var n = _write_fd(fd, slice.as_bytes().unsafe_ptr(), chunk)
        if n <= 0:
            return "write_failed"
        sent += n
    return ""


@fieldwise_init
struct ChunkWrite(Movable):
    var reason: String
    var written: Int


def write_fd_chunk(fd: Int, data: String, offset: Int) -> ChunkWrite:
    """Write one ``PIPE_BUF``-safe chunk after a readiness poll.

    Returns the bounded failure reason and the bytes actually written so a
    caller can interleave writing with draining other descriptors.
    """
    var total = data.byte_length()
    if offset >= total:
        return ChunkWrite("", 0)
    var chunk = min(WRITE_CHUNK_BYTES, total - offset)
    var slice = data[byte = offset : offset + chunk]
    var n = _write_fd(fd, slice.as_bytes().unsafe_ptr(), chunk)
    if n <= 0:
        return ChunkWrite("write_failed", 0)
    return ChunkWrite("", n)


# ── Bounded line reader with surplus retention ──────────────────────────────


@fieldwise_init
struct BoundedLineReader(Movable):
    """Byte-bounded, deadline-bounded line reader that never discards surplus.

    The byte cap is enforced *inside* every read chunk, so a coalesced chunk of
    ``ready`` + ``report`` lines cannot smuggle an oversized line past the cap
    and bytes after a returned newline stay available to the next reader call.
    """

    var fd: Int
    var max_bytes: Int
    var _pending: List[UInt8]
    var _pos: Int
    var _eof: Bool
    var _closed: Bool

    def __init__(out self, fd: Int, max_bytes: Int):
        self.fd = fd
        self.max_bytes = max_bytes
        self._pending = List[UInt8]()
        self._pos = 0
        self._eof = False
        self._closed = False

    def close(mut self):
        if not self._closed:
            close_fd(self.fd)
            self._closed = True

    def has_pending(self) -> Bool:
        return self._pos < len(self._pending)

    def _compact(mut self):
        if self._pos == 0:
            return
        if self._pos >= len(self._pending):
            self._pending = List[UInt8]()
            self._pos = 0
            return
        var rest = List[UInt8]()
        for index in range(self._pos, len(self._pending)):
            rest.append(self._pending[index])
        self._pending = rest^
        self._pos = 0

    def _take_available(mut self, mut out: List[UInt8], stop: Int):
        for index in range(self._pos, stop):
            out.append(self._pending[index])

    def read_line(mut self, deadline_ms: Int) raises -> String:
        """Read one newline-terminated line with bounded size and deadline.

        Raises ``ready_output_overflow`` once the line exceeds ``max_bytes``
        and ``read_deadline_expired`` when the deadline elapses first. EOF
        before a newline returns the bytes read so far (possibly empty).
        """
        var out = List[UInt8]()
        var start = now_ms()
        while True:
            var found = -1
            for index in range(self._pos, len(self._pending)):
                if Int(self._pending[index]) == 10:
                    found = index
                    break
            if found >= 0:
                self._take_available(out, found)
                self._pos = found + 1
                self._compact()
                if len(out) > self.max_bytes:
                    raise Error("ready_output_overflow")
                return bytes_to_string(out)
            self._take_available(out, len(self._pending))
            self._pos = len(self._pending)
            self._compact()
            if len(out) > self.max_bytes:
                raise Error("ready_output_overflow")
            if self._eof:
                return bytes_to_string(out)
            if now_ms() - start >= deadline_ms:
                raise Error("read_deadline_expired")
            var ev = poll_fd(self.fd, POLLIN, LIFECYCLE_POLL_SLICE_MS)
            if ev < 0:
                raise Error("read_error")
            if ev == 0:
                continue
            var buf = InlineArray[Byte, 512](fill=0)
            var n = read_fd(self.fd, buf.unsafe_ptr(), 512)
            if n < 0:
                raise Error("read_error")
            if n == 0:
                self._eof = True
                continue
            for index in range(n):
                self._pending.append(UInt8(Int(buf[index])))


def read_line_bounded(
    fd: Int, max_bytes: Int, deadline_ms: Int
) raises -> String:
    """One-shot bounded line read for callers without surplus to preserve."""
    var reader = BoundedLineReader(fd, max_bytes)
    return reader.read_line(deadline_ms)


def read_all_bounded(
    fd: Int, max_bytes: Int, deadline_ms: Int
) raises -> String:
    """Read until EOF, with a bounded size cap and parent deadline.

    Raises ``stdout_overflow`` when the cap is exceeded and
    ``read_deadline_expired`` when the deadline elapses first.
    """
    var out = List[UInt8]()
    var buf = InlineArray[Byte, 4096](fill=0)
    var start = now_ms()
    while True:
        if now_ms() - start >= deadline_ms:
            raise Error("read_deadline_expired")
        var ev = poll_fd(fd, POLLIN, LIFECYCLE_POLL_SLICE_MS)
        if ev < 0:
            raise Error("read_error")
        if ev == 0:
            continue
        var n = read_fd(fd, buf.unsafe_ptr(), 4096)
        if n < 0:
            raise Error("read_error")
        if n == 0:
            break
        if len(out) + n > max_bytes:
            raise Error("stdout_overflow")
        for index in range(n):
            out.append(UInt8(Int(buf[index])))
    return bytes_to_string(out)


def bytes_to_string(bytes: List[UInt8]) raises -> String:
    if len(bytes) == 0:
        return ""
    return String(from_utf8=Span(ptr=bytes.unsafe_ptr(), length=len(bytes)))


def _utf8_line(bytes: List[UInt8]) raises -> String:
    """Decode a complete line as UTF-8, or fail with a bounded cause."""
    try:
        return bytes_to_string(bytes)
    except:
        raise Error("invalid_utf8")


struct CleanupLedger(Copyable, Movable):
    """Caller-owned record of owned-child cleanup failures.

    The ledger is deliberately *not* owned by the handle: an unproved cleanup
    stays observable after the owning ``with`` block ends and the handle is
    destroyed, because the calling test keeps the ``List`` and can assert it
    is empty. A default-constructed ``CleanupLedger`` is inert.
    """

    var errors: Optional[UnsafePointer[List[String], MutAnyOrigin]]

    def __init__(out self):
        self.errors = None

    def __init__(out self, errors: UnsafePointer[List[String], MutAnyOrigin]):
        self.errors = errors

    def record(self, text: String):
        if self.errors:
            self.errors.value()[].append(text)

    def count(self) -> Int:
        if self.errors:
            return len(self.errors.value()[])
        return -1

    def last(self) -> String:
        if self.errors:
            var recorded = self.errors.value()[]
            if len(recorded) > 0:
                return String(recorded[len(recorded) - 1])
        return ""


# ── Child lifecycle ─────────────────────────────────────────────────────────


@fieldwise_init
struct ProcessStatus(Copyable, Movable):
    var state: String
    var exited: Bool
    var exit_code: Int
    var signal: Int
    var raw: Int
    var error: String

    def __copyinit__(out self, existing: Self):
        self.state = existing.state
        self.exited = existing.exited
        self.exit_code = existing.exit_code
        self.signal = existing.signal
        self.raw = existing.raw
        self.error = existing.error

    def reaped(self) -> Bool:
        return self.state == "reaped"

    def cleanup_proved(self) -> Bool:
        """True only when no waitable owned child can remain for this pid."""
        return self.state == "reaped" or self.state == "gone"

    def describe(self) -> String:
        if self.state != "reaped":
            if self.error != "":
                return self.state + ":" + self.error
            return self.state
        if self.exited:
            return "exited=" + String(self.exit_code)
        return "signal=" + String(self.signal)


def _decode_status(raw: Int) -> ProcessStatus:
    var low = raw & 0x7F
    if low == 0:
        return ProcessStatus("reaped", True, (raw >> 8) & 0xFF, 0, raw, "")
    if low == 0x7F:
        return ProcessStatus("stopped", False, -1, 0, raw, "")
    return ProcessStatus("reaped", False, -1, low, raw, "")


def classify_wait_errno(errno_value: Int) -> String:
    """Map a real ``waitpid`` errno to the ownership taxonomy.

    ``interrupted`` (EINTR) retains ownership and is retried; ``gone``
    (ECHILD) proves no waitable child remains; anything else is
    ``wait_error`` and must never be reported as completed cleanup.
    """
    if errno_value == Int(ErrNo.EINTR.value):
        return "interrupted"
    if errno_value == Int(ErrNo.ECHILD.value):
        return "gone"
    return "wait_error"


def wait_nohang(pid: Int) -> ProcessStatus:
    """Non-blocking wait with an exact errno ownership taxonomy.

    ``reaped``/``running`` are exact. A negative ``waitpid`` is classified by
    the real errno: ``EINTR`` retains ownership and is retried by callers;
    ``ECHILD`` proves no waitable child remains; any other error is a
    ``wait_error`` that must not be reported as completed cleanup. A
    non-positive pid is never waited on.
    """
    if pid <= 0:
        return ProcessStatus("wait_error", False, -1, 0, -1, "invalid_pid")
    var status = InlineArray[c_int, 1](fill=0)
    var r = Int(
        external_call["waitpid", c_int](
            c_int(pid), status.unsafe_ptr(), c_int(WNOHANG)
        )
    )
    if r == pid:
        return _decode_status(Int(status[0]))
    if r == 0:
        return ProcessStatus("running", False, -1, 0, 0, "")
    var errno_value = Int(get_errno().value)
    var klass = classify_wait_errno(errno_value)
    if klass == "gone":
        return ProcessStatus("gone", False, -1, -1, -1, "")
    return ProcessStatus(
        klass, False, -1, 0, -1, "errno_" + String(errno_value)
    )


def wait_bounded(pid: Int, deadline_ms: Int) -> ProcessStatus:
    var start = now_ms()
    while True:
        var st = wait_nohang(pid)
        if st.state != "running" and st.state != "interrupted":
            return st^
        if now_ms() - start >= deadline_ms:
            return st^
        sleep_ms(5)


def terminate_owned(pid: Int, grace_ms: Int) -> ProcessStatus:
    """Reap a child this test owns, escalating SIGTERM -> SIGKILL.

    A pid already reaped or not waitable (``gone``) is never signaled, so a
    reused PID from an unrelated process can never be targeted. An
    ``interrupted``/``wait_error`` status still owns a live child, so it is
    signaled and reaped; the returned status is only ``reaped`` when the child
    was actually collected.
    """
    var st = wait_nohang(pid)
    if st.cleanup_proved():
        return st^
    if st.state == "wait_error":
        # Identity/ownership is unproved; never signal and never claim cleanup.
        return st^
    _ = kill_pid(pid, SIGTERM)
    st = wait_bounded(pid, grace_ms)
    if st.state == "running" or st.state == "interrupted":
        _ = kill_pid(pid, SIGKILL)
        st = wait_bounded(pid, grace_ms)
    return st^


def pid_not_waitable(pid: Int) -> Bool:
    """True when ``pid`` is neither running nor an unreaped zombie of ours.

    Used only to evidence, after ``terminate_owned`` reaped a specific owned
    child, that the same pid is no longer waitable. It never reaps a pid this
    test did not fork and never scans by process name.
    """
    return wait_nohang(pid).state == "gone"


# ── Shared owned-child lifecycle state ──────────────────────────────────────


@fieldwise_init
struct PipedChildState(Movable):
    """Single mutable lifecycle record shared by every copy of one handle.

    Retained read surplus is an undecoded byte buffer, so a chunk that splits a
    multi-byte character is preserved without raising on an incomplete UTF-8
    fragment. ``last_terminated`` records whether the most recent line ended
    with a newline, so a truncated report can never be read as complete.
    ``ledger`` is the caller-owned record of cleanup failures.
    """

    var pid: Int
    var report_fd: Int
    var pending: List[UInt8]
    var eof: Bool
    var closed: Bool
    var deadline_ms: Int
    var expected_requests: Int
    var reaped: Bool
    var ok: Bool
    var phase: String
    var case_label: String
    var reason: String
    var requests: Int
    var connections: Int
    var cleanup_error: String
    var status: ProcessStatus
    var observed: ProcessStatus
    var observed_valid: Bool
    var last_terminated: Bool
    var spawn_ms: Int
    var ledger: CleanupLedger

    def store(
        mut self,
        ok: Bool,
        phase: String,
        case_label: String,
        reason: String,
        requests: Int,
        connections: Int,
    ):
        self.ok = ok
        self.phase = String(phase)
        self.case_label = String(case_label)
        self.reason = String(reason)
        self.requests = requests
        self.connections = connections

    def close_reader(mut self):
        if not self.closed:
            close_fd(self.report_fd)
            self.closed = True

    def read_line(mut self, max_bytes: Int, deadline_ms: Int) raises -> String:
        """Bounded line read that retains surplus as undecoded bytes.

        The byte cap is enforced inside every read chunk (including a newline
        in the same chunk) and bytes after the returned newline stay buffered
        for the next consumer. ``last_terminated`` reports whether the returned
        line ended with a newline. Raises ``ready_output_overflow`` past the cap,
        ``read_deadline_expired`` on the read deadline, ``read_error`` for a
        real read/poll failure (never conflated with EOF) and ``invalid_utf8``
        for a line that is not valid UTF-8.
        """
        var line = List[UInt8]()
        var start = now_ms()
        self.last_terminated = False
        while True:
            var found = -1
            for index in range(len(self.pending)):
                if Int(self.pending[index]) == 10:
                    found = index
                    break
            if found >= 0:
                for index in range(found):
                    line.append(self.pending[index])
                var rest = List[UInt8]()
                for index in range(found + 1, len(self.pending)):
                    rest.append(self.pending[index])
                self.pending = rest^
                if len(line) > max_bytes or len(self.pending) > max_bytes:
                    raise Error("ready_output_overflow")
                self.last_terminated = True
                return _utf8_line(line^)
            for index in range(len(self.pending)):
                line.append(self.pending[index])
            self.pending = List[UInt8]()
            if len(line) > max_bytes:
                raise Error("ready_output_overflow")
            if self.eof:
                return _utf8_line(line^)
            if now_ms() - start >= deadline_ms:
                raise Error("read_deadline_expired")
            var ev = poll_fd(self.report_fd, POLLIN, LIFECYCLE_POLL_SLICE_MS)
            if ev < 0:
                raise Error("read_error")
            if ev == 0:
                continue
            var buf = InlineArray[Byte, 512](fill=0)
            var n = read_fd(self.report_fd, buf.unsafe_ptr(), 512)
            if n < 0:
                raise Error("read_error")
            if n == 0:
                self.eof = True
                continue
            for index in range(n):
                self.pending.append(UInt8(Int(buf[index])))

    def drain_surplus(mut self, max_bytes: Int, deadline_ms: Int) raises -> Int:
        """Consume every byte after the last returned line, through EOF.

        A real report is exactly one newline-terminated line, so any surplus
        byte is a duplicate or trailing report regardless of chunk alignment.
        A read/poll failure is a distinct cause and never a clean end of
        stream.
        """
        var total = len(self.pending)
        self.pending = List[UInt8]()
        if total > max_bytes:
            raise Error("ready_output_overflow")
        var start = now_ms()
        while not self.eof:
            if now_ms() - start >= deadline_ms:
                raise Error("read_deadline_expired")
            var ev = poll_fd(self.report_fd, POLLIN, LIFECYCLE_POLL_SLICE_MS)
            if ev < 0:
                raise Error("read_error")
            if ev == 0:
                continue
            var buf = InlineArray[Byte, 1024](fill=0)
            var n = read_fd(self.report_fd, buf.unsafe_ptr(), 1024)
            if n < 0:
                raise Error("read_error")
            if n == 0:
                self.eof = True
                continue
            total += n
            if total > max_bytes:
                raise Error("ready_output_overflow")
        return total


def piped_child_state(
    pid: Int,
    report_fd: Int,
    deadline_ms: Int,
    expected_requests: Int,
    ledger: CleanupLedger,
) -> PipedChildState:
    """Build one owned-child lifecycle record with explicit ownership truth."""
    return PipedChildState(
        pid=pid,
        report_fd=report_fd,
        pending=List[UInt8](),
        eof=False,
        closed=False,
        deadline_ms=deadline_ms,
        expected_requests=expected_requests,
        reaped=False,
        ok=False,
        phase="pending",
        case_label="-",
        reason="not_reaped",
        requests=0,
        connections=0,
        cleanup_error="",
        status=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed_valid=False,
        last_terminated=False,
        spawn_ms=now_ms(),
        ledger=ledger.copy(),
    )


def parse_ready_line(line: String, max_bytes: Int) raises -> Int:
    """Parse the exact ``ready <port>`` grammar with a valid TCP port range."""
    if line.byte_length() == 0:
        raise Error("ready_empty")
    if line.byte_length() > max_bytes:
        raise Error("ready_too_large")
    if not line.startswith("ready "):
        raise Error("ready_grammar")
    var digits = String(line[byte=6:])
    if digits.byte_length() == 0:
        raise Error("ready_missing_port")
    if digits.byte_length() > 5:
        raise Error("ready_port_range")
    for byte in digits.as_bytes():
        var b = Int(byte)
        if b < 48 or b > 57:
            raise Error("ready_non_digit")
    var port = Int(digits)
    if port < 1 or port > 65535:
        raise Error("ready_port_range")
    return port


# ── Non-opening descriptor census ───────────────────────────────────────────


def parse_ready_or_cleanup(
    pid: Int, line: String, max_bytes: Int
) raises -> Int:
    """Parse exact readiness or terminate and prove the owned child is gone.

    Gives malformed readiness a real cleanup path with a bounded cause carrying
    the offending line and the owned child's reap result.
    """
    try:
        return parse_ready_line(line, max_bytes)
    except e:
        var status = terminate_owned(pid, TERMINATION_GRACE_MS)
        raise Error(
            "ready_invalid:"
            + String(e)
            + " report="
            + line
            + " child="
            + status.describe()
            + " cleanup="
            + ("proved" if status.cleanup_proved() else "unreaped")
        )


def descriptor_census(limit: Int) -> Int:
    """Count open descriptors numerically via ``fcntl(F_GETFD)``.

    Never opens a target path, so device nodes cannot block it and sockets and
    high descriptors are counted the same as regular files. Returns -1 when the
    census cannot be established (invalid bound or no standard descriptors),
    which callers must treat as a failed unavailable census, never a pass.
    """
    if limit <= 0:
        return -1
    var count = 0
    for fd in range(0, limit):
        while True:
            var rc = Int(
                external_call["fcntl", c_int](c_int(fd), c_int(F_GETFD))
            )
            if rc >= 0:
                count += 1
                break
            if get_errno() == ErrNo.EINTR:
                continue
            break
    if count == 0:
        return -1
    return count


def fd_scan_limit() -> Int:
    """Return the OS descriptor-table size, or -1 when unavailable.

    The raw size is returned; callers decide whether complete coverage inside
    the admitted range is possible rather than silently truncating the scan.
    """
    var n = Int(external_call["getdtablesize", c_int]())
    if n <= 0:
        return -1
    return n


def open_fd_count() -> Int:
    """Numeric open-descriptor census for this process (-1 if unavailable)."""
    var limit = fd_scan_limit()
    if limit <= 0 or limit > CENSUS_MAX_FDS:
        return -1
    return descriptor_census(limit)


def open_fd_count_checked(limit: Int = -1) raises -> Int:
    """Checked census that fails explicitly when coverage cannot be complete.

    ``limit`` defaults to the OS descriptor-table size. A nonpositive,
    oversized or otherwise unavailable census raises
    ``descriptor_census_unavailable`` rather than returning a partial count
    that a caller could read as a pass.
    """
    var effective = limit
    if effective < 0:
        effective = fd_scan_limit()
    if effective <= 0 or effective > CENSUS_MAX_FDS:
        raise Error("descriptor_census_unavailable")
    var count = descriptor_census(effective)
    if count < 0:
        raise Error("descriptor_census_unavailable")
    return count
