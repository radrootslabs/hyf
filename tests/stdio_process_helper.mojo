"""Bounded, parent-owned stdio entrypoint runner for HYF process tests.

ADR-0014 D33 FX06/FX08 and ADR-0015 D35 LC04: the *parent* enforces one finite
startup/write/read/wait budget, bounds stdout/stderr/ready output, drains
stdout and stderr concurrently with writing the request so a chatty child
cannot deadlock, ignores SIGPIPE so a peer-close race cannot kill the parent,
and reaps/closes every owned descriptor on success, assertion failure, timeout
or early return. The child ``alarm`` is defense in depth only.

The request/response API is unchanged so existing call sites keep working.
"""

import std.os
from std.collections import List
from std.ffi import CStringSlice, c_int, external_call

from parent_lifecycle import (
    IO_DEADLINE_EXPIRED,
    LIFECYCLE_POLL_SLICE_MS,
    POLLERR,
    POLLHUP,
    POLLIN,
    POLLNVAL,
    POLLOUT,
    TERMINATION_GRACE_MS,
    bytes_to_string,
    child_exit,
    close_fd,
    dup2_fd,
    fork_owned_or_close3,
    make_three_pipes,
    now_ms,
    poll_three,
    read_fd,
    set_alarm,
    terminate_owned,
    wait_bounded,
    write_fd_chunk,
)
from safe_tempdir import SafeTempDir

from json import Value, loads


comptime HYF_PATHS_PROFILE_ENV = "HYF_PATHS_PROFILE"
comptime HYF_PATHS_REPO_LOCAL_ROOT_ENV = "HYF_PATHS_REPO_LOCAL_ROOT"

# The entrypoint compiles and runs a real Mojo program; this is a finite
# build/run lane budget, not a fixture lifetime and not a product SLO. One
# budget covers compile, write, drain and wait; only the bounded cleanup grace
# is added for reaping.
comptime STDIO_ENTRYPOINT_DEADLINE_MS = 120000
comptime STDIO_CHILD_ALARM_SECONDS = 180
comptime STDIO_MAX_STDOUT_BYTES = 2097152
comptime STDIO_MAX_STDERR_BYTES = 65536


struct ScopedEnvVar:
    var name: String
    var value: String
    var previous: String
    var had_previous: Bool

    def __init__(out self, name: String, value: String):
        self.name = String(name)
        self.value = String(value)
        self.previous = std.os.getenv(name)
        self.had_previous = self.previous != ""

    def __enter__(mut self) raises:
        _ = std.os.setenv(self.name, self.value, overwrite=True)

    def __exit__(mut self):
        if self.had_previous:
            _ = std.os.setenv(self.name, self.previous, overwrite=True)
        else:
            _ = std.os.unsetenv(self.name)


@fieldwise_init
struct DrainOutcome(Movable):
    var eof: Bool
    var reason: String


def drain_ready(
    fd: Int, mut out: List[UInt8], cap: Int, revents: Int, deadline_ms: Int
) -> DrainOutcome:
    """Read one ready descriptor into a capped buffer; preserve the cause.

    The read's EINTR retry is bounded by the caller's remaining
    ``deadline_ms``, so a retried read returns to the deadline owner instead of
    spinning, and an expired retry is a distinct ``read_deadline_expired``
    cause rather than a clean EOF.
    """
    if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0:
        return DrainOutcome(False, "")
    var buf = InlineArray[Byte, 4096](fill=0)
    var n = read_fd(fd, buf.unsafe_ptr(), 4096, deadline_ms)
    if n == IO_DEADLINE_EXPIRED:
        return DrainOutcome(True, "read_deadline_expired")
    if n < 0:
        return DrainOutcome(True, "read_error")
    if n == 0:
        return DrainOutcome(True, "")
    if len(out) + n > cap:
        return DrainOutcome(True, "stream_overflow")
    for index in range(n):
        out.append(UInt8(Int(buf[index])))
    return DrainOutcome(False, "")


def run_stdio_entrypoint(
    entrypoint: String, request_json: String
) raises -> Value:
    return run_stdio_entrypoint_with_2_args(entrypoint, request_json, "", "")


def run_stdio_entrypoint(
    entrypoint: String, request_json: String, arg0: String, arg1: String
) raises -> Value:
    return run_stdio_entrypoint_with_2_args(
        entrypoint, request_json, arg0, arg1
    )


def _stdio_phase_summary(
    phase: String,
    request_sent: Bool,
    stdout_eof: Bool,
    stderr_eof: Bool,
    output_bytes: Int,
    output_valid: Bool,
    work_ms: Int,
    cleanup_ms: Int,
) -> String:
    """Bounded phase/time evidence for a stdio failure (ADR-0018 RA03).

    Work and cleanup time are recorded separately so an expired work budget can
    never be confused with the bounded cleanup allowance, and the phase fields
    prove which stage the child actually reached.
    """
    return (
        "stdio-entrypoint phase="
        + phase
        + " request_sent="
        + ("true" if request_sent else "false")
        + " stdout_eof="
        + ("true" if stdout_eof else "false")
        + " stderr_eof="
        + ("true" if stderr_eof else "false")
        + " output_bytes="
        + String(output_bytes)
        + " output_valid="
        + ("true" if output_valid else "false")
        + " work_ms="
        + String(work_ms)
        + " cleanup_ms="
        + String(cleanup_ms)
    )


def _output_is_valid_json(bytes: List[UInt8]) -> Bool:
    """True when the captured stdout is nonempty and parses as JSON."""
    if len(bytes) == 0:
        return False
    try:
        _ = loads(bytes_to_string(bytes))
        return True
    except:
        return False


def _terminate_and_raise(
    pid: Int,
    stdin_fd: Int,
    stdout_fd: Int,
    stderr_fd: Int,
    reason: String,
    phase: String,
    request_sent: Bool,
    stdout_eof: Bool,
    stderr_eof: Bool,
    output_bytes: Int,
    output_valid: Bool,
    work_ms: Int,
) raises:
    var cleanup_start = now_ms()
    var st = terminate_owned(pid, TERMINATION_GRACE_MS)
    var cleanup_ms = now_ms() - cleanup_start
    close_fd(stdin_fd)
    close_fd(stdout_fd)
    close_fd(stderr_fd)
    raise Error(
        _stdio_phase_summary(
            phase,
            request_sent,
            stdout_eof,
            stderr_eof,
            output_bytes,
            output_valid,
            work_ms,
            cleanup_ms,
        )
        + " reason="
        + reason
        + " (child "
        + st.describe()
        + " cleanup_error="
        + String("" if st.cleanup_proved() else "unreaped")
        + ")"
    )


def run_stdio_entrypoint_with_2_args(
    entrypoint: String, request_json: String, arg0: String, arg1: String
) raises -> Value:
    return run_stdio_entrypoint_with_deadline(
        entrypoint, request_json, arg0, arg1, STDIO_ENTRYPOINT_DEADLINE_MS
    )


def run_stdio_binary_with_deadline(
    binary: String,
    request_json: String,
    arg0: String,
    arg1: String,
    deadline_ms: Int,
) raises -> Value:
    """Run an already-built test child directly with the same guarantees.

    ADR-0018 RA03 phase isolation: this launch seam performs no compilation, so
    a late-exit control can prove the child actually reached valid output,
    closed output and the wait phase before its late exit was rejected. The
    ordinary compile/run helper keeps its declared total budget.
    """
    var args = List[String]()
    if arg0 != "":
        args.append(arg0)
    if arg1 != "":
        args.append(arg1)
    return _run_stdio_launch(binary, args^, request_json, deadline_ms)


def run_stdio_entrypoint_with_deadline(
    entrypoint: String,
    request_json: String,
    arg0: String,
    arg1: String,
    deadline_ms: Int,
) raises -> Value:
    var args = List[String]()
    args.append("run")
    args.append("-I")
    args.append("src")
    args.append(entrypoint)
    if arg0 != "":
        args.append(arg0)
    if arg1 != "":
        args.append(arg1)
    return _run_stdio_launch("mojo", args^, request_json, deadline_ms)


def _run_stdio_launch(
    command: String,
    var args: List[String],
    request_json: String,
    deadline_ms: Int,
) raises -> Value:
    # Build argv before owning any descriptors so no exception window can leak
    # pipes between creation and the fork; fork failure alone is handled by the
    # rollback helper. ``parts`` owns the C-string text for the whole call, so
    # every argv entry points at a live buffer until after the fork/exec.
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
        _ = set_alarm(STDIO_CHILD_ALARM_SECONDS)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        child_exit(127)

    close_fd(stdin_read_fd)
    close_fd(stdout_write_fd)
    close_fd(stderr_write_fd)

    var request = request_json + "\n"
    var sent = 0
    var stdout = List[UInt8]()
    var stderr_bytes = List[UInt8]()
    var stdout_eof = False
    var stderr_eof = False
    var stdin_done = False
    var write_reason = ""
    var read_reason = ""
    var start = now_ms()
    var budget = deadline_ms
    if budget <= 0:
        budget = 1

    while not (stdin_done and stdout_eof and stderr_eof):
        var elapsed = now_ms() - start
        if elapsed >= budget:
            read_reason = "read_deadline_expired"
            break
        var remaining = budget - elapsed
        var slice_ms = min(LIFECYCLE_POLL_SLICE_MS, remaining)
        if slice_ms < 1:
            slice_ms = 1
        var ev_stdin = 0 if stdin_done else POLLOUT
        var ev_out = 0 if stdout_eof else POLLIN
        var ev_err = 0 if stderr_eof else POLLIN
        var pr = poll_three(
            stdin_write_fd,
            ev_stdin,
            stdout_read_fd,
            ev_out,
            stderr_read_fd,
            ev_err,
            slice_ms,
        )
        if pr.count < 0:
            read_reason = "poll_failed"
            break
        if pr.count == 0:
            continue
        if not stdin_done:
            if (pr.r0 & (POLLERR | POLLHUP | POLLNVAL)) != 0:
                # An early peer close or error is a cause-specific failure even
                # when the child later exits 0 with valid stdout: the intended
                # request bytes were not delivered.
                write_reason = "write_pipe_closed"
                stdin_done = True
            elif (pr.r0 & POLLOUT) != 0:
                var cw = write_fd_chunk(
                    stdin_write_fd,
                    request,
                    sent,
                    budget - (now_ms() - start),
                )
                if cw.reason != "":
                    write_reason = cw.reason
                    stdin_done = True
                else:
                    sent += cw.written
                    if sent >= request.byte_length():
                        stdin_done = True
                        close_fd(stdin_write_fd)
                        stdin_write_fd = -1
        if not stdout_eof:
            var d = drain_ready(
                stdout_read_fd,
                stdout,
                STDIO_MAX_STDOUT_BYTES,
                pr.r1,
                budget - (now_ms() - start),
            )
            stdout_eof = d.eof
            if d.reason != "":
                read_reason = "stdout_" + d.reason
                break
        if not stderr_eof:
            var d = drain_ready(
                stderr_read_fd,
                stderr_bytes,
                STDIO_MAX_STDERR_BYTES,
                pr.r2,
                budget - (now_ms() - start),
            )
            stderr_eof = d.eof
            if d.reason != "":
                read_reason = "stderr_" + d.reason
                break

    var request_sent = sent >= request.byte_length()
    var work_ms = now_ms() - start
    var output_len = len(stdout)
    if write_reason == "" and not request_sent:
        # The loop only ends with stdin finished; guard any path that would
        # otherwise leave intended request bytes unwritten.
        write_reason = "write_incomplete"
    close_fd(stdin_write_fd)
    if write_reason != "":
        _terminate_and_raise(
            pid,
            -1,
            stdout_read_fd,
            stderr_read_fd,
            "write_" + write_reason,
            "write",
            request_sent,
            stdout_eof,
            stderr_eof,
            output_len,
            _output_is_valid_json(stdout),
            work_ms,
        )
    if read_reason != "":
        _terminate_and_raise(
            pid,
            -1,
            stdout_read_fd,
            stderr_read_fd,
            read_reason,
            "read",
            request_sent,
            stdout_eof,
            stderr_eof,
            output_len,
            _output_is_valid_json(stdout),
            work_ms,
        )

    var remaining = budget - (now_ms() - start)
    if remaining < 1:
        remaining = 1
    var st = wait_bounded(pid, remaining)
    work_ms = now_ms() - start
    if not st.cleanup_proved():
        _terminate_and_raise(
            pid,
            -1,
            stdout_read_fd,
            stderr_read_fd,
            "timeout",
            "wait",
            request_sent,
            stdout_eof,
            stderr_eof,
            output_len,
            _output_is_valid_json(stdout),
            work_ms,
        )
    close_fd(stdout_read_fd)
    close_fd(stderr_read_fd)

    var output = bytes_to_string(stdout)
    var diagnostics = bytes_to_string(stderr_bytes)

    if st.exited and st.exit_code == 127:
        raise Error(
            "stdio-entrypoint phase=exit exec_failed (stdout="
            + output
            + " stderr="
            + diagnostics
            + ")"
        )
    if not st.exited or st.exit_code != 0:
        raise Error(
            "stdio-entrypoint phase=exit child_failed ("
            + st.describe()
            + " stderr="
            + diagnostics
            + ")"
        )
    if output == "":
        raise Error("hyf process returned no stdout payload")
    return loads(output)


def run_hyf_stdio(request_json: String) raises -> Value:
    var response = Value(None)
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                response = run_stdio_entrypoint("src/main.mojo", request_json)
    return response^
