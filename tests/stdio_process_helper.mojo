"""Bounded, parent-owned stdio entrypoint runner for HYF process tests.

ADR-0014 D33 FX06/FX08: the *parent* enforces finite startup/read/write/wait
deadlines, bounds stdout/ready output, and reaps/closes every owned descriptor
on success, assertion failure, timeout or early return. The child ``alarm`` is
defense in depth only.

The request/response API is unchanged so existing call sites keep working.
"""

import std.os
from std.ffi import CStringSlice, c_int, external_call

from parent_lifecycle import (
    TERMINATION_GRACE_MS,
    FIXTURE_DEFAULT_DEADLINE_MS,
    child_exit,
    close_fd,
    dup2_fd,
    fork_pid,
    make_pipe,
    read_all_bounded,
    set_alarm,
    terminate_owned,
    wait_bounded,
    write_fd_bounded,
)
from safe_tempdir import SafeTempDir

from json import Value, loads


comptime HYF_PATHS_PROFILE_ENV = "HYF_PATHS_PROFILE"
comptime HYF_PATHS_REPO_LOCAL_ROOT_ENV = "HYF_PATHS_REPO_LOCAL_ROOT"

# The entrypoint compiles and runs a real Mojo program; this is a finite
# build/run lane budget, not a fixture lifetime and not a product SLO.
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
    pid: Int, stdin_fd: Int, stdout_fd: Int, stderr_fd: Int, reason: String
) raises:
    var st = terminate_owned(pid, TERMINATION_GRACE_MS)
    close_fd(stdin_fd)
    close_fd(stdout_fd)
    close_fd(stderr_fd)
    raise Error("stdio-entrypoint " + reason + " (child " + st.describe() + ")")


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
    var stdin_pipe = make_pipe()
    var stdout_pipe = make_pipe()
    var stderr_pipe = make_pipe()

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

    var stdin_read_fd = stdin_pipe.read_fd
    var stdin_write_fd = stdin_pipe.write_fd
    var stdout_read_fd = stdout_pipe.read_fd
    var stdout_write_fd = stdout_pipe.write_fd
    var stderr_read_fd = stderr_pipe.read_fd
    var stderr_write_fd = stderr_pipe.write_fd
    var command_ptr = command.as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv.unsafe_ptr()

    var pid = fork_pid()
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

    var write_reason = write_fd_bounded(
        stdin_write_fd, request_json + "\n", deadline_ms
    )
    close_fd(stdin_write_fd)
    if write_reason != "":
        _terminate_and_raise(
            pid, -1, stdout_read_fd, stderr_read_fd, "write_" + write_reason
        )

    var output = ""
    try:
        output = read_all_bounded(
            stdout_read_fd, STDIO_MAX_STDOUT_BYTES, deadline_ms
        )
    except:
        _terminate_and_raise(
            pid,
            -1,
            stdout_read_fd,
            stderr_read_fd,
            "stdout_bounded_read_failed",
        )
    close_fd(stdout_read_fd)

    var diagnostics = _diagnostics_or_empty(stderr_read_fd)
    close_fd(stderr_read_fd)

    var st = wait_bounded(pid, deadline_ms)
    if not st.reaped():
        var term = terminate_owned(pid, TERMINATION_GRACE_MS)
        raise Error("stdio-entrypoint timeout (child " + term.describe() + ")")
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


def _diagnostics_or_empty(fd: Int) -> String:
    try:
        return read_all_bounded(
            fd, STDIO_MAX_STDERR_BYTES, TERMINATION_GRACE_MS
        )
    except:
        return ""


def run_hyf_stdio(request_json: String) raises -> Value:
    var response = Value(None)
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                response = run_stdio_entrypoint("src/main.mojo", request_json)
    return response^
