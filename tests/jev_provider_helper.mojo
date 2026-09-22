import std.os
from std.ffi import c_int, c_size_t, c_ssize_t, c_uint, external_call
from std.os import Pipe, Process
from std.sys._libc import close

from flare.net import SocketAddr
from flare.tcp import TcpListener, TcpStream
from flare.utils import usleep

from strict_fixture import ConnectionReader, FramedRequest, bearer_token


def _dup2(oldfd: c_int, newfd: c_int) -> c_int:
    return external_call["dup2", c_int](oldfd, newfd)


@always_inline
def _fork() -> c_int:
    return external_call["fork", c_int]()


@always_inline
def _alarm(seconds: c_uint) -> c_uint:
    return external_call["alarm", c_uint](seconds)


@always_inline
def _exit_child(code: c_int):
    _ = external_call["_exit", c_int](code)


def _write(fd: Int, text: String):
    _ = external_call["write", c_ssize_t](
        fd, text.as_bytes().unsafe_ptr(), c_size_t(text.byte_length())
    )


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


def _json_string(value: String) -> String:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _analysis() -> String:
    return (
        '{"model":"jev-1.13.0","answers":{'
        '"supply_status":{"type":"choice","choice":"offered","probabilities":{"offered":1.0,"forecast":0.0,"unclear":0.0},"confidence":1.0},'
        '"seconds_ok":{"type":"noul","noul":0.9},'
        '"culinary_fit":{"type":"score","score":2,"legend":{"0":"u","1":"l","2":"s"},"probabilities":{"0":0.0,"1":0.0,"2":1.0},"confidence":1.0}},'
        '"usage":{"input_tokens":10,"output_tokens":5}}'
    )


def _response(status: Int, body: String) -> String:
    var reason = "OK"
    if status == 401:
        reason = "Unauthorized"
    elif status == 429:
        reason = "Too Many Requests"
    elif status == 500:
        reason = "Internal Server Error"
    elif status == 529:
        reason = "Overloaded"
    return (
        "HTTP/1.1 "
        + String(status)
        + " "
        + reason
        + "\r\ncontent-type: application/json\r\ncontent-length: "
        + String(body.byte_length())
        + "\r\nconnection: close\r\n\r\n"
        + body
    )


def _send(mut reader: ConnectionReader, status: Int, body: String) raises:
    reader.write_all(_response(status, body))


def _send_raw(mut reader: ConnectionReader, response: String) raises:
    reader.write_all(response)


def _handle(
    mut reader: ConnectionReader, mode: String, framed: FramedRequest
) raises:
    var path = framed.path
    if mode == "echo_authorization":
        var token = bearer_token(framed.headers_raw)
        if token == "":
            _send(reader, 401, '{"error":{"message":"missing authorization"}}')
        else:
            _send(reader, 200, '{"authorization":' + _json_string(token) + "}")
        return
    if path != "/v1/systemone":
        _send(reader, 404, '{"error":{"message":"not found"}}')
        return

    if mode == "ok":
        _send(reader, 200, _analysis())
    elif mode == "rate_limit":
        _send(reader, 429, '{"error":{"message":"slow down"}}')
    elif mode == "server_error":
        _send(reader, 500, '{"error":{"message":"boom"}}')
    elif mode == "overloaded":
        _send(reader, 529, '{"error":{"message":"overloaded"}}')
    elif mode == "auth":
        _send(reader, 401, '{"error":{"message":"bad key"}}')
    elif mode == "malformed_json":
        _send(reader, 200, "not json")
    elif mode == "model_mismatch":
        _send(reader, 200, _analysis().replace("jev-1.13.0", "jev-other"))
    elif mode == "truncated":
        var truncated = (
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n"
            "content-length: 999\r\nconnection: close\r\n\r\n"
            '{"model":"jev'
        )
        reader.write_all(truncated)
    elif mode == "redirect":
        reader.write_all(
            "HTTP/1.1 302 Found\r\nlocation:"
            " http://127.0.0.1:1/steal\r\ncontent-length:"
            " 0\r\nconnection: close\r\n\r\n"
        )
    elif mode == "slow":
        usleep(2_000_000)
        _send(reader, 200, _analysis())
    else:
        _send(reader, 500, '{"error":{"message":"unsupported_mode"}}')


def _serve(port: Int, mode: String, requests: Int) raises:
    var listener = TcpListener.bind(SocketAddr.localhost(UInt16(port)))
    var actual_port = Int(listener.local_addr().port)
    _write(1, "ready " + String(actual_port) + "\n")
    var request_count = 0
    while request_count < requests:
        var stream = listener.accept()
        var reader = ConnectionReader(stream^)
        while request_count < requests:
            var framed = reader.read()
            if not framed.ok:
                if framed.error == "empty":
                    break
                raise Error("strict fixture framing error: " + framed.error)
            request_count += 1
            _handle(reader, mode, framed)
            if not framed.keep_alive:
                break
    listener.close()


struct SpawnedJevStub(Movable):
    var pid: Int

    def __init__(out self, pid: Int):
        self.pid = pid

    def wait(mut self) raises:
        var process = Process(self.pid)
        var status = process.wait()
        if not status.exit_code or status.exit_code.value() != 0:
            raise Error("jev stub exited unexpectedly")


def reserve_jev_port() raises -> Int:
    var listener = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(listener.local_addr().port)
    listener.close()
    return port


@fieldwise_init
struct SpawnedJevStubAuto(Movable):
    var port: Int
    var stub: SpawnedJevStub


def spawn_jev_stub_auto(
    mode: String, requests: Int
) raises -> SpawnedJevStubAuto:
    return _spawn_jev_stub(0, mode, requests)


def spawn_jev_stub(
    port: Int, mode: String, requests: Int
) raises -> SpawnedJevStub:
    var started = _spawn_jev_stub(port, mode, requests)
    return started.stub^


def _spawn_jev_stub(
    port: Int, mode: String, requests: Int
) raises -> SpawnedJevStubAuto:
    var stdout_pipe = Pipe()
    var stdout_read_fd = c_int(stdout_pipe.fd_in.value().value)
    var stdout_write_fd = c_int(stdout_pipe.fd_out.value().value)
    var pid = _fork()
    if pid < 0:
        raise Error("failed to spawn jev stub")
    if pid == 0:
        if _dup2(stdout_write_fd, 1) < 0:
            _exit_child(c_int(126))
        _ = close(stdout_read_fd)
        _ = close(stdout_write_fd)
        _ = _alarm(c_uint(20))
        try:
            _serve(port, mode, requests)
            _exit_child(c_int(0))
        except:
            _exit_child(c_int(125))
    stdout_pipe.set_input_only()
    var ready_line = _read_pipe_line(stdout_pipe)
    if not ready_line.startswith("ready"):
        stdout_pipe.set_output_only()
        var process = Process(Int(pid))
        _ = process.wait()
        raise Error("jev stub failed to report ready")
    var reported_port = port
    var space = ready_line.find(" ")
    if space >= 0:
        reported_port = Int(String(ready_line[byte = space + 1 :]))
    stdout_pipe.set_output_only()
    return SpawnedJevStubAuto(port=reported_port, stub=SpawnedJevStub(Int(pid)))
