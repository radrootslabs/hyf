"""Strict fixture/script verification tests (ADR-0012 D29 / ADR-0014 D33).

Covers FX01-FX08 for both providers plus the in-memory mutation controls that
prove a negative control fails for the intended cause rather than for any
exception, signal or unrelated startup failure.
"""

from std.testing import TestSuite, assert_true, assert_equal

from flare.net import SocketAddr
from flare.tcp import TcpListener, TcpStream

from parent_lifecycle import open_fd_count, pid_not_waitable
from strict_fixture import (
    ExchangeScript,
    FramedRequest,
    authorization_reason,
    exchange_script,
    json_escape,
    verify_exchange,
)
from max_local_process_helper import (
    SpawnedMaxLocalStub,
    reserve_loopback_port,
    spawn_max_local_scripted,
    spawn_max_local_stub,
)
from jev_provider_helper import (
    spawn_jev_scripted_auto,
    spawn_jev_stub_auto,
)


# ── Client helpers ──────────────────────────────────────────────────────────


def _read_all(mut client: TcpStream) raises -> String:
    var buffer = InlineArray[Byte, 4096](fill=0)
    var response = String("")
    while True:
        var n = client.read(buffer.unsafe_ptr(), 4096)
        if n <= 0:
            break
        response += String(
            unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n))
        )
    return response^


def _write_all(mut client: TcpStream, text: String) raises:
    client.write_all(Span[UInt8, _](text.as_bytes()))


def _raw_exchange(port: Int, raw: String) raises -> String:
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    _write_all(client, raw)
    var response = _read_all(client)
    client.close()
    return response^


def _raw_send_only(port: Int, raw: String) raises:
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    _write_all(client, raw)
    client.close()


def _read_one_response(mut client: TcpStream) raises -> String:
    var data = String("")
    var buf = InlineArray[Byte, 1024](fill=0)
    while data.find("\r\n\r\n") < 0:
        var n = client.read(buf.unsafe_ptr(), 1024)
        if n <= 0:
            return data^
        data += String(
            unsafe_from_utf8=Span(ptr=buf.unsafe_ptr(), length=Int(n))
        )
    var header_end = data.find("\r\n\r\n")
    var length = 0
    for line in data[byte=0:header_end].split("\r\n"):
        var entry = String(line)
        if entry.lower().startswith("content-length:"):
            length = Int(String(entry[byte=15:]).strip())
    var body_start = header_end + 4
    while data.byte_length() - body_start < length:
        var n = client.read(buf.unsafe_ptr(), 1024)
        if n <= 0:
            break
        data += String(
            unsafe_from_utf8=Span(ptr=buf.unsafe_ptr(), length=Int(n))
        )
    return data^


def _request(
    port: Int,
    method: String,
    path: String,
    body: String,
    extra: String = "",
    connection: String = "close",
) raises -> String:
    var raw = (
        method
        + " "
        + path
        + " HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        + extra
        + "content-type: application/json\r\ncontent-length: "
        + String(body.byte_length())
        + "\r\nconnection: "
        + connection
        + "\r\n\r\n"
        + body
    )
    return _raw_exchange(port, raw)


def _default_script() -> ExchangeScript:
    return exchange_script(
        "expect_ok", "POST", "/v1/chat/completions", 200, '{"ok":true}'
    )


# ── Existing convenience-mode coverage ──────────────────────────────────────


def test_max_local_stub_reads_fragmented_large_body() raises:
    var stub = spawn_max_local_stub(0, "echo_body_bytes", 1)
    var body = String("")
    for _ in range(9000):
        body += "x"
    var response = _request(stub.port, "POST", "/v1/chat/completions", body)
    assert_true(response.find('"received_bytes":9000') >= 0)
    stub.wait()


def test_max_local_stub_counts_every_wire_attempt() raises:
    var requests = 3
    var stub = spawn_max_local_stub(0, "count_requests", requests)
    for index in range(requests):
        var response = _request(stub.port, "POST", "/v1/chat/completions", "{}")
        assert_true(response.find('"request_index":' + String(index + 1)) >= 0)
    stub.wait()


def test_max_local_stub_rejects_unknown_path() raises:
    # FX02/FX04: an unexpected route must fail fixture verification, not be
    # answered 404 and then reported as a successful stub run.
    var stub = spawn_max_local_stub(0, "query_rewrite_ok", 1)
    var response = _request(stub.port, "POST", "/not-a-route", "{}")
    assert_true(response.find("404") < 0)
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.phase(), "exchange")
    assert_equal(stub.reason(), "unexpected_path")


def test_max_local_stub_binds_and_reports_port() raises:
    var stub = spawn_max_local_stub(0, "count_requests", 1)
    assert_true(stub.port > 0)
    var response = _request(stub.port, "POST", "/v1/chat/completions", "{}")
    assert_true(response.find('"request_index":1') >= 0)
    stub.wait()


def test_jev_stub_observes_bearer_sentinel_at_intended_origin() raises:
    var started = spawn_jev_stub_auto("echo_authorization", 1)
    var response = _request(
        started.port,
        "POST",
        "/v1/systemone",
        "{}",
        "authorization: Bearer hyf-sentinel-token\r\n",
    )
    assert_true(response.find("hyf-sentinel-token") >= 0)
    started.stub.wait()


def test_max_local_stub_stalled_child_is_reaped() raises:
    var stub = spawn_max_local_stub(0, "stall", 1)
    _raw_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\nconnection: close\r\n\r\n{}"
        ),
    )
    stub.terminate()
    assert_true(pid_not_waitable(stub.pid))


# ── FX01: explicit ordered scripted exchanges ───────────────────────────────


def test_max_local_scripted_matches_explicit_exchange() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "explicit_ok", "POST", "/v1/chat/completions", 201, '{"made":"yes"}'
    )
    script.headers = "x-sentinel:explicit"
    script.check_body = True
    script.body = '{"q":"apples"}'
    script.response_headers = "x-scripted: yes"
    script.delay_ms = 20
    scripts.append(script^)
    var stub = spawn_max_local_scripted(0, scripts^)
    var response = _request(
        stub.port,
        "POST",
        "/v1/chat/completions",
        '{"q":"apples"}',
        "x-sentinel: explicit\r\n",
    )
    assert_true(response.find("201") >= 0)
    assert_true(response.find("x-scripted: yes") >= 0)
    assert_true(response.find('{"made":"yes"}') >= 0)
    stub.wait()
    assert_equal(stub.request_count(), 1)
    assert_equal(stub.connection_count(), 1)


def test_max_local_scripted_rejects_wrong_method() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var stub = spawn_max_local_scripted(0, scripts^)
    _raw_send_only(
        stub.port,
        (
            "GET /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\nconnection: close\r\n\r\n{}"
        ),
    )
    stub.reap()
    assert_equal(stub.phase(), "exchange")
    assert_equal(stub.reason(), "method_mismatch")


def test_max_local_scripted_rejects_wrong_path() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var stub = spawn_max_local_scripted(0, scripts^)
    _raw_send_only(
        stub.port,
        (
            "POST /v1/other HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\nconnection: close\r\n\r\n{}"
        ),
    )
    stub.reap()
    assert_equal(stub.phase(), "exchange")
    assert_equal(stub.reason(), "path_mismatch")


def test_max_local_scripted_rejects_wrong_selected_header() raises:
    var scripts = List[ExchangeScript]()
    var script = _default_script()
    script.headers = "x-sentinel:expected"
    scripts.append(script^)
    var stub = spawn_max_local_scripted(0, scripts^)
    _raw_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "x-sentinel: wrong\r\ncontent-length: 2\r\nconnection: close\r\n"
            "\r\n{}"
        ),
    )
    stub.reap()
    assert_equal(stub.phase(), "exchange")
    assert_equal(stub.reason(), "header_mismatch:x-sentinel")


def test_max_local_scripted_rejects_wrong_body() raises:
    var scripts = List[ExchangeScript]()
    var script = _default_script()
    script.check_body = True
    script.body = '{"expected":true}'
    scripts.append(script^)
    var stub = spawn_max_local_scripted(0, scripts^)
    _raw_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            'content-length: 15\r\nconnection: close\r\n\r\n{"wrong":true} '
        ),
    )
    stub.reap()
    assert_equal(stub.phase(), "exchange")
    assert_equal(stub.reason(), "body_mismatch")


# ── FX02: unexpected/extra/missing/unconsumed accounting ────────────────────


def test_scripted_rejects_extra_pipelined_exchange() raises:
    var scripts = List[ExchangeScript]()
    var script = _default_script()
    script.close_connection = False
    scripts.append(script^)
    var stub = spawn_max_local_scripted(0, scripts^)
    var first_frame = (
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 2\r\nconnection: keep-alive\r\n\r\n{}"
    )
    var second_frame = String(first_frame)
    _raw_send_only(stub.port, first_frame + second_frame)
    stub.reap()
    assert_equal(stub.phase(), "accounting")
    assert_equal(stub.reason(), "extra_exchange_after_completion")


def test_scripted_rejects_missing_exchange() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var stub = spawn_max_local_scripted(0, scripts^)
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(stub.port)))
    client.close()
    stub.reap()
    assert_equal(stub.phase(), "accounting")
    assert_equal(stub.reason(), "missing_exchanges")
    assert_equal(stub.request_count(), 0)


def test_scripted_reports_unconsumed_remaining_scripts() raises:
    var scripts = List[ExchangeScript]()
    var first = _default_script()
    first.close_connection = False
    scripts.append(first^)
    scripts.append(_default_script())
    var stub = spawn_max_local_scripted(0, scripts^)
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(stub.port)))
    _write_all(
        client,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\nconnection: keep-alive\r\n\r\n{}"
        ),
    )
    var response = _read_one_response(client)
    client.close()
    assert_true(response.find('{"ok":true}') >= 0)
    stub.reap()
    assert_equal(stub.reason(), "missing_exchanges")
    assert_equal(stub.request_count(), 1)


# ── FX03: strict lexical framing ────────────────────────────────────────────


def _framing_failure(raw: String) raises -> SpawnedMaxLocalStub:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var stub = spawn_max_local_scripted(0, scripts^)
    _raw_send_only(stub.port, raw)
    stub.reap()
    return stub^


def test_strict_framing_lexical_content_length() raises:
    var plus = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: +2\r\nconnection: close\r\n\r\n{}"
    )
    assert_equal(plus.phase(), "read")
    assert_equal(plus.reason(), "malformed_content_length")
    var spaced = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 2 3\r\nconnection: close\r\n\r\n{}"
    )
    assert_equal(spaced.reason(), "malformed_content_length")
    var empty = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length:\r\nconnection: close\r\n\r\n"
    )
    assert_equal(empty.reason(), "malformed_content_length")
    var non_digit = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 2x\r\nconnection: close\r\n\r\n{}"
    )
    assert_equal(non_digit.reason(), "malformed_content_length")
    var overflow = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 99999999999999999999\r\nconnection: close\r\n\r\n"
    )
    assert_equal(overflow.reason(), "content_length_overflow")


def test_strict_framing_versions_and_header_syntax() raises:
    var version = _framing_failure(
        "POST /v1/chat/completions NONHTTP\r\nhost: 127.0.0.1\r\n"
        "content-length: 2\r\nconnection: close\r\n\r\n{}"
    )
    assert_equal(version.phase(), "read")
    assert_equal(version.reason(), "malformed_version")
    var space_name = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost : 127.0.0.1\r\n"
        "content-length: 2\r\nconnection: close\r\n\r\n{}"
    )
    assert_equal(space_name.reason(), "malformed_header")
    var obs_fold = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        " content-length: 2\r\nconnection: close\r\n\r\n{}"
    )
    assert_equal(obs_fold.reason(), "malformed_header")


def test_strict_framing_conflicting_and_transfer_modes() raises:
    var conflicting = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 2\r\ntransfer-encoding: identity\r\n"
        "connection: close\r\n\r\n{}"
    )
    assert_equal(conflicting.reason(), "conflicting_framing")
    var chunked = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost:"
        " 127.0.0.1\r\ntransfer-encoding: chunked\r\nconnection:"
        " close\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
    )
    assert_equal(chunked.reason(), "unsupported_transfer_encoding")
    var duplicate = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "transfer-encoding: identity\r\ntransfer-encoding: identity\r\n"
        "connection: close\r\n\r\n"
    )
    assert_equal(duplicate.reason(), "duplicate_transfer_encoding")


def test_strict_framing_premature_eof() raises:
    var stub = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 100\r\nconnection: close\r\n\r\nshort"
    )
    assert_equal(stub.phase(), "read")
    assert_equal(stub.reason(), "premature_eof")


def test_strict_framing_duplicate_content_length() raises:
    var stub = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 2\r\ncontent-length: 2\r\n"
        "connection: close\r\n\r\n{}"
    )
    assert_equal(stub.phase(), "read")
    assert_equal(stub.reason(), "duplicate_content_length")


def test_strict_framing_body_cap_exceeded() raises:
    var stub = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 1048577\r\nconnection: close\r\n\r\n"
    )
    assert_equal(stub.phase(), "read")
    assert_equal(stub.reason(), "body_too_large")


def test_strict_framing_header_cap_exceeded() raises:
    var filler = String("")
    for _ in range(70000):
        filler += "a"
    var stub = _framing_failure(
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\nx-big: "
            + filler
            + "\r\n\r\n"
        )
    )
    assert_equal(stub.phase(), "read")
    assert_equal(stub.reason(), "header_too_large")


def test_jev_echo_authorization_ignores_x_authorization() raises:
    var started = spawn_jev_stub_auto("echo_authorization", 1)
    var response = _request(
        started.port,
        "POST",
        "/v1/systemone",
        "{}",
        "x-authorization: Bearer spoof\r\n",
    )
    assert_true(response.find("401") >= 0)
    assert_true(response.find("spoof") < 0)
    started.stub.wait()


def test_strict_framing_split_utf8_body() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "utf8", "POST", "/v1/chat/completions", 200, '{"ok":true}'
    )
    script.check_body = True
    var payload = String("")
    for _ in range(800):
        payload += "é"
    script.body = payload
    scripts.append(script^)
    var stub = spawn_max_local_scripted(0, scripts^)
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(stub.port)))
    var head = (
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: "
        + String(payload.byte_length())
        + "\r\nconnection: close\r\n\r\n"
    )
    _write_all(client, head)
    var payload_bytes = payload.as_bytes()
    var sent = 0
    while sent < payload.byte_length():
        var end = sent + 3
        if end > payload.byte_length():
            end = payload.byte_length()
        client.write_all(payload_bytes[sent:end])
        sent = end
    var response = _read_all(client)
    client.close()
    assert_true(response.find("200") >= 0)
    stub.wait()


def test_strict_framing_surplus_retained_for_second_frame() raises:
    var scripts = List[ExchangeScript]()
    var first = exchange_script(
        "first", "POST", "/v1/chat/completions", 200, '{"n":1}'
    )
    first.close_connection = False
    scripts.append(first^)
    var second = exchange_script(
        "second", "POST", "/v1/chat/completions", 200, '{"n":2}'
    )
    scripts.append(second^)
    var stub = spawn_max_local_scripted(0, scripts^)
    var first_frame = (
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "content-length: 2\r\nconnection: keep-alive\r\n\r\n{}"
    )
    var second_frame = String(first_frame)
    var response = _raw_exchange(stub.port, first_frame + second_frame)
    assert_true(response.find('{"n":1}') >= 0)
    assert_true(response.find('{"n":2}') >= 0)
    stub.wait()
    assert_equal(stub.request_count(), 2)
    assert_equal(stub.connection_count(), 1)


# ── FX04: route/method before auth, exact headers, safe escaping ────────────


def test_jev_scripted_wrong_route_auth_not_bypassed() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "jev_expect", "POST", "/v1/systemone", 200, '{"ok":true}'
    )
    script.require_bearer = True
    scripts.append(script^)
    var started = spawn_jev_scripted_auto(scripts^)
    _raw_send_only(
        started.port,
        (
            "POST /not-a-route HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "x-authorization: Bearer spoof\r\ncontent-length: 2\r\n"
            "connection: close\r\n\r\n{}"
        ),
    )
    started.stub.reap()
    assert_equal(started.stub.phase(), "exchange")
    assert_equal(started.stub.reason(), "path_mismatch")


def test_scripted_rejects_duplicate_authorization() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "dup_auth", "POST", "/v1/chat/completions", 200, '{"ok":true}'
    )
    script.require_bearer = True
    scripts.append(script^)
    var stub = spawn_max_local_scripted(0, scripts^)
    _raw_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "authorization: Bearer one\r\nauthorization: Bearer two\r\n"
            "content-length: 2\r\nconnection: close\r\n\r\n{}"
        ),
    )
    stub.reap()
    assert_equal(stub.phase(), "exchange")
    assert_equal(stub.reason(), "auth_duplicate")


def test_json_escape_control_characters() raises:
    assert_equal(json_escape("a\nb\tc"), '"a\\nb\\tc"')
    assert_equal(json_escape('q"uote'), '"q\\"uote"')
    assert_equal(json_escape("back\\slash"), '"back\\\\slash"')
    assert_equal(json_escape("ctl\x01"), '"ctl\\u0001"')


def test_verify_exchange_mutation_controls() raises:
    # Deliberate in-memory mutations: each must fail for its own bounded
    # reason rather than any generic exception (FX07).
    var script = exchange_script(
        "control", "POST", "/v1/chat/completions", 200, "{}"
    )
    script.headers = "x-sel:1"
    script.check_body = True
    script.body = '{"b":1}'
    var ok = FramedRequest(
        ok=True,
        error="",
        method="POST",
        path="/v1/chat/completions",
        version="HTTP/1.1",
        headers_raw="host: h\r\nx-sel:1",
        body='{"b":1}',
        content_length=7,
        keep_alive=False,
        total_bytes=0,
    )
    assert_equal(verify_exchange(script, ok), "")
    var wrong_method = FramedRequest(
        ok=True,
        error="",
        method="PUT",
        path="/v1/chat/completions",
        version="HTTP/1.1",
        headers_raw="host: h\r\nx-sel:1",
        body='{"b":1}',
        content_length=7,
        keep_alive=False,
        total_bytes=0,
    )
    assert_equal(verify_exchange(script, wrong_method), "method_mismatch")
    var wrong_path = FramedRequest(
        ok=True,
        error="",
        method="POST",
        path="/v1/other",
        version="HTTP/1.1",
        headers_raw="host: h\r\nx-sel:1",
        body='{"b":1}',
        content_length=7,
        keep_alive=False,
        total_bytes=0,
    )
    assert_equal(verify_exchange(script, wrong_path), "path_mismatch")
    var missing_header = FramedRequest(
        ok=True,
        error="",
        method="POST",
        path="/v1/chat/completions",
        version="HTTP/1.1",
        headers_raw="host: h",
        body='{"b":1}',
        content_length=7,
        keep_alive=False,
        total_bytes=0,
    )
    assert_equal(
        verify_exchange(script, missing_header), "header_missing:x-sel"
    )
    var wrong_body = FramedRequest(
        ok=True,
        error="",
        method="POST",
        path="/v1/chat/completions",
        version="HTTP/1.1",
        headers_raw="host: h\r\nx-sel:1",
        body='{"b":2}',
        content_length=7,
        keep_alive=False,
        total_bytes=0,
    )
    assert_equal(verify_exchange(script, wrong_body), "body_mismatch")
    assert_equal(
        authorization_reason(
            (
                "POST /v1/chat/completions HTTP/1.1\r\nx-authorization: Bearer"
                " spoof"
            ),
            True,
        ),
        "auth_missing",
    )
    assert_equal(
        authorization_reason(
            "POST /v1/chat/completions HTTP/1.1\r\nauthorization: Bearer t",
            True,
        ),
        "",
    )


# ── FX05: persistent reusable/close connection semantics ────────────────────


def test_scripted_persistent_counters_and_close_semantics() raises:
    var scripts = List[ExchangeScript]()
    var first = exchange_script(
        "reusable", "POST", "/v1/systemone", 200, '{"step":1}'
    )
    first.close_connection = False
    first.response_headers = "x-step: one"
    scripts.append(first^)
    var second = exchange_script(
        "close", "POST", "/v1/systemone", 200, '{"step":2}'
    )
    second.response_headers = "x-step: two"
    scripts.append(second^)
    var started = spawn_jev_scripted_auto(scripts^)
    var first_frame = (
        "POST /v1/systemone HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "authorization: Bearer t\r\ncontent-length: 2\r\n"
        "connection: keep-alive\r\n\r\n{}"
    )
    var second_frame = String(first_frame)
    var response = _raw_exchange(started.port, first_frame + second_frame)
    assert_true(response.find("x-step: one") >= 0)
    assert_true(response.find("x-step: two") >= 0)
    assert_true(response.find("connection: keep-alive") >= 0)
    assert_true(response.find("connection: close") >= 0)
    started.stub.wait()
    assert_equal(started.stub.request_count(), 2)
    assert_equal(started.stub.connection_count(), 1)


# ── FX06/FX07/FX08: parent lifecycle and cause-specific failures ────────────


def test_startup_failure_distinct_from_exchange_failure() raises:
    # Occupy a port so the fixture child cannot bind; the parent must observe
    # a startup failure (no ready line), not a script/parser rejection.
    var blocker = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(blocker.local_addr().port)
    var raised = False
    try:
        var stub = spawn_max_local_stub(port, "count_requests", 1)
        stub.terminate()
    except:
        raised = True
    blocker.close()
    assert_true(raised)


def test_owned_child_reaped_after_early_terminate() raises:
    var stub = spawn_max_local_stub(0, "count_requests", 1)
    stub.terminate()
    assert_true(pid_not_waitable(stub.pid))


def test_repeated_failures_leave_no_owned_child() raises:
    for _ in range(3):
        var scripts = List[ExchangeScript]()
        scripts.append(_default_script())
        var stub = spawn_max_local_scripted(0, scripts^)
        _raw_send_only(
            stub.port,
            (
                "POST /v1/nope HTTP/1.1\r\nhost: 127.0.0.1\r\n"
                "content-length: 2\r\nconnection: close\r\n\r\n{}"
            ),
        )
        stub.reap()
        assert_true(not stub.ok())
        assert_equal(stub.reason(), "path_mismatch")
        assert_true(pid_not_waitable(stub.pid))


def test_repeated_teardown_does_not_leak_descriptors() raises:
    var before = open_fd_count()
    assert_true(before > 0)
    for _ in range(5):
        var stub = spawn_max_local_stub(0, "count_requests", 1)
        stub.terminate()
        assert_true(pid_not_waitable(stub.pid))
    var after = open_fd_count()
    assert_true(after > 0)
    assert_true(after <= before)


def test_timeout_terminates_and_reaps_stalled_child() raises:
    var stub = spawn_max_local_stub(0, "stall", 1)
    _raw_send_only(
        stub.port,
        (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\nconnection: close\r\n\r\n{}"
        ),
    )
    stub.terminate()
    assert_true(pid_not_waitable(stub.pid))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
