from std.testing import TestSuite, assert_true

from flare.net import SocketAddr
from flare.tcp import TcpStream

from max_local_process_helper import (
    SpawnedMaxLocalStub,
    spawn_max_local_stub,
)
from jev_provider_helper import spawn_jev_stub_auto


def _client_request(
    port: Int, path: String, body: String, auth: String = ""
) raises -> String:
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    var auth_line = "" if auth == "" else "authorization: " + auth + "\r\n"
    var headers = (
        "POST "
        + path
        + " HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        + auth_line
        + "content-type: application/json\r\ncontent-length: "
        + String(body.byte_length())
        + "\r\nconnection: close\r\n\r\n"
    )
    client.write_all(Span[UInt8, _](headers.as_bytes()))
    var sent = 0
    while sent < body.byte_length():
        var end = sent + 3000
        if end > body.byte_length():
            end = body.byte_length()
        client.write_all(Span[UInt8, _](body[byte=sent:end].as_bytes()))
        sent = end
    var buffer = InlineArray[Byte, 4096](fill=0)
    var response = String("")
    while True:
        var n = client.read(buffer.unsafe_ptr(), 4096)
        if n <= 0:
            break
        response += String(
            unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n))
        )
    client.close()
    return response^


def test_max_local_stub_reads_fragmented_large_body() raises:
    var stub = spawn_max_local_stub(0, "echo_body_bytes", 1)
    var body = String("")
    for _ in range(9000):
        body += "x"
    var response = _client_request(stub.port, "/v1/chat/completions", body)
    assert_true(response.find('"received_bytes":9000') >= 0)
    stub.wait()


def test_max_local_stub_counts_every_wire_attempt() raises:
    var requests = 3
    var stub = spawn_max_local_stub(0, "count_requests", requests)
    for index in range(requests):
        var response = _client_request(stub.port, "/v1/chat/completions", "{}")
        assert_true(response.find('"request_index":' + String(index + 1)) >= 0)
    stub.wait()


def test_max_local_stub_rejects_unknown_path() raises:
    var stub = spawn_max_local_stub(0, "query_rewrite_ok", 1)
    var response = _client_request(stub.port, "/not-a-route", "{}")
    assert_true(response.find("404") >= 0)
    assert_true(response.find('"not_found"') >= 0)
    stub.wait()


def test_max_local_stub_binds_and_reports_port() raises:
    var stub = spawn_max_local_stub(0, "count_requests", 1)
    assert_true(stub.port > 0)
    var response = _client_request(stub.port, "/v1/chat/completions", "{}")
    assert_true(response.find('"request_index":1') >= 0)
    stub.wait()


def test_jev_stub_observes_bearer_sentinel_at_intended_origin() raises:
    var started = spawn_jev_stub_auto("echo_authorization", 1)
    var response = _client_request(
        started.port, "/v1/systemone", "{}", "Bearer hyf-sentinel-token"
    )
    assert_true(response.find("hyf-sentinel-token") >= 0)
    started.stub.wait()


def _client_send_raw(port: Int, data: String) raises -> String:
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    client.write_all(Span[UInt8, _](data.as_bytes()))
    var buffer = InlineArray[Byte, 4096](fill=0)
    var response = String("")
    while True:
        var n = client.read(buffer.unsafe_ptr(), 4096)
        if n <= 0:
            break
        response += String(
            unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n))
        )
    client.close()
    return response^


def _client_two_on_one(port: Int, path: String) raises -> String:
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    var body = "{}"
    var first = (
        "POST "
        + path
        + " HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type:"
        " application/json\r\ncontent-length: "
        + String(body.byte_length())
        + "\r\nconnection: keep-alive\r\n\r\n"
        + body
    )
    var second = (
        "POST "
        + path
        + " HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type:"
        " application/json\r\ncontent-length: "
        + String(body.byte_length())
        + "\r\nconnection: close\r\n\r\n"
        + body
    )
    client.write_all(Span[UInt8, _](first.as_bytes()))
    client.write_all(Span[UInt8, _](second.as_bytes()))
    var buffer = InlineArray[Byte, 4096](fill=0)
    var response = String("")
    while True:
        var n = client.read(buffer.unsafe_ptr(), 4096)
        if n <= 0:
            break
        response += String(
            unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n))
        )
    client.close()
    return response^


def _stub_failed(mut stub: SpawnedMaxLocalStub) raises -> Bool:
    try:
        stub.wait()
        return False
    except:
        return True


def _client_send_only(port: Int, data: String) raises:
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    client.write_all(Span[UInt8, _](data.as_bytes()))
    client.close()


def test_max_local_strict_rejects_truncated_frame() raises:
    var stub = spawn_max_local_stub(0, "echo_body_bytes", 1)
    _client_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 100\r\nconnection: close\r\n\r\nshort"
        ),
    )
    assert_true(_stub_failed(stub))


def test_max_local_strict_rejects_duplicate_content_length() raises:
    var stub = spawn_max_local_stub(0, "echo_body_bytes", 1)
    _client_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\ncontent-length: 2\r\n"
            "connection: close\r\n\r\n{}"
        ),
    )
    assert_true(_stub_failed(stub))


def test_max_local_strict_rejects_oversize_body() raises:
    var stub = spawn_max_local_stub(0, "echo_body_bytes", 1)
    _client_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2097152\r\nconnection: close\r\n\r\n"
        ),
    )
    assert_true(_stub_failed(stub))


def test_max_local_strict_persistent_exchanges_distinct_counters() raises:
    var stub = spawn_max_local_stub(0, "count_requests", 2)
    var response = _client_two_on_one(stub.port, "/v1/chat/completions")
    assert_true(response.find('"request_index":1') >= 0)
    assert_true(response.find('"request_index":2') >= 0)
    assert_true(response.find('"connection_index":1') >= 0)
    assert_true(response.find('"connection_index":2') < 0)
    stub.wait()


def test_jev_strict_rejects_x_authorization() raises:
    var started = spawn_jev_stub_auto("echo_authorization", 1)
    var response = _client_send_raw(
        started.port,
        (
            "POST /v1/systemone HTTP/1.1\r\nhost: 127.0.0.1\r\nx-authorization:"
            " Bearer spoof\r\ncontent-type: application/json\r\ncontent-length:"
            " 2\r\nconnection: close\r\n\r\n{}"
        ),
    )
    assert_true(response.find("401") >= 0)
    assert_true(response.find("spoof") < 0)
    started.stub.wait()


def test_max_local_stub_stalled_child_is_reaped() raises:
    var stub = spawn_max_local_stub(0, "stall", 1)
    _client_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\nconnection: close\r\n\r\n{}"
        ),
    )
    stub.terminate()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
