from std.ffi import c_int, c_size_t, c_ssize_t, external_call
from std.os import Pipe, Process
from std.sys._libc import close

from flare.net import SocketAddr
from flare.tcp import TcpListener
from flare.tcp import TcpStream
from flare.utils import usleep


def _dup2(oldfd: c_int, newfd: c_int) -> c_int:
    return external_call["dup2", c_int](oldfd, newfd)


@always_inline
def _fork() -> c_int:
    return external_call["fork", c_int]()


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


comptime MAX_TEST_REQUEST_BYTES = 1048576


def _read_request(mut stream: TcpStream) raises -> String:
    var bytes = List[UInt8]()
    var chunk = InlineArray[Byte, 4096](fill=0)
    var expected_total = -1
    while True:
        var n = stream.read(chunk.unsafe_ptr(), 4096)
        if n <= 0:
            break
        for index in range(Int(n)):
            bytes.append(chunk[index])
        if len(bytes) > MAX_TEST_REQUEST_BYTES:
            break
        var text = String(unsafe_from_utf8=bytes[:])
        var header_end = text.find("\r\n\r\n")
        if header_end >= 0 and expected_total < 0:
            var lowered = text.lower()
            var marker = lowered.find("content-length:")
            var content_length = 0
            if marker >= 0:
                var rest = String(text[byte = marker + 15 :])
                var line_end = rest.find("\r\n")
                var value = rest if line_end < 0 else String(
                    rest[byte=0:line_end]
                )
                content_length = Int(String(String(value).strip()))
            expected_total = header_end + 4 + content_length
        if expected_total >= 0 and len(bytes) >= expected_total:
            break
    if len(bytes) == 0:
        return ""
    return String(unsafe_from_utf8=bytes[:])


def _request_body(request: String) -> String:
    var header_end = request.find("\r\n\r\n")
    if header_end < 0:
        return ""
    return String(request[byte = header_end + 4 :])


def _request_path(request: String) -> String:
    var line_end = request.find("\r\n")
    if line_end < 0:
        return ""
    var first_line = String(request[byte=0:line_end])
    var first_space = first_line.find(" ")
    if first_space < 0:
        return ""
    var rest = String(first_line[byte = first_space + 1 :])
    var second_space = rest.find(" ")
    if second_space < 0:
        return ""
    return String(rest[byte=0:second_space])


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
    if status == 404:
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


def _send(mut stream: TcpStream, status: Int, body: String) raises:
    var response = _response(status, body)
    stream.write_all(Span[UInt8, _](response.as_bytes()))


def _send_raw(mut stream: TcpStream, response: String) raises:
    stream.write_all(Span[UInt8, _](response.as_bytes()))


def _handle_health(mut stream: TcpStream, mode: String) raises:
    if mode == "health_non_2xx":
        _send(stream, 503, '{"status":"unavailable"}')
    elif mode == "health_timeout":
        usleep(1_000_000)
    elif mode == "health_malformed_http":
        _send_raw(stream, "not an http response\r\n\r\n")
    elif mode == "query_rewrite_remaining_deadline_timeout":
        usleep(200_000)
        _send(stream, 200, '{"status":"ok"}')
    else:
        _send(stream, 200, '{"status":"ok"}')


def _handle_chat_completions(mut stream: TcpStream, mode: String) raises:
    if mode == "query_rewrite_ok":
        _send(stream, 200, _chat_completion(_query_rewrite_analysis()))
    elif mode == "query_rewrite_non_2xx":
        _send(stream, 503, '{"error":{"message":"provider unavailable"}}')
    elif mode == "query_rewrite_invalid_json":
        _send(stream, 200, '{"choices":[{"message":{"content":"not json"}}]}')
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
        _send(stream, 200, _chat_completion(body))
    elif mode == "query_rewrite_top_level_string":
        _send(stream, 200, '"not object"')
    elif mode == "query_rewrite_top_level_array":
        _send(stream, 200, "[]")
    elif mode == "query_rewrite_top_level_null":
        _send(stream, 200, "null")
    elif mode == "query_rewrite_empty_choices":
        _send(stream, 200, '{"choices":[]}')
    elif mode == "query_rewrite_missing_content":
        _send(stream, 200, '{"choices":[{"message":{}}]}')
    elif mode == "query_rewrite_error_payload":
        _send(stream, 200, '{"error":{"message":"provider refusal"}}')
    elif mode == "query_rewrite_timeout":
        usleep(2_000_000)
        _send(stream, 200, _chat_completion(_query_rewrite_analysis()))
    elif mode == "query_rewrite_remaining_deadline_timeout":
        usleep(400_000)
        _send(stream, 200, _chat_completion(_query_rewrite_analysis()))
    elif mode == "query_rewrite_malformed_http":
        _send_raw(stream, "not an http response\r\n\r\n")
    else:
        _send(stream, 500, '{"error":"unsupported_mode"}')


def _handle_request(mut stream: TcpStream, mode: String, index: Int) raises:
    var request = _read_request(stream)
    var path = _request_path(request)
    if mode == "echo_body_bytes":
        _send(
            stream,
            200,
            '{"received_bytes":'
            + String(_request_body(request).byte_length())
            + "}",
        )
    elif mode == "count_requests":
        _send(stream, 200, '{"request_index":' + String(index + 1) + "}")
    elif path == "/health":
        _handle_health(stream, mode)
    elif path == "/v1/chat/completions":
        _handle_chat_completions(stream, mode)
    else:
        _send(stream, 404, '{"error":"not_found"}')
    stream.close()


def _serve_max_local_stub(port: Int, mode: String, requests: Int) raises:
    var listener = TcpListener.bind(SocketAddr.localhost(UInt16(port)))
    var actual_port = Int(listener.local_addr().port)
    _write(1, "ready " + String(actual_port) + "\n")
    for request_index in range(requests):
        var stream = listener.accept()
        _handle_request(stream, mode, request_index)
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
