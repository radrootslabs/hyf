from std.collections import List, Optional
from std.ffi import CStringSlice, c_int, external_call
from std.os import Pipe, Process
from std.sys._libc import close

from flare.net import SocketAddr
from flare.tcp import TcpListener


def _dup2(oldfd: c_int, newfd: c_int) -> c_int:
    return external_call["dup2", c_int](oldfd, newfd)


@always_inline
def _fork() -> c_int:
    return external_call["fork", c_int]()


@always_inline
def _exit_child(code: c_int):
    _ = external_call["_exit", c_int](code)


def _read_pipe_line(mut pipe: Pipe) raises -> String:
    var buffer = InlineArray[Byte, 1](fill=0)
    var output = String("")
    while True:
        var read = pipe.read_bytes(Span(buffer))
        if read == 0:
            break
        var chunk = String(
            from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(read))
        )
        if chunk == "\n":
            break
        output += chunk
    return output^


struct SpawnedMaxLocalStub(Movable):
    var pid: Int

    def __init__(out self, pid: Int):
        self.pid = pid

    def wait(mut self) raises:
        var process = Process(self.pid)
        var status = process.wait()
        if not status.exit_code or status.exit_code.value() != 0:
            raise Error("max_local stub exited unexpectedly")


def reserve_loopback_port() raises -> Int:
    var listener = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(listener.local_addr().port)
    listener.close()
    return port


def spawn_max_local_stub(
    port: Int, mode: String
) raises -> SpawnedMaxLocalStub:
    var stdout_pipe = Pipe()
    var command = String("mojo")
    var include_flag = String("-I")
    var include_path = String("src")
    var vendor_include_path = String("../../../../vendor/mojo/flare")
    var entrypoint = String("tests/max_local_http_stub.mojo")
    var arg_port_flag = String("--port")
    var arg_port = String(port)
    var arg_mode_flag = String("--mode")
    var arg_mode = String(mode)
    var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](length=12, fill={})
    argv[0] = rebind[CStringSlice[ImmutAnyOrigin]](command.as_c_string_slice())
    argv[1] = rebind[CStringSlice[ImmutAnyOrigin]]("run".as_c_string_slice())
    argv[2] = rebind[CStringSlice[ImmutAnyOrigin]](
        include_flag.as_c_string_slice()
    )
    argv[3] = rebind[CStringSlice[ImmutAnyOrigin]](
        include_path.as_c_string_slice()
    )
    argv[4] = rebind[CStringSlice[ImmutAnyOrigin]](
        include_flag.as_c_string_slice()
    )
    argv[5] = rebind[CStringSlice[ImmutAnyOrigin]](
        vendor_include_path.as_c_string_slice()
    )
    argv[6] = rebind[CStringSlice[ImmutAnyOrigin]](entrypoint.as_c_string_slice())
    argv[7] = rebind[CStringSlice[ImmutAnyOrigin]](
        arg_port_flag.as_c_string_slice()
    )
    argv[8] = rebind[CStringSlice[ImmutAnyOrigin]](arg_port.as_c_string_slice())
    argv[9] = rebind[CStringSlice[ImmutAnyOrigin]](
        arg_mode_flag.as_c_string_slice()
    )
    argv[10] = rebind[CStringSlice[ImmutAnyOrigin]](arg_mode.as_c_string_slice())
    var stdout_read_fd = c_int(stdout_pipe.fd_in.value().value)
    var stdout_write_fd = c_int(stdout_pipe.fd_out.value().value)
    var command_ptr = command.as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv.unsafe_ptr()

    var pid = _fork()
    if pid < 0:
        raise Error("failed to spawn max_local stub")

    if pid == 0:
        if _dup2(stdout_write_fd, 1) < 0:
            _exit_child(c_int(126))
        _ = close(stdout_read_fd)
        _ = close(stdout_write_fd)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        _exit_child(c_int(127))

    stdout_pipe.set_input_only()
    var ready_line = _read_pipe_line(stdout_pipe)
    if ready_line != "ready":
        stdout_pipe.set_output_only()
        var process = Process(Int(pid))
        _ = process.wait()
        raise Error("max_local stub failed to report ready")

    stdout_pipe.set_output_only()
    return SpawnedMaxLocalStub(Int(pid))
