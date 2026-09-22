"""Governed test-only POSIX process/pipe lifecycle and deadline helpers.

ADR-0014 D33 FX06/FX08 require *parent-enforced*, finite startup/read/write/
wait deadlines and exception-safe cleanup/reaping for provider fixture
children and ``run_stdio_entrypoint``. A child ``alarm(2)`` watchdog is
defense in depth, never the parent's lifecycle proof.

Mojo's ``std.os.Pipe`` wrapper does not expose stable raw descriptors for
``poll(2)``-based bounded I/O, so this module owns the required POSIX surface
directly. It is test-only tooling: it changes no HYF product policy.

Ownership rules:

* ``make_pipe``/``fork_pid`` create resources owned by the calling test.
* ``terminate_owned`` only signals a pid this process forked and has not yet
  reaped, so a reused PID can never be targeted by a repeated teardown.
* No broad ``pkill``/name matching is performed anywhere.
"""

from std.ffi import c_int, c_uint, c_ssize_t, c_size_t, external_call
from std.sys._libc import close
from std.time import perf_counter_ns


comptime WNOHANG: Int = 1
comptime POLLIN: Int = 1
comptime POLLOUT: Int = 4
comptime POLLERR: Int = 8
comptime POLLHUP: Int = 16
comptime POLLNVAL: Int = 32
comptime SIGALRM: Int = 14
comptime SIGKILL: Int = 9
comptime SIGTERM: Int = 15

comptime FIXTURE_DEFAULT_DEADLINE_MS: Int = 20000
comptime TERMINATION_GRACE_MS: Int = 2000
comptime LIFECYCLE_POLL_SLICE_MS: Int = 25


def now_ms() -> Int:
    return Int(perf_counter_ns() // 1_000_000)


# ── Raw descriptor helpers ──────────────────────────────────────────────────


@fieldwise_init
struct PipeFds(Movable):
    var read_fd: Int
    var write_fd: Int


def make_pipe() raises -> PipeFds:
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
    var cell = InlineArray[Int32, 2](fill=0)
    cell[0] = Int32(fd)
    cell[1] = Int32(events)
    var n = Int(
        external_call["poll", c_int](
            cell.unsafe_ptr(), c_uint(1), c_int(timeout_ms)
        )
    )
    if n <= 0:
        return 0
    return (Int(cell[1]) >> 16) & 0xFFFF


def read_fd(fd: Int, buf: UnsafePointer[Byte, ...], max_bytes: Int) -> Int:
    return Int(external_call["read", c_ssize_t](fd, buf, c_size_t(max_bytes)))


def _write_fd(fd: Int, ptr: UnsafePointer[UInt8, ...], n: Int) -> Int:
    return Int(external_call["write", c_ssize_t](fd, ptr, c_size_t(n)))


def write_raw(fd: Int, text: String) -> Int:
    """Best-effort blocking write of a small bounded string (no deadline)."""
    var n = _write_fd(fd, text.as_bytes().unsafe_ptr(), text.byte_length())
    return n


def write_fd_bounded(fd: Int, data: String, deadline_ms: Int) -> String:
    """Write ``data`` with a parent-enforced deadline.

    Returns ``""`` on success or a bounded reason such as
    ``write_deadline_expired`` / ``write_pipe_closed``.
    """
    var total = data.byte_length()
    var sent = 0
    var start = now_ms()
    while sent < total:
        if now_ms() - start >= deadline_ms:
            return "write_deadline_expired"
        var ev = poll_fd(fd, POLLOUT, LIFECYCLE_POLL_SLICE_MS)
        if ev == 0:
            continue
        if (ev & (POLLERR | POLLHUP | POLLNVAL)) != 0:
            return "write_pipe_closed"
        var chunk = min(4096, total - sent)
        var slice = data[byte = sent : sent + chunk]
        var n = _write_fd(fd, slice.as_bytes().unsafe_ptr(), chunk)
        if n <= 0:
            return "write_failed"
        sent += n
    return ""


def read_line_bounded(
    fd: Int, max_bytes: Int, deadline_ms: Int
) raises -> String:
    """Read one newline-terminated line with bounded size and deadline.

    Raises on overflow or deadline. An EOF before a newline returns whatever
    bytes were read (possibly empty).
    """
    var out = List[UInt8]()
    var buf = InlineArray[Byte, 512](fill=0)
    var start = now_ms()
    while True:
        if len(out) >= max_bytes:
            raise Error("ready_output_overflow")
        if now_ms() - start >= deadline_ms:
            raise Error("read_deadline_expired")
        var ev = poll_fd(fd, POLLIN, LIFECYCLE_POLL_SLICE_MS)
        if ev == 0:
            continue
        var n = read_fd(fd, buf.unsafe_ptr(), 512)
        if n <= 0:
            break
        for index in range(n):
            if Int(buf[index]) == 10:
                return _bytes_to_string(out)
            out.append(UInt8(Int(buf[index])))
    return _bytes_to_string(out)


def drain_fd_bounded(
    fd: Int, max_bytes: Int, deadline_ms: Int
) raises -> String:
    """Read available bytes up to ``max_bytes`` under deadline."""
    var out = List[UInt8]()
    var buf = InlineArray[Byte, 1024](fill=0)
    var start = now_ms()
    while len(out) < max_bytes:
        if now_ms() - start >= deadline_ms:
            break
        var ev = poll_fd(fd, POLLIN, LIFECYCLE_POLL_SLICE_MS)
        if ev == 0:
            continue
        var n = read_fd(fd, buf.unsafe_ptr(), 1024)
        if n <= 0:
            break
        for index in range(n):
            out.append(UInt8(Int(buf[index])))
    return _bytes_to_string(out)


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
        if ev == 0:
            continue
        var n = read_fd(fd, buf.unsafe_ptr(), 4096)
        if n <= 0:
            break
        if len(out) + n > max_bytes:
            raise Error("stdout_overflow")
        for index in range(n):
            out.append(UInt8(Int(buf[index])))
    return _bytes_to_string(out)


def _bytes_to_string(bytes: List[UInt8]) raises -> String:
    if len(bytes) == 0:
        return ""
    return String(from_utf8=Span(ptr=bytes.unsafe_ptr(), length=len(bytes)))


# ── Child lifecycle ─────────────────────────────────────────────────────────


@fieldwise_init
struct ProcessStatus(Movable):
    var state: String
    var exited: Bool
    var exit_code: Int
    var signal: Int
    var raw: Int

    def reaped(self) -> Bool:
        return self.state == "reaped"

    def describe(self) -> String:
        if self.state != "reaped":
            return self.state
        if self.exited:
            return "exited=" + String(self.exit_code)
        return "signal=" + String(self.signal)


def _decode_status(raw: Int) -> ProcessStatus:
    var low = raw & 0x7F
    if low == 0:
        return ProcessStatus("reaped", True, (raw >> 8) & 0xFF, 0, raw)
    if low == 0x7F:
        return ProcessStatus("stopped", False, -1, 0, raw)
    return ProcessStatus("reaped", False, -1, low, raw)


def wait_nohang(pid: Int) -> ProcessStatus:
    var status = InlineArray[c_int, 1](fill=0)
    var r = Int(
        external_call["waitpid", c_int](
            c_int(pid), status.unsafe_ptr(), c_int(WNOHANG)
        )
    )
    if r == pid:
        return _decode_status(Int(status[0]))
    if r < 0:
        return ProcessStatus("gone", False, -1, -1, -1)
    return ProcessStatus("running", False, -1, 0, 0)


def wait_bounded(pid: Int, deadline_ms: Int) -> ProcessStatus:
    var start = now_ms()
    while True:
        var st = wait_nohang(pid)
        if st.state != "running":
            return st^
        if now_ms() - start >= deadline_ms:
            return st^
        sleep_ms(5)


def terminate_owned(pid: Int, grace_ms: Int) -> ProcessStatus:
    """Reap a child this test owns, escalating SIGTERM -> SIGKILL.

    A pid already reaped or not waitable (``gone``) is never signaled, so a
    reused PID from an unrelated process can never be targeted.
    """
    var st = wait_nohang(pid)
    if st.state != "running":
        return st^
    _ = kill_pid(pid, SIGTERM)
    st = wait_bounded(pid, grace_ms)
    if st.state == "running":
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


def open_fd_count() -> Int:
    """Count this process's open descriptors by probing ``/dev/fd/N``.

    A bounded, read-only descriptor census used to evidence that repeated
    teardown leaks no descriptors. Returns -1 if the platform probe is
    unavailable (never treated as a pass).
    """
    var probe = String("/dev/fd")
    var dir = Int(
        external_call["open", c_int](
            probe.as_c_string_slice().unsafe_ptr(), c_int(0)
        )
    )
    if dir < 0:
        probe = "/proc/self/fd"
        dir = Int(
            external_call["open", c_int](
                probe.as_c_string_slice().unsafe_ptr(), c_int(0)
            )
        )
        if dir < 0:
            return -1
    close_fd(dir)
    var count = 0
    for n in range(3, 1024):
        var path = probe + "/" + String(n)
        var fd = Int(
            external_call["open", c_int](
                path.as_c_string_slice().unsafe_ptr(), c_int(0)
            )
        )
        if fd >= 0:
            count += 1
            close_fd(fd)
    return count
