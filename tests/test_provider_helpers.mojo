from std.testing import TestSuite, assert_true

from flare.net import SocketAddr
from flare.tcp import TcpStream

from max_local_process_helper import spawn_max_local_stub
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
    assert_true(response.find("Bearer hyf-sentinel-token") >= 0)
    started.stub.wait()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
