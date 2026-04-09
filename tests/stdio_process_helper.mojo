import std.os
from std.os import Pipe, Process
from std.ffi import CStringSlice, c_int, external_call
from std.sys._libc import close, exit, vfork
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
    var stdin_pipe = Pipe()
    var stdout_pipe = Pipe()
    var output = String("")
    var command = String("mojo")
    var include_flag = String("-I")
    var include_path = String("src")
    var entrypoint_path = String(entrypoint)
    var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](length=6, fill={})
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

    var pid = vfork()
    if pid < 0:
        raise Error("failed to spawn hyf process test child")

    if pid == 0:
        if _dup2(c_int(stdin_pipe.fd_in.value().value), 0) < 0:
            exit(126)
        if _dup2(c_int(stdout_pipe.fd_out.value().value), 1) < 0:
            exit(126)
        _ = close(c_int(stdin_pipe.fd_in.value().value))
        _ = close(c_int(stdin_pipe.fd_out.value().value))
        _ = close(c_int(stdout_pipe.fd_in.value().value))
        _ = close(c_int(stdout_pipe.fd_out.value().value))
        _ = external_call["execvp", c_int](
            command.as_c_string_slice().unsafe_ptr(),
            argv.unsafe_ptr(),
        )
        exit(127)

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
