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
    fd: Int, mut out: List[UInt8], cap: Int, revents: Int
) -> DrainOutcome:
    """Read one ready descriptor into a capped buffer; preserve the cause."""
    if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0:
        return DrainOutcome(False, "")
    var buf = InlineArray[Byte, 4096](fill=0)
    var n = read_fd(fd, buf.unsafe_ptr(), 4096)
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


def _terminate_and_raise(
    pid: Int,
    stdin_fd: Int,
    stdout_fd: Int,
    stderr_fd: Int,
    reason: String,
) raises:
    var st = terminate_owned(pid, TERMINATION_GRACE_MS)
    close_fd(stdin_fd)
    close_fd(stdout_fd)
    close_fd(stderr_fd)
    raise Error(
        "stdio-entrypoint "
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


def run_stdio_entrypoint_with_deadline(
    entrypoint: String,
    request_json: String,
    arg0: String,
    arg1: String,
    deadline_ms: Int,
) raises -> Value:
    var pipes = make_three_pipes()

    var command = String("mojo")
    var include_flag = String("-I")
    var include_path = String("src")
    var entrypoint_path = String(entrypoint)
    var process_arg0 = String(arg0)
    var process_arg1 = String(arg1)
    var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](length=8, fill={})
    argv[0] = rebind[CStringSlice[ImmutAnyOrigin]](command.as_c_string_slice())
    argv[1] = rebind[CStringSlice[ImmutAnyOrigin]]("run".as_c_string_slice())
    argv[2] = rebind[CStringSlice[ImmutAnyOrigin]](
        include_flag.as_c_string_slice()
    )
    argv[3] = rebind[CStringSlice[ImmutAnyOrigin]](
        include_path.as_c_string_slice()
    )
    argv[4] = rebind[CStringSlice[ImmutAnyOrigin]](
        entrypoint_path.as_c_string_slice()
    )
    if process_arg0 != "":
        argv[5] = rebind[CStringSlice[ImmutAnyOrigin]](
            process_arg0.as_c_string_slice()
        )
    if process_arg1 != "":
        argv[6] = rebind[CStringSlice[ImmutAnyOrigin]](
            process_arg1.as_c_string_slice()
        )

    var stdin_read_fd = pipes.stdin_pipe.read_fd
    var stdin_write_fd = pipes.stdin_pipe.write_fd
    var stdout_read_fd = pipes.stdout_pipe.read_fd
    var stdout_write_fd = pipes.stdout_pipe.write_fd
    var stderr_read_fd = pipes.stderr_pipe.read_fd
    var stderr_write_fd = pipes.stderr_pipe.write_fd
    var command_ptr = command.as_c_string_slice().unsafe_ptr()
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
                stdin_done = True
            elif (pr.r0 & POLLOUT) != 0:
                var cw = write_fd_chunk(stdin_write_fd, request, sent)
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
                stdout_read_fd, stdout, STDIO_MAX_STDOUT_BYTES, pr.r1
            )
            stdout_eof = d.eof
            if d.reason != "":
                read_reason = "stdout_" + d.reason
                break
        if not stderr_eof:
            var d = drain_ready(
                stderr_read_fd, stderr_bytes, STDIO_MAX_STDERR_BYTES, pr.r2
            )
            stderr_eof = d.eof
            if d.reason != "":
                read_reason = "stderr_" + d.reason
                break

    close_fd(stdin_write_fd)
    if write_reason != "":
        _terminate_and_raise(
            pid,
            -1,
            stdout_read_fd,
            stderr_read_fd,
            "write_" + write_reason,
        )
    if read_reason != "":
        _terminate_and_raise(
            pid, -1, stdout_read_fd, stderr_read_fd, read_reason
        )

    var st = wait_bounded(pid, TERMINATION_GRACE_MS)
    if not st.reaped():
        _terminate_and_raise(pid, -1, stdout_read_fd, stderr_read_fd, "timeout")
    close_fd(stdout_read_fd)
    close_fd(stderr_read_fd)

    var output = bytes_to_string(stdout)
    var diagnostics = bytes_to_string(stderr_bytes)

    if st.exited and st.exit_code == 127:
        raise Error(
            "stdio-entrypoint exec_failed (stdout="
            + output
            + " stderr="
            + diagnostics
            + ")"
        )
    if not st.exited or st.exit_code != 0:
        raise Error(
            "stdio-entrypoint child_failed ("
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
