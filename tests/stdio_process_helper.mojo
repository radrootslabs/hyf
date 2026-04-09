import std.os
from std.os import Pipe, Process
from std.ffi import CStringSlice, c_int, external_call
from std.sys._libc import close
from std.tempfile import TemporaryDirectory

from mojson import Value, loads


comptime HYF_PATHS_PROFILE_ENV = "HYF_PATHS_PROFILE"
comptime HYF_PATHS_REPO_LOCAL_ROOT_ENV = "HYF_PATHS_REPO_LOCAL_ROOT"


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


def _dup2(oldfd: c_int, newfd: c_int) -> c_int:
    return external_call["dup2", c_int](oldfd, newfd)


@always_inline
def _fork() -> c_int:
    return external_call["fork", c_int]()


@always_inline
def _exit_child(code: c_int):
    _ = external_call["_exit", c_int](code)


def _read_pipe_to_string(mut pipe: Pipe) raises -> String:
    var buffer = InlineArray[Byte, 4096](fill=0)
    var output = String("")
    while True:
        var read = pipe.read_bytes(Span(buffer))
        if read == 0:
            break
        output += String(
            from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(read))
        )
    return output^


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


def run_stdio_entrypoint_with_2_args(
    entrypoint: String, request_json: String, arg0: String, arg1: String
) raises -> Value:
    var stdin_pipe = Pipe()
    var stdout_pipe = Pipe()
    var output = String("")
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

    var stdin_read_fd = c_int(stdin_pipe.fd_in.value().value)
    var stdin_write_fd = c_int(stdin_pipe.fd_out.value().value)
    var stdout_read_fd = c_int(stdout_pipe.fd_in.value().value)
    var stdout_write_fd = c_int(stdout_pipe.fd_out.value().value)
    var command_ptr = command.as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv.unsafe_ptr()

    var pid = _fork()
    if pid < 0:
        raise Error("failed to spawn hyf process test child")

    if pid == 0:
        if _dup2(stdin_read_fd, 0) < 0:
            _exit_child(c_int(126))
        if _dup2(stdout_write_fd, 1) < 0:
            _exit_child(c_int(126))
        _ = close(stdin_read_fd)
        _ = close(stdin_write_fd)
        _ = close(stdout_read_fd)
        _ = close(stdout_write_fd)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        _exit_child(c_int(127))

    stdin_pipe.set_output_only()
    stdout_pipe.set_input_only()

    stdin_pipe.write_bytes((request_json + "\n").as_bytes())
    stdin_pipe.set_input_only()

    output = _read_pipe_to_string(stdout_pipe)
    stdout_pipe.set_output_only()

    var process = Process(Int(pid))
    var status = process.wait()
    if not status.exit_code or status.exit_code.value() != 0:
        raise Error("hyf process exited unexpectedly")

    if output == "":
        raise Error("hyf process returned no stdout payload")
    return loads(output)


def run_hyf_stdio(request_json: String) raises -> Value:
    var response = Value(None)
    with TemporaryDirectory() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                response = run_stdio_entrypoint("src/main.mojo", request_json)
    return response^
