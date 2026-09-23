"""Governed test-only persistent-process measurement tooling (ADR-0012 D29).

H005A requires repo-owned, standalone measurement tooling rather than a
docs-resident script. This helper owns exactly one persistent HYF stdio process
and drives warmup plus measured frames over that single process, validating
every frame's parsed envelope, correlation, outcome and count with finite
bounded I/O, a checked child exit and exception-safe cleanup.

It exists only for tests. It changes no HYF product policy, no schema and no
dependency: the process is launched from a build of the existing product entry
point and the samples are read back with the bounded lifecycle primitives.

Explicit failure policy (R56/R57):

* a frame that is not JSON, has the wrong correlation or outcome, or a child
  that exits nonzero, fails the measurement instead of reporting success;
* unavailable ``ps``/``lsof`` sampling raises a sampling error rather than
  recording a placeholder value;
* every read/write/wait is parent-bounded by a finite deadline and the owned
  child is always terminated and reaped through the shared ownership guard.
"""

from std.collections import List
from std.ffi import CStringSlice, c_int, external_call

from json import Value, loads

from parent_lifecycle import (
    IO_DEADLINE_EXPIRED,
    LIFECYCLE_POLL_SLICE_MS,
    POLLERR,
    POLLHUP,
    POLLIN,
    POLLNVAL,
    POLLOUT,
    TERMINATION_GRACE_MS,
    CleanupGuard,
    PipedChildState,
    ProcessStatus,
    child_exit,
    close_fd,
    dup2_fd,
    fork_owned_or_close3,
    make_three_pipes,
    now_ms,
    piped_child_state,
    poll_three,
    read_fd,
    set_alarm,
    terminate_owned,
    wait_bounded,
    write_fd_chunk,
)


comptime MEASUREMENT_FRAME_BYTES = 1048576
comptime MEASUREMENT_FRAME_DEADLINE_MS = 5000
comptime MEASUREMENT_SAMPLE_DEADLINE_MS = 10000
comptime MEASUREMENT_CHILD_ALARM_SECONDS = 900
comptime MEASUREMENT_MAX_CAPTURE_BYTES = 65536
comptime MEASUREMENT_SAMPLE_INTERVAL = 50


# ── Bounded captured commands (identity and sampling) ───────────────────────


@fieldwise_init
struct CommandOutput(Movable):
    var exit_code: Int
    var signal: Int
    var stdout: String
    var stderr: String

    def describe(self) -> String:
        return (
            "exited="
            + String(self.exit_code)
            + " signal="
            + String(self.signal)
        )


def run_capture(
    command: String,
    var args: List[String],
    deadline_ms: Int,
    mut guard: CleanupGuard,
) raises -> CommandOutput:
    """Run one bounded child command and capture its stdout/stderr.

    The child is owned by this test: it is forked once, its stdio is closed or
    captured, every drain is bounded by ``deadline_ms`` and a timeout terminates
    and reaps the exact owned pid. A non-``execvp`` failure is reported as an
    exit rather than silently succeeding.
    """
    var parts = List[String]()
    parts.append(command)
    for index in range(len(args)):
        parts.append(args[index])
    var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
        length=len(parts) + 1, fill={}
    )
    var elements = parts.unsafe_ptr()
    for index in range(len(parts)):
        argv[index] = rebind[CStringSlice[ImmutAnyOrigin]](
            elements[index].as_c_string_slice()
        )

    var pipes = make_three_pipes()
    var stdin_read_fd = pipes.stdin_pipe.read_fd
    var stdin_write_fd = pipes.stdin_pipe.write_fd
    var stdout_read_fd = pipes.stdout_pipe.read_fd
    var stdout_write_fd = pipes.stdout_pipe.write_fd
    var stderr_read_fd = pipes.stderr_pipe.read_fd
    var stderr_write_fd = pipes.stderr_pipe.write_fd
    var command_ptr = elements[0].as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv.unsafe_ptr()

    var pid = fork_owned_or_close3(pipes)
    if pid == 0:
        if dup2_fd(stdin_read_fd, 0) < 0:
            child_exit(126)
        if dup2_fd(stdout_write_fd, 1) < 0:
            child_exit(126)
        if dup2_fd(stderr_write_fd, 2) < 0:
            child_exit(126)
        close_fd(stdin_read_fd)
        close_fd(stdin_write_fd)
        close_fd(stdout_read_fd)
        close_fd(stdout_write_fd)
        close_fd(stderr_read_fd)
        close_fd(stderr_write_fd)
        _ = set_alarm(MEASUREMENT_CHILD_ALARM_SECONDS)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        child_exit(127)

    close_fd(stdin_read_fd)
    close_fd(stdin_write_fd)
    close_fd(stdout_write_fd)
    close_fd(stderr_write_fd)

    var stdout = List[UInt8]()
    var stderr_bytes = List[UInt8]()
    var stdout_eof = False
    var stderr_eof = False
    var read_reason = ""
    var start = now_ms()
    while not (stdout_eof and stderr_eof):
        var elapsed = now_ms() - start
        if elapsed >= deadline_ms:
            read_reason = "sample_deadline_expired"
            break
        var slice_ms = min(LIFECYCLE_POLL_SLICE_MS, deadline_ms - elapsed)
        if slice_ms < 1:
            slice_ms = 1
        var pr = poll_three(
            -1,
            0,
            stdout_read_fd,
            0 if stdout_eof else POLLIN,
            stderr_read_fd,
            0 if stderr_eof else POLLIN,
            slice_ms,
        )
        if pr.count < 0:
            read_reason = "sample_poll_failed"
            break
        if pr.count == 0:
            continue
        var remaining = deadline_ms - (now_ms() - start)
        if not stdout_eof:
            var d = drain_capture(stdout_read_fd, stdout, pr.r1, remaining)
            stdout_eof = d.eof
            if d.reason != "":
                read_reason = "stdout_" + d.reason
                break
        if not stderr_eof:
            var d = drain_capture(
                stderr_read_fd, stderr_bytes, pr.r2, remaining
            )
            stderr_eof = d.eof
            if d.reason != "":
                read_reason = "stderr_" + d.reason
                break

    close_fd(stdout_read_fd)
    close_fd(stderr_read_fd)
    if read_reason != "":
        var term = terminate_owned(pid, TERMINATION_GRACE_MS)
        guard.retain(
            pid, -1, "measurement sample command " + command + " " + read_reason
        )
        if term.cleanup_proved():
            guard.resolve_pid(pid)
        raise Error(
            "measurement: sample command " + command + " " + read_reason
        )

    var remaining = deadline_ms - (now_ms() - start)
    if remaining < 1:
        remaining = 1
    var st = wait_bounded(pid, remaining)
    if not st.cleanup_proved():
        var term = terminate_owned(pid, TERMINATION_GRACE_MS)
        guard.retain(
            pid, -1, "measurement sample command " + command + " timeout"
        )
        if term.cleanup_proved():
            guard.resolve_pid(pid)
        raise Error("measurement: sample command " + command + " timeout")
    guard.resolve_pid(pid)

    return CommandOutput(
        exit_code=st.exit_code if st.exited else -1,
        signal=st.signal,
        stdout=bytes_to_text(stdout),
        stderr=bytes_to_text(stderr_bytes),
    )


@fieldwise_init
struct DrainResult(Movable):
    var eof: Bool
    var reason: String


def drain_capture(
    fd: Int, mut out: List[UInt8], revents: Int, deadline_ms: Int
) -> DrainResult:
    """Drain one captured descriptor with a bounded cause."""
    if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0:
        return DrainResult(False, "")
    var buf = InlineArray[Byte, 4096](fill=0)
    var n = read_fd(fd, buf.unsafe_ptr(), 4096, deadline_ms)
    if n == IO_DEADLINE_EXPIRED:
        return DrainResult(True, "read_deadline_expired")
    if n < 0:
        return DrainResult(True, "read_error")
    if n == 0:
        return DrainResult(True, "")
    if len(out) + n > MEASUREMENT_MAX_CAPTURE_BYTES:
        return DrainResult(True, "capture_overflow")
    for index in range(n):
        out.append(UInt8(Int(buf[index])))
    return DrainResult(False, "")


def bytes_to_text(bytes: List[UInt8]) raises -> String:
    if len(bytes) == 0:
        return ""
    return String(from_utf8=Span(ptr=bytes.unsafe_ptr(), length=len(bytes)))


# ── Identity ────────────────────────────────────────────────────────────────


def run_capture_simple(
    command: String, var args: List[String], mut guard: CleanupGuard
) raises -> CommandOutput:
    return run_capture(command, args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard)


def file_sha256(path: String, mut guard: CleanupGuard) raises -> String:
    """Exact sha256 of ``path`` via a bounded ``shasum``/``sha256sum`` call."""
    var shasum_args = List[String]()
    shasum_args.append("-a")
    shasum_args.append("256")
    shasum_args.append(path)
    var out = run_capture_simple("shasum", shasum_args^, guard)
    if out.exit_code != 0 or out.stdout.strip().byte_length() < 64:
        var sum_args = List[String]()
        sum_args.append(path)
        var alt = run_capture(
            "sha256sum", sum_args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard
        )
        if alt.exit_code != 0 or alt.stdout.strip().byte_length() < 64:
            raise Error("measurement: sha256 unavailable for " + path)
        out = alt^
    var text = String(out.stdout.strip())
    var digest = String(text[byte=0:64])
    for byte in digest.as_bytes():
        var b = Int(byte)
        var is_digit = b >= 48 and b <= 57
        var is_hex = (b >= 97 and b <= 102) or (b >= 65 and b <= 70)
        if not is_digit and not is_hex:
            raise Error(
                "measurement: sha256 output not hexadecimal for " + path
            )
    return digest


def host_platform(mut guard: CleanupGuard) raises -> String:
    var args = List[String]()
    args.append("-s")
    args.append("-m")
    var out = run_capture_simple("uname", args^, guard)
    if out.exit_code != 0:
        raise Error("measurement: host platform unavailable")
    return String(out.stdout.strip())


def toolchain_version(mut guard: CleanupGuard) raises -> String:
    var args = List[String]()
    args.append("--version")
    var out = run_capture_simple("mojo", args^, guard)
    if out.exit_code != 0:
        raise Error("measurement: toolchain version unavailable")
    var text = String(out.stdout.strip())
    if text == "":
        text = String(out.stderr.strip())
    if text.byte_length() == 0:
        raise Error("measurement: toolchain version output empty")
    var newline = text.find("\n")
    if newline >= 0:
        return String(text[byte=0:newline])
    return text^


@fieldwise_init
struct MeasurementIdentity(Movable):
    """Exact source/binary/toolchain/host identity and launch profile."""

    var source_root: String
    var binary_path: String
    var binary_sha256: String
    var pixi_toml_sha256: String
    var pixi_lock_sha256: String
    var toolchain_version: String
    var host_platform: String
    var argv_profile: String
    var env_profile: String

    def describe(self) -> String:
        return (
            "binary_sha256="
            + self.binary_sha256
            + " pixi_toml_sha256="
            + self.pixi_toml_sha256
            + " pixi_lock_sha256="
            + self.pixi_lock_sha256
            + " toolchain="
            + self.toolchain_version
            + " host="
            + self.host_platform
            + " argv="
            + self.argv_profile
            + " env="
            + self.env_profile
        )


comptime MEASUREMENT_BUILD_DEADLINE_MS = 600000


def build_product_binary(
    temp_dir: String, mut guard: CleanupGuard
) raises -> String:
    """Build the existing product entry point once, outside measured frames.

    The build is a separate bounded phase; the measurement itself never
    compiles or starts a process per frame.
    """
    var output = temp_dir + "/hyfd"
    var args = List[String]()
    args.append("build")
    args.append("-I")
    args.append("src")
    args.append("src/main.mojo")
    args.append("-o")
    args.append(output)
    var out = run_capture("mojo", args^, MEASUREMENT_BUILD_DEADLINE_MS, guard)
    if out.exit_code != 0:
        raise Error(
            "measurement: product build failed (" + out.describe() + ")"
        )
    return output^


def measurement_identity(
    source_root: String,
    binary_path: String,
    argv_profile: String,
    env_profile: String,
    mut guard: CleanupGuard,
) raises -> MeasurementIdentity:
    return MeasurementIdentity(
        source_root=source_root,
        binary_path=binary_path,
        binary_sha256=file_sha256(binary_path, guard),
        pixi_toml_sha256=file_sha256(source_root + "/pixi.toml", guard),
        pixi_lock_sha256=file_sha256(source_root + "/pixi.lock", guard),
        toolchain_version=toolchain_version(guard),
        host_platform=host_platform(guard),
        argv_profile=argv_profile,
        env_profile=env_profile,
    )


# ── Persistent measured process ─────────────────────────────────────────────


@fieldwise_init
struct MeasurementProcess(Movable):
    """Exactly one persistent HYF stdio process owned by the measurement."""

    var pid: Int
    var stdin_fd: Int
    var reader: PipedChildState
    var stderr_fd: Int
    var stderr_bytes: List[UInt8]
    var stderr_eof: Bool
    var deadline_ms: Int
    var start_ms: Int
    var stdin_closed: Bool
    var reaped: Bool
    var status: ProcessStatus

    def remaining_ms(mut self) -> Int:
        return self.deadline_ms - (now_ms() - self.start_ms)

    def send_frame(mut self, frame: String, deadline_ms: Int) raises:
        """Write one newline-delimited request frame with a finite deadline."""
        var payload = frame + "\n"
        var sent = 0
        var start = now_ms()
        while sent < payload.byte_length():
            var remaining = deadline_ms - (now_ms() - start)
            if remaining <= 0:
                raise Error("measurement: request write deadline expired")
            var ev = poll_three(self.stdin_fd, POLLOUT, -1, 0, -1, 0, 25)
            if ev.count < 0:
                raise Error("measurement: request write poll failed")
            if ev.count == 0:
                continue
            if (ev.r0 & (POLLERR | POLLHUP | POLLNVAL)) != 0:
                raise Error("measurement: request write pipe closed")
            var cw = write_fd_chunk(self.stdin_fd, payload, sent, remaining)
            if cw.reason != "":
                raise Error(
                    "measurement: request write failed (" + cw.reason + ")"
                )
            sent += cw.written
        self.drain_stderr(25)

    def read_response(mut self, deadline_ms: Int) raises -> String:
        """Read one complete newline-terminated response with bounded I/O."""
        self.drain_stderr(1)
        var line = self.reader.read_line(MEASUREMENT_FRAME_BYTES, deadline_ms)
        if not self.reader.last_terminated:
            if line == "":
                raise Error(
                    "measurement: response stream reached EOF with no frame"
                    " (early_eof)"
                )
            raise Error(
                "measurement: response frame was not newline-terminated"
            )
        return line^

    def drain_stderr(mut self, slice_ms: Int):
        if self.stderr_eof:
            return
        var pr = poll_three(-1, 0, -1, 0, self.stderr_fd, POLLIN, slice_ms)
        if pr.count <= 0:
            return
        var buf = InlineArray[Byte, 4096](fill=0)
        var n = read_fd(self.stderr_fd, buf.unsafe_ptr(), 4096, 0)
        if n <= 0:
            if n == 0:
                self.stderr_eof = True
            return
        if len(self.stderr_bytes) + n <= MEASUREMENT_MAX_CAPTURE_BYTES:
            for index in range(n):
                self.stderr_bytes.append(UInt8(Int(buf[index])))

    def finish(mut self) raises -> ProcessStatus:
        """Close stdin, require a clean bounded child exit and prove cleanup."""
        if not self.stdin_closed:
            close_fd(self.stdin_fd)
            self.stdin_fd = -1
            self.stdin_closed = True
        var remaining = self.remaining_ms()
        if remaining < 1:
            remaining = 1
        var st = wait_bounded(self.pid, remaining)
        if not st.cleanup_proved():
            var term = terminate_owned(self.pid, TERMINATION_GRACE_MS)
            self.reader.guard[].retain(
                self.pid,
                self.reader.report_fd,
                "measurement process cleanup unproved " + term.describe(),
            )
            self.status = term.copy()
            if term.cleanup_proved():
                self.reader.guard[].resolve_pid(self.pid)
                self.reaped = True
                self.reader.close_reader()
                close_fd(self.stderr_fd)
            raise Error(
                "measurement: process did not exit within its budget ("
                + term.describe()
                + ")"
            )
        self.status = st.copy()
        self.reaped = True
        self.reader.guard[].resolve_pid(self.pid)
        self.reader.close_reader()
        close_fd(self.stderr_fd)
        return st^

    def cleanup(mut self):
        """Non-raising cleanup so a failing assertion still reaps the child."""
        if self.stdin_fd >= 0 and not self.stdin_closed:
            close_fd(self.stdin_fd)
            self.stdin_fd = -1
            self.stdin_closed = True
        if not self.reaped:
            var st = terminate_owned(self.pid, TERMINATION_GRACE_MS)
            self.status = st.copy()
            if st.cleanup_proved():
                self.reaped = True
                self.reader.guard[].resolve_pid(self.pid)
            else:
                self.reader.guard[].retain(
                    self.pid,
                    self.reader.report_fd,
                    "measurement process cleanup unproved " + st.describe(),
                )
        self.reader.close_reader()
        if not self.stderr_eof:
            close_fd(self.stderr_fd)
            self.stderr_eof = True

    def stderr_text(mut self) raises -> String:
        return bytes_to_text(self.stderr_bytes)


def spawn_measurement_process(
    binary_path: String,
    var argv: List[String],
    deadline_ms: Int,
    mut guard: CleanupGuard,
) raises -> MeasurementProcess:
    """Fork exactly one persistent process for warmup and measured frames."""
    var parts = List[String]()
    parts.append(binary_path)
    for index in range(len(argv)):
        parts.append(argv[index])
    var argv_c = List[Optional[CStringSlice[ImmutAnyOrigin]]](
        length=len(parts) + 1, fill={}
    )
    var elements = parts.unsafe_ptr()
    for index in range(len(parts)):
        argv_c[index] = rebind[CStringSlice[ImmutAnyOrigin]](
            elements[index].as_c_string_slice()
        )

    var pipes = make_three_pipes()
    var stdin_read_fd = pipes.stdin_pipe.read_fd
    var stdin_write_fd = pipes.stdin_pipe.write_fd
    var stdout_read_fd = pipes.stdout_pipe.read_fd
    var stdout_write_fd = pipes.stdout_pipe.write_fd
    var stderr_read_fd = pipes.stderr_pipe.read_fd
    var stderr_write_fd = pipes.stderr_pipe.write_fd
    var command_ptr = elements[0].as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv_c.unsafe_ptr()

    var start = now_ms()
    var pid = fork_owned_or_close3(pipes)
    if pid == 0:
        if dup2_fd(stdin_read_fd, 0) < 0:
            child_exit(126)
        if dup2_fd(stdout_write_fd, 1) < 0:
            child_exit(126)
        if dup2_fd(stderr_write_fd, 2) < 0:
            child_exit(126)
        close_fd(stdin_read_fd)
        close_fd(stdin_write_fd)
        close_fd(stdout_read_fd)
        close_fd(stdout_write_fd)
        close_fd(stderr_read_fd)
        close_fd(stderr_write_fd)
        _ = set_alarm(MEASUREMENT_CHILD_ALARM_SECONDS)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        child_exit(127)

    close_fd(stdin_read_fd)
    close_fd(stdout_write_fd)
    close_fd(stderr_write_fd)
    var reader = piped_child_state(
        pid, stdout_read_fd, deadline_ms, 0, UnsafePointer(to=guard)
    )
    return MeasurementProcess(
        pid=pid,
        stdin_fd=stdin_write_fd,
        reader=reader^,
        stderr_fd=stderr_read_fd,
        stderr_bytes=List[UInt8](),
        stderr_eof=False,
        deadline_ms=deadline_ms,
        start_ms=start,
        stdin_closed=False,
        reaped=False,
        status=ProcessStatus("pending", False, -1, 0, 0, ""),
    )


# ── Frame validation ────────────────────────────────────────────────────────


@fieldwise_init
struct FrameVerdict(Movable):
    """Bounded per-frame validation result."""

    var ok: Bool
    var reason: String
    var outcome: String
    var declared_max_requests: Int

    def describe(self) -> String:
        return (
            "ok="
            + String(self.ok)
            + " outcome="
            + self.outcome
            + " reason="
            + self.reason
        )


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if String(candidate) == key:
            return True
    return False


def _field_string(value: Value, key: String) raises -> String:
    if not value.is_object():
        return ""
    if not _has_key(value, key):
        return ""
    var field = value[key]
    if not field.is_string():
        return ""
    return String(field.string_value())


def validate_status_frame(
    response_text: String,
    expected_request_id: String,
    expected_trace_id: String,
) raises -> FrameVerdict:
    """Validate one status frame's parsed envelope, correlation and outcome."""
    var parsed = Value(None)
    try:
        parsed = loads(response_text)
    except:
        return FrameVerdict(False, "not_json", "", -1)
    if not parsed.is_object():
        return FrameVerdict(False, "not_object", "", -1)
    if not _has_key(parsed, "version"):
        return FrameVerdict(False, "missing_version", "", -1)
    if Int(parsed["version"].int_value()) != 1:
        return FrameVerdict(False, "version_mismatch", "", -1)
    var request_id = _field_string(parsed, "request_id")
    if request_id != expected_request_id:
        return FrameVerdict(False, "correlation_mismatch", "", -1)
    var trace_id = _field_string(parsed, "trace_id")
    if trace_id != expected_trace_id:
        return FrameVerdict(False, "trace_mismatch", "", -1)
    if not _has_key(parsed, "ok"):
        return FrameVerdict(False, "missing_outcome", "", -1)
    if not parsed["ok"].bool_value():
        return FrameVerdict(False, "not_ok", "", -1)
    if _has_key(parsed, "error"):
        return FrameVerdict(False, "unexpected_error", "", -1)
    if not _has_key(parsed, "output") or not parsed["output"].is_object():
        return FrameVerdict(False, "missing_output", "", -1)
    var daemon = _field_string(parsed["output"], "daemon")
    if daemon != "hyfd":
        return FrameVerdict(False, "outcome_mismatch", "", -1)
    var declared = -1
    var output = parsed["output"]
    if _has_key(output, "limits") and output["limits"].is_object():
        var limits = output["limits"]
        if _has_key(limits, "max_requests_per_process"):
            declared = Int(limits["max_requests_per_process"].int_value())
    return FrameVerdict(True, "", "sys.status_ok", declared)


def build_status_frame(index: Int) -> List[String]:
    """One status request frame plus its expected request/trace correlation."""
    var request_id = "meas-status-" + String(index)
    var trace_id = "meas-trace-" + String(index)
    var frame = (
        '{"version":1,"request_id":"'
        + request_id
        + '","trace_id":"'
        + trace_id
        + '","capability":"sys.status","input":{}}'
    )
    var pair = List[String]()
    pair.append(frame)
    pair.append(request_id)
    pair.append(trace_id)
    return pair^


# ── Sampling ────────────────────────────────────────────────────────────────


def sample_rss_kb(
    pid: Int, command: String, mut guard: CleanupGuard
) raises -> Int:
    """Numeric resident-set size in kB, or an explicit sampling failure."""
    var args = List[String]()
    args.append("-o")
    args.append("rss=")
    args.append("-p")
    args.append(String(pid))
    var out = run_capture(command, args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard)
    if out.exit_code != 0:
        raise Error(
            "measurement: rss sampling unavailable ("
            + command
            + " "
            + out.describe()
            + ")"
        )
    var text = String(out.stdout.strip())
    if text.byte_length() == 0:
        raise Error("measurement: rss sampling returned no value")
    for byte in text.as_bytes():
        var b = Int(byte)
        if b < 48 or b > 57:
            raise Error("measurement: rss sampling value is not numeric")
    return Int(text)


def sample_fd_count(
    pid: Int, command: String, mut guard: CleanupGuard
) raises -> Int:
    """Numeric descriptor count, excluding lsof cwd/txt/mem pseudo rows."""
    var args = List[String]()
    args.append("-p")
    args.append(String(pid))
    args.append("-F")
    args.append("f")
    var out = run_capture(command, args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard)
    if out.exit_code != 0 and out.stdout.strip().byte_length() == 0:
        raise Error(
            "measurement: descriptor sampling unavailable ("
            + command
            + " "
            + out.describe()
            + ")"
        )
    var count = 0
    for line in out.stdout.split("\n"):
        var entry = String(line).strip()
        if entry.byte_length() < 2:
            continue
        if not entry.startswith("f"):
            continue
        var digits = String(entry[byte=1:])
        var numeric = True
        for byte in digits.as_bytes():
            var b = Int(byte)
            if b < 48 or b > 57:
                numeric = False
                break
        if numeric:
            count += 1
    if count == 0:
        raise Error("measurement: descriptor sampling counted no descriptors")
    return count


# ── Measurement session ─────────────────────────────────────────────────────


@fieldwise_init
struct MeasurementSession(Movable):
    """Validated result of one persistent warmup/measured process."""

    var identity: MeasurementIdentity
    var warmup_frames: Int
    var measured_frames: Int
    var ok_frames: Int
    var failed_frames: Int
    var first_failure: String
    var startup_ms: Int
    var warmup_ms: Int
    var measured_ms: Int
    var rss_kb_before_warmup: Int
    var rss_kb_after_warmup: Int
    var rss_kb_after_measured: Int
    var rss_kb_peak: Int
    var fd_before_warmup: Int
    var fd_after_measured: Int
    var fd_peak: Int
    var declared_max_requests_per_process: Int
    var child_exit: String
    var stderr_excerpt: String
    var sampling_method: String

    def summary(self) -> String:
        return (
            "frames="
            + String(self.warmup_frames + self.measured_frames)
            + " ok="
            + String(self.ok_frames)
            + " failed="
            + String(self.failed_frames)
            + " startup_ms="
            + String(self.startup_ms)
            + " warmup_ms="
            + String(self.warmup_ms)
            + " measured_ms="
            + String(self.measured_ms)
            + " rss_kb="
            + String(self.rss_kb_before_warmup)
            + "/"
            + String(self.rss_kb_after_warmup)
            + "/"
            + String(self.rss_kb_after_measured)
            + " peak="
            + String(self.rss_kb_peak)
            + " fd="
            + String(self.fd_before_warmup)
            + "/"
            + String(self.fd_after_measured)
            + " peak="
            + String(self.fd_peak)
            + " child="
            + self.child_exit
            + " first_failure="
            + (self.first_failure if self.first_failure != "" else "none")
        )


def measure_persistent_process(
    source_root: String,
    binary_path: String,
    argv_profile: String,
    env_profile: String,
    var argv: List[String],
    warmup_frames: Int,
    measured_frames: Int,
    deadline_ms: Int,
    mut guard: CleanupGuard,
    rss_sampler: String = "ps",
    fd_sampler: String = "lsof",
) raises -> MeasurementSession:
    """Drive warmup then measured frames over one persistent owned process.

    Every frame is written and read with a finite deadline and validated for
    parsed envelope, correlation and outcome; every sample is a real numeric
    value or an explicit error; the child must exit cleanly after EOF and its
    cleanup is always proved through the shared guard.
    """
    if warmup_frames < 0 or measured_frames < 1:
        raise Error("measurement: invalid warmup/measured frame counts")
    var identity = measurement_identity(
        source_root, binary_path, argv_profile, env_profile, guard
    )
    var process = spawn_measurement_process(
        identity.binary_path, argv^, deadline_ms, guard
    )
    var ok_frames = 0
    var failed_frames = 0
    var first_failure = ""
    var startup_ms = -1
    var warmup_ms = 0
    var measured_ms = 0
    var rss_before = 0
    var rss_after_warmup = 0
    var rss_after_measured = 0
    var rss_peak = 0
    var fd_before = 0
    var fd_after = 0
    var fd_peak = 0
    var declared = -1
    var child_exit = ""
    var stderr_excerpt = ""

    try:
        rss_before = sample_rss_kb(process.pid, rss_sampler, guard)
        fd_before = sample_fd_count(process.pid, fd_sampler, guard)
        rss_peak = rss_before
        fd_peak = fd_before
        var warmup_start = now_ms()
        var total = warmup_frames + measured_frames
        for index in range(total):
            var pair = build_status_frame(index)
            var frame = pair[0]
            var request_id = pair[1]
            var trace_id = pair[2]
            var frame_start = now_ms()
            process.send_frame(frame, deadline_ms)
            var response = process.read_response(deadline_ms)
            var latency = now_ms() - frame_start
            if index == 0:
                startup_ms = latency
            var verdict = validate_status_frame(response, request_id, trace_id)
            if verdict.declared_max_requests >= 0:
                declared = verdict.declared_max_requests
            if verdict.ok:
                ok_frames += 1
            else:
                failed_frames += 1
                if first_failure == "":
                    first_failure = (
                        "frame="
                        + String(index)
                        + " reason="
                        + verdict.reason
                        + " response="
                        + response
                    )
                # A mandatory per-frame guarantee failed: fail loudly instead
                # of reporting a partially successful measurement.
                raise Error("measurement: frame invalid " + first_failure)
            if index == warmup_frames - 1:
                warmup_ms = now_ms() - warmup_start
                rss_after_warmup = sample_rss_kb(
                    process.pid, rss_sampler, guard
                )
                fd_peak = max(
                    fd_peak, sample_fd_count(process.pid, fd_sampler, guard)
                )
                if rss_after_warmup > rss_peak:
                    rss_peak = rss_after_warmup
            if index >= warmup_frames:
                var measured_index = index - warmup_frames
                if measured_index % MEASUREMENT_SAMPLE_INTERVAL == 0:
                    var mid_rss = sample_rss_kb(process.pid, rss_sampler, guard)
                    var mid_fd = sample_fd_count(process.pid, fd_sampler, guard)
                    if mid_rss > rss_peak:
                        rss_peak = mid_rss
                    if mid_fd > fd_peak:
                        fd_peak = mid_fd
                if measured_index == measured_frames - 1:
                    measured_ms = now_ms() - warmup_start - warmup_ms
        rss_after_measured = sample_rss_kb(process.pid, rss_sampler, guard)
        fd_after = sample_fd_count(process.pid, fd_sampler, guard)
        if rss_after_measured > rss_peak:
            rss_peak = rss_after_measured
        if fd_after > fd_peak:
            fd_peak = fd_after
        var st = process.finish()
        child_exit = st.describe() + " cleanup=proved"
        stderr_excerpt = process.stderr_text()
        if not st.exited or st.exit_code != 0:
            # A failed child is a measurement failure, never a success with a
            # missing or partial outcome.
            raise Error(
                "measurement: child exited nonzero ("
                + st.describe()
                + ") stderr="
                + stderr_excerpt
            )
    except e:
        process.cleanup()
        raise Error("measurement: persistent measurement failed: " + String(e))

    return MeasurementSession(
        identity=identity^,
        warmup_frames=warmup_frames,
        measured_frames=measured_frames,
        ok_frames=ok_frames,
        failed_frames=failed_frames,
        first_failure=first_failure,
        startup_ms=startup_ms,
        warmup_ms=warmup_ms,
        measured_ms=measured_ms,
        rss_kb_before_warmup=rss_before,
        rss_kb_after_warmup=rss_after_warmup,
        rss_kb_after_measured=rss_after_measured,
        rss_kb_peak=rss_peak,
        fd_before_warmup=fd_before,
        fd_after_measured=fd_after,
        fd_peak=fd_peak,
        declared_max_requests_per_process=declared,
        child_exit=child_exit,
        stderr_excerpt=stderr_excerpt,
        sampling_method=(
            "ps -o rss= -p <pid> (kB) / "
            + fd_sampler
            + " -p <pid> -F f numeric f<digits> rows"
        ),
    )
