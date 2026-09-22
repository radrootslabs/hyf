from std.ffi import c_int, c_size_t, c_ssize_t, c_uint, external_call
from std.os import Pipe, Process
from std.sys._libc import close

from flare.net import SocketAddr
from flare.tcp import TcpListener
from flare.tcp import TcpStream
from flare.utils import usleep

from strict_fixture import ConnectionReader, FramedRequest, bearer_token


def _dup2(oldfd: c_int, newfd: c_int) -> c_int:
    return external_call["dup2", c_int](oldfd, newfd)


@always_inline
def _fork() -> c_int:
    return external_call["fork", c_int]()


@always_inline
def _kill(pid: c_int, sig: c_int) -> c_int:
    return external_call["kill", c_int](pid, sig)


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


def _query_rewrite_analysis() -> String:
    return (
        '{"original_text":"local apples pickup weekend",'
        '"normalized_text":"local apples pickup weekend",'
        '"rewritten_text":"apples pickup weekend",'
        '"query_terms":["apples","pickup","weekend"],'
        '"normalization_signals":["lowercase","local_intent_detected"],'
        '"ranking_hints":["prefer_local_results","prefer_pickup"],'
        '"extracted_filters":{'
        '"local_intent":true,'
        '"fulfillment":"pickup",'
        '"time_window":"weekend"'
        "}}"
    )


def _chat_completion(body: String) -> String:
    return '{"choices":[{"message":{"content":' + _json_string(body) + "}}]}"


def _response(status: Int, body: String) -> String:
    var reason = "OK"
    if status == 401:
        reason = "Unauthorized"
    elif status == 404:
        reason = "Not Found"
    elif status == 500:
        reason = "Internal Server Error"
    elif status == 503:
        reason = "Service Unavailable"
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


def _handle_health(mut reader: ConnectionReader, mode: String) raises:
    if mode == "health_non_2xx":
        _send(reader, 503, '{"status":"unavailable"}')
    elif mode == "health_timeout":
        usleep(1_000_000)
    elif mode == "health_malformed_http":
        _send_raw(reader, "not an http response\r\n\r\n")
    elif mode == "query_rewrite_remaining_deadline_timeout":
        usleep(200_000)
        _send(reader, 200, '{"status":"ok"}')
    else:
        _send(reader, 200, '{"status":"ok"}')


def _handle_chat_completions(mut reader: ConnectionReader, mode: String) raises:
    if mode == "query_rewrite_ok":
        _send(reader, 200, _chat_completion(_query_rewrite_analysis()))
    elif mode == "query_rewrite_non_2xx":
        _send(reader, 503, '{"error":{"message":"provider unavailable"}}')
    elif mode == "query_rewrite_invalid_json":
        _send(reader, 200, '{"choices":[{"message":{"content":"not json"}}]}')
    elif mode == "query_rewrite_schema_invalid":
        var body = (
            '{"original_text":"local apples pickup weekend",'
            '"normalized_text":"local apples pickup weekend",'
            '"query_terms":["apples","pickup","weekend"],'
            '"normalization_signals":["lowercase","local_intent_detected"],'
            '"ranking_hints":["prefer_local_results","prefer_pickup"],'
            '"extracted_filters":{'
            '"local_intent":true,'
            '"fulfillment":"pickup",'
            '"time_window":"weekend"'
            "}}"
        )
        _send(reader, 200, _chat_completion(body))
    elif mode == "query_rewrite_top_level_string":
        _send(reader, 200, '"not object"')
    elif mode == "query_rewrite_top_level_array":
        _send(reader, 200, "[]")
    elif mode == "query_rewrite_top_level_null":
        _send(reader, 200, "null")
    elif mode == "query_rewrite_empty_choices":
        _send(reader, 200, '{"choices":[]}')
    elif mode == "query_rewrite_missing_content":
        _send(reader, 200, '{"choices":[{"message":{}}]}')
    elif mode == "query_rewrite_error_payload":
        _send(reader, 200, '{"error":{"message":"provider refusal"}}')
    elif mode == "query_rewrite_timeout":
        usleep(2_000_000)
        _send(reader, 200, _chat_completion(_query_rewrite_analysis()))
    elif mode == "query_rewrite_remaining_deadline_timeout":
        usleep(400_000)
        _send(reader, 200, _chat_completion(_query_rewrite_analysis()))
    elif mode == "query_rewrite_malformed_http":
        _send_raw(reader, "not an http response\r\n\r\n")
    else:
        _send(reader, 500, '{"error":"unsupported_mode"}')


def _handle_framed(
    mut reader: ConnectionReader,
    mode: String,
    request_index: Int,
    connection_index: Int,
    framed: FramedRequest,
) raises:
    var path = framed.path
    if mode == "echo_body_bytes":
        _send(
            reader,
            200,
            '{"received_bytes":' + String(framed.body.byte_length()) + "}",
        )
    elif mode == "count_requests":
        _send(
            reader,
            200,
            '{"request_index":'
            + String(request_index)
            + ',"connection_index":'
            + String(connection_index)
            + "}",
        )
    elif mode == "echo_authorization":
        var token = bearer_token(framed.headers_raw)
        if token == "":
            _send(reader, 401, '{"error":"missing_authorization"}')
        else:
            _send(reader, 200, '{"authorization":' + _json_string(token) + "}")
    elif mode == "stall":
        usleep(30_000_000)
    elif path == "/health":
        _handle_health(reader, mode)
    elif path == "/v1/chat/completions":
        _handle_chat_completions(reader, mode)
    else:
        _send(reader, 404, '{"error":"not_found"}')


def _serve_max_local_stub(port: Int, mode: String, requests: Int) raises:
    var listener = TcpListener.bind(SocketAddr.localhost(UInt16(port)))
    var actual_port = Int(listener.local_addr().port)
    _write(1, "ready " + String(actual_port) + "\n")
    var request_count = 0
    var connection_count = 0
    while request_count < requests:
        var stream = listener.accept()
        connection_count += 1
        var reader = ConnectionReader(stream^)
        while request_count < requests:
            var framed = reader.read()
            if not framed.ok:
                if framed.error == "empty":
                    break
                raise Error("strict fixture framing error: " + framed.error)
            request_count += 1
            _handle_framed(
                reader, mode, request_count, connection_count, framed
            )
            if not framed.keep_alive:
                break
    listener.close()


struct SpawnedMaxLocalStub(Movable):
    var pid: Int
    var port: Int

    def __init__(out self, pid: Int, port: Int):
        self.pid = pid
        self.port = port

    def wait(mut self) raises:
        var process = Process(self.pid)
        var status = process.wait()
        if not status.exit_code or status.exit_code.value() != 0:
            raise Error("max_local stub exited unexpectedly")

    def terminate(mut self) raises:
        _ = _kill(c_int(self.pid), c_int(15))
        var process = Process(self.pid)
        _ = process.wait()


def reserve_loopback_port() raises -> Int:
    var listener = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(listener.local_addr().port)
    listener.close()
    return port


def spawn_max_local_stub(
    port: Int, mode: String, requests: Int
) raises -> SpawnedMaxLocalStub:
    var stdout_pipe = Pipe()
    var stdout_read_fd = c_int(stdout_pipe.fd_in.value().value)
    var stdout_write_fd = c_int(stdout_pipe.fd_out.value().value)

    var pid = _fork()
    if pid < 0:
        raise Error("failed to spawn max_local stub")

    if pid == 0:
        if _dup2(stdout_write_fd, 1) < 0:
            _exit_child(c_int(126))
        _ = close(stdout_read_fd)
        _ = close(stdout_write_fd)
        _ = _alarm(c_uint(20))
        try:
            _serve_max_local_stub(port, mode, requests)
            _exit_child(c_int(0))
        except:
            _exit_child(c_int(125))

    stdout_pipe.set_input_only()
    var ready_line = _read_pipe_line(stdout_pipe)
    if not ready_line.startswith("ready"):
        stdout_pipe.set_output_only()
        var process = Process(Int(pid))
        _ = process.wait()
        raise Error("max_local stub failed to report ready")

    var reported_port = port
    var space = ready_line.find(" ")
    if space >= 0:
        reported_port = Int(String(ready_line[byte = space + 1 :]))

    stdout_pipe.set_output_only()
    return SpawnedMaxLocalStub(Int(pid), reported_port)
