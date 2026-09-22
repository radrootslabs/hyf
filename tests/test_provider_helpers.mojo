"""Strict fixture/script verification tests (ADR-0012 D29 / ADR-0014 D33).

Covers FX01-FX08 for both providers plus the in-memory mutation controls that
prove a negative control fails for the intended cause rather than for any
exception, signal or unrelated startup failure.
"""

from std.testing import TestSuite, assert_true, assert_equal
from std.ffi import ErrNo, c_int, external_call

from flare.net import SocketAddr
from flare.net.socket import RawSocket
from flare.tcp import TcpListener, TcpStream

from parent_lifecycle import (
    PipedChildState,
    ProcessStatus,
    child_exit,
    classify_wait_errno,
    close_fd,
    descriptor_census,
    dup2_fd,
    fork_owned_or_close,
    fork_pid,
    make_pipe,
    make_three_pipes,
    open_fd_count,
    open_fd_count_checked,
    parse_ready_line,
    parse_ready_or_cleanup,
    pid_not_waitable,
    read_all_bounded,
    read_line_bounded,
    sleep_ms,
    wait_nohang,
    write_fd_bounded,
    write_raw,
)
from strict_fixture import (
    ConnectionReader,
    ExchangeScript,
    FramedRequest,
    authorization_reason,
    exchange_script,
    json_escape,
    parse_report,
    report_status_matches_exit,
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


@fieldwise_init
struct FramingFailure(Movable):
    """Bounded snapshot of a fixture read failure for post-scope asserts."""

    var ok: Bool
    var phase_value: String
    var case_value: String
    var reason_value: String
    var requests: Int
    var connections: Int

    def phase(self) -> String:
        return String(self.phase_value)

    def reason(self) -> String:
        return String(self.reason_value)

    def failure_case(self) -> String:
        return String(self.case_value)


# ── Existing convenience-mode coverage ──────────────────────────────────────


def test_max_local_stub_reads_fragmented_large_body() raises:
    with spawn_max_local_stub(0, "echo_body_bytes", 1) as stub:
        var body = String("")
        for _ in range(9000):
            body += "x"
        var response = _request(stub.port, "POST", "/v1/chat/completions", body)
        assert_true(response.find('"received_bytes":9000') >= 0)
        stub.wait()


def test_max_local_stub_counts_every_wire_attempt() raises:
    var requests = 3
    with spawn_max_local_stub(0, "count_requests", requests) as stub:
        for index in range(requests):
            var response = _request(
                stub.port, "POST", "/v1/chat/completions", "{}"
            )
            assert_true(
                response.find('"request_index":' + String(index + 1)) >= 0
            )
        stub.wait()


def test_max_local_stub_rejects_unknown_path() raises:
    # FX02/FX04: an unexpected route must fail fixture verification, not be
    # answered 404 and then reported as a successful stub run.
    with spawn_max_local_stub(0, "query_rewrite_ok", 1) as stub:
        var response = _request(stub.port, "POST", "/not-a-route", "{}")
        assert_true(response.find("404") < 0)
        stub.reap()
        assert_true(not stub.ok())
        assert_equal(stub.phase(), "exchange")
        assert_equal(stub.reason(), "unexpected_path")


def test_max_local_stub_binds_and_reports_port() raises:
    with spawn_max_local_stub(0, "count_requests", 1) as stub:
        assert_true(stub.port > 0)
        var response = _request(stub.port, "POST", "/v1/chat/completions", "{}")
        assert_true(response.find('"request_index":1') >= 0)
        stub.wait()


def test_jev_stub_observes_bearer_sentinel_at_intended_origin() raises:
    with spawn_jev_stub_auto("echo_authorization", 1) as started:
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
    with spawn_max_local_stub(0, "stall", 1) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
        _raw_send_only(
            stub.port,
            (
                "POST /v1/chat/completions HTTP/1.1\r\nhost:"
                " 127.0.0.1\r\nx-sentinel: wrong\r\ncontent-length:"
                " 2\r\nconnection: close\r\n\r\n{}"
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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


def _framing_failure(raw: String) raises -> FramingFailure:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    with spawn_max_local_scripted(0, scripts^) as stub:
        _raw_send_only(stub.port, raw)
        stub.reap()
        return FramingFailure(
            stub.ok(),
            stub.phase(),
            stub.failure_case(),
            stub.reason(),
            stub.request_count(),
            stub.connection_count(),
        )


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
    with spawn_jev_stub_auto("echo_authorization", 1) as started:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_jev_scripted_auto(scripts^) as started:
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
    with spawn_max_local_scripted(0, scripts^) as stub:
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
    with spawn_jev_scripted_auto(scripts^) as started:
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
    # a bounded startup/serve_failed report, not a generic exception or a
    # script/parser rejection (FX07 / R61).
    var blocker = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(blocker.local_addr().port)
    var message = ""
    try:
        with spawn_max_local_stub(port, "count_requests", 1) as stub:
            stub.terminate()
    except e:
        message = String(e)
    blocker.close()
    assert_true(message.find("phase=startup") >= 0)
    assert_true(message.find("reason=serve_failed") >= 0)
    assert_true(message.find("exited=") >= 0 or message.find("signal=") >= 0)


def test_provider_stub_parent_deadline_watchdog() raises:
    # No client connects, so the child blocks in accept until the parent's own
    # finite deadline fires and the owned child is terminated and reaped.
    with spawn_max_local_stub(0, "count_requests", 1, 800) as stub:
        stub.reap()
        assert_true(not stub.ok())
        assert_equal(stub.phase(), "watchdog")
        assert_equal(stub.reason(), "timeout")
        assert_true(pid_not_waitable(stub.pid))


def test_jev_stub_parent_deadline_watchdog() raises:
    with spawn_jev_stub_auto("ok", 1, 800) as started:
        started.stub.reap()
        assert_true(not started.stub.ok())
        assert_equal(started.stub.phase(), "watchdog")
        assert_equal(started.stub.reason(), "timeout")
        assert_true(pid_not_waitable(started.stub.pid))


def test_bounded_read_caps_fail_for_intended_cause() raises:
    var ready_pipe = make_pipe()
    write_raw(ready_pipe.write_fd, "no newline here")
    var ready_message = ""
    try:
        _ = read_line_bounded(ready_pipe.read_fd, 8, 500)
    except e:
        ready_message = String(e)
    close_fd(ready_pipe.read_fd)
    close_fd(ready_pipe.write_fd)
    assert_true(ready_message.find("ready_output_overflow") >= 0)

    var stdout_pipe = make_pipe()
    write_raw(stdout_pipe.write_fd, "0123456789")
    close_fd(stdout_pipe.write_fd)
    var stdout_message = ""
    try:
        _ = read_all_bounded(stdout_pipe.read_fd, 4, 500)
    except e:
        stdout_message = String(e)
    close_fd(stdout_pipe.read_fd)
    assert_true(stdout_message.find("stdout_overflow") >= 0)


def test_write_deadline_and_closed_pipe_causes() raises:
    var closed = make_pipe()
    close_fd(closed.read_fd)
    var closed_reason = write_fd_bounded(closed.write_fd, "payload", 500)
    close_fd(closed.write_fd)
    assert_true(
        closed_reason == "write_pipe_closed" or closed_reason == "write_failed"
    )

    var full = make_pipe()
    var payload = String("")
    for _ in range(1024):
        payload += "y"
    for _ in range(7):
        var doubled = String(payload)
        payload = payload + doubled
    var deadline_reason = write_fd_bounded(full.write_fd, payload, 200)
    close_fd(full.read_fd)
    close_fd(full.write_fd)
    assert_equal(deadline_reason, "write_deadline_expired")


def test_owned_child_reaped_after_early_terminate() raises:
    with spawn_max_local_stub(0, "count_requests", 1) as stub:
        stub.terminate()
        assert_true(pid_not_waitable(stub.pid))


def test_repeated_failures_leave_no_owned_child() raises:
    for _ in range(3):
        var scripts = List[ExchangeScript]()
        scripts.append(_default_script())
        with spawn_max_local_scripted(0, scripts^) as stub:
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
        with spawn_max_local_stub(0, "count_requests", 1) as stub:
            stub.terminate()
            assert_true(pid_not_waitable(stub.pid))
    var after = open_fd_count()
    assert_true(after > 0)
    assert_true(after <= before)


def test_timeout_terminates_and_reaps_stalled_child() raises:
    with spawn_max_local_stub(0, "stall", 1) as stub:
        _raw_send_only(
            stub.port,
            (
                "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
                "content-length: 2\r\nconnection: close\r\n\r\n{}"
            ),
        )
        stub.terminate()
        assert_true(pid_not_waitable(stub.pid))


def _owned_report_child(
    exit_code: Int, report: String
) raises -> SpawnedMaxLocalStub:
    """Fork a test-owned child that writes ``report`` to stdout and exits.

    Lets LC02 prove real forged/empty/mismatched reports fail for their cause,
    independent of the fixture serve loop.
    """
    var pipe = make_pipe()
    var pid = fork_pid()
    if pid == 0:
        if dup2_fd(pipe.write_fd, 1) < 0:
            child_exit(126)
        close_fd(pipe.read_fd)
        close_fd(pipe.write_fd)
        if report != "":
            _ = write_raw(1, report)
        child_exit(exit_code)
    close_fd(pipe.write_fd)
    var state = PipedChildState(
        pid=pid,
        report_fd=pipe.read_fd,
        pending="",
        eof=False,
        closed=False,
        deadline_ms=2000,
        expected_requests=1,
        reaped=False,
        ok=False,
        phase="pending",
        case_label="-",
        reason="not_reaped",
        requests=0,
        connections=0,
        cleanup_error="",
        status=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed_valid=False,
    )
    return SpawnedMaxLocalStub(pid, 0, state^)


# ── LC01: automatic scope ownership ─────────────────────────────────────────


def test_scope_cleanup_on_assertion_failure() raises:
    var held_pid = 0
    var caught = False
    try:
        with spawn_max_local_stub(0, "count_requests", 1) as stub:
            held_pid = stub.pid
            assert_true(False)
    except:
        caught = True
    assert_true(caught)
    assert_true(held_pid > 0)
    assert_true(pid_not_waitable(held_pid))


def test_scope_cleanup_on_generic_error() raises:
    var held_pid = 0
    var message = ""
    try:
        with spawn_max_local_stub(0, "count_requests", 1) as stub:
            held_pid = stub.pid
            raise Error("intentional scope error")
    except e:
        message = String(e)
    assert_equal(message, "intentional scope error")
    assert_true(pid_not_waitable(held_pid))


def _early_return_owner() raises -> Int:
    with spawn_max_local_stub(0, "count_requests", 1) as stub:
        return stub.pid
    return 0


def test_scope_cleanup_on_early_return() raises:
    var held_pid = _early_return_owner()
    assert_true(held_pid > 0)
    assert_true(pid_not_waitable(held_pid))


def test_jev_scope_cleanup_on_assertion_failure() raises:
    var held_pid = 0
    var caught = False
    try:
        with spawn_jev_stub_auto("ok", 1) as started:
            held_pid = started.stub.pid
            assert_true(False)
    except:
        caught = True
    assert_true(caught)
    assert_true(held_pid > 0)
    assert_true(pid_not_waitable(held_pid))


def test_wait_error_taxonomy_distinguishes_causes() raises:
    assert_equal(classify_wait_errno(Int(ErrNo.EINTR.value)), "interrupted")
    assert_equal(classify_wait_errno(Int(ErrNo.ECHILD.value)), "gone")
    assert_equal(classify_wait_errno(9999), "wait_error")
    assert_equal(wait_nohang(0).state, "wait_error")
    var stub = spawn_max_local_stub(0, "count_requests", 1)
    var live_pid = stub.pid
    assert_equal(wait_nohang(live_pid).state, "running")
    stub.terminate()
    assert_equal(wait_nohang(live_pid).state, "gone")
    assert_true(pid_not_waitable(live_pid))


def test_repeated_reap_and_terminate_are_owned_and_idempotent() raises:
    with spawn_max_local_stub(0, "count_requests", 1) as stub:
        var owned_pid = stub.pid
        stub.terminate()
        stub.terminate()
        stub.reap()
        assert_true(pid_not_waitable(owned_pid))
        var cached = stub.status()
        assert_true(cached.cleanup_proved())
        assert_true(not stub.ok())


# ── LC02: strict result truth ───────────────────────────────────────────────


def test_result_truth_rejects_empty_exit_zero_report() raises:
    var stub = _owned_report_child(0, "")
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "missing_report")


def test_result_truth_rejects_forged_success_with_nonzero_exit() raises:
    var stub = _owned_report_child(
        7,
        "result ok phase=complete case=- reason=ok requests=1 connections=1\n",
    )
    stub.reap()
    assert_true(not stub.ok())
    assert_true(stub.reason().startswith("report_status_mismatch"))


def test_result_truth_accepts_matching_report_and_exit() raises:
    var stub = _owned_report_child(
        0,
        "result ok phase=complete case=- reason=ok requests=1 connections=1\n",
    )
    stub.reap()
    assert_true(stub.ok())
    assert_equal(stub.phase(), "complete")
    assert_equal(stub.request_count(), 1)
    assert_equal(stub.connection_count(), 1)


def test_parse_report_rejects_malformed_inputs() raises:
    assert_equal(parse_report("").phase, "parse")
    assert_equal(
        parse_report(
            "result maybe phase=x case=- reason=y requests=1 connections=1"
        ).reason,
        "unknown_status",
    )
    assert_equal(
        parse_report(
            "result ok phase=complete case=- reason=ok requests=1 connections=1"
            " requests=1"
        ).reason,
        "duplicate_field",
    )
    assert_equal(
        parse_report(
            "result ok phase=complete case=- reason=ok requests=x connections=1"
        ).reason,
        "invalid_count",
    )
    assert_equal(
        parse_report(
            "result ok phase=complete case=- reason=ok requests=1"
        ).reason,
        "missing_field",
    )
    assert_equal(
        parse_report(
            "result ok phase=complete case=- reason=ok requests=1 connections=1"
            " extra=z"
        ).reason,
        "unknown_field",
    )
    assert_equal(
        parse_report(
            "result ok phase=complete case=- reason=ok requests=1 connections=1"
        ).phase,
        "complete",
    )


def test_report_status_matches_exit() raises:
    assert_true(report_status_matches_exit(True, 0, True))
    assert_true(report_status_matches_exit(True, 125, False))
    assert_true(not report_status_matches_exit(True, 7, True))
    assert_true(not report_status_matches_exit(True, 0, False))
    assert_true(not report_status_matches_exit(False, 0, True))


# ── LC03: byte caps and surplus retention ───────────────────────────────────


def _pipe_line(text: String) raises -> String:
    var pipe = make_pipe()
    _ = write_raw(pipe.write_fd, text)
    var result = ""
    var raised = ""
    try:
        result = read_line_bounded(pipe.read_fd, 8, 500)
    except e:
        raised = String(e)
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)
    if raised != "":
        return "raised:" + raised
    return result^


def test_line_cap_boundaries() raises:
    assert_equal(_pipe_line("1234567\n"), "1234567")
    assert_equal(_pipe_line("12345678\n"), "12345678")
    assert_equal(_pipe_line("123456789\n"), "raised:ready_output_overflow")


def test_coalesced_ready_and_report_lines_retain_surplus() raises:
    # One write carries both lines; the report line must survive the ready read
    # rather than being discarded with the chunk.
    var pipe = make_pipe()
    _ = write_raw(
        pipe.write_fd,
        (
            "ready 4242\nresult ok phase=complete case=- reason=ok requests=1"
            " connections=1\n"
        ),
    )
    var state = PipedChildState(
        pid=0,
        report_fd=pipe.read_fd,
        pending="",
        eof=False,
        closed=False,
        deadline_ms=500,
        expected_requests=1,
        reaped=False,
        ok=False,
        phase="pending",
        case_label="-",
        reason="not_reaped",
        requests=0,
        connections=0,
        cleanup_error="",
        status=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed_valid=False,
    )
    var ready = state.read_line(2048, 500)
    var report = state.read_line(2048, 500)
    state.close_reader()
    close_fd(pipe.write_fd)
    assert_equal(ready, "ready 4242")
    assert_true(report.startswith("result ok"))


# ── LC05: framing and descriptor census ─────────────────────────────────────


def test_verify_exchange_rejects_malformed_script_header() raises:
    var script = exchange_script(
        "bad_decl", "POST", "/v1/chat/completions", 200, "{}"
    )
    script.headers = "not-a-header"
    var framed = FramedRequest(
        ok=True,
        error="",
        method="POST",
        path="/v1/chat/completions",
        version="HTTP/1.1",
        headers_raw="host: h",
        body="",
        content_length=0,
        keep_alive=False,
        total_bytes=0,
    )
    assert_equal(verify_exchange(script, framed), "malformed_script_header")


def test_header_value_rejects_control_bytes_and_trims_ows() raises:
    # Raw control byte inside a value is rejected as malformed framing.
    var bad = _framing_failure(
        "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
        "x-ctl: a\x01b\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
    )
    assert_equal(bad.phase(), "read")
    assert_equal(bad.reason(), "malformed_header")
    # Legal surrounding OWS on a selected header value is accepted.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "ows", "POST", "/v1/chat/completions", 200, "{}"
    )
    script.headers = "x-ows:value"
    scripts.append(script^)
    with spawn_max_local_scripted(0, scripts^) as stub:
        var response = _request(
            stub.port,
            "POST",
            "/v1/chat/completions",
            "{}",
            "x-ows:   value  \r\n",
        )
        assert_true(response.find("200") >= 0)
        stub.wait()


def test_descriptor_census_detects_planted_high_fd() raises:
    var before = open_fd_count()
    assert_true(before > 0)
    assert_equal(descriptor_census(0), -1)
    assert_true(descriptor_census(3) > 0)
    var pipe = make_pipe()
    var planted = Int(dup2_fd(pipe.read_fd, 900))
    var with_pipe = open_fd_count()
    assert_true(planted >= 0)
    assert_true(with_pipe > before)
    close_fd(planted)
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)
    assert_equal(open_fd_count(), before)


def test_partial_pipe_failure_rolls_back() raises:
    # LC01: a later pipe failure must close the pipes already created.
    var before = open_fd_count_checked()
    var message = ""
    try:
        _ = make_three_pipes(1)
    except e:
        message = String(e)
    assert_true(message.find("injected pipe creation failure") >= 0)
    assert_equal(open_fd_count_checked(), before)


def test_fork_failure_closes_owned_pipes() raises:
    # LC01: a fork failure must close both ends of the owned pipe.
    var before = open_fd_count_checked()
    var pipe = make_pipe()
    var message = ""
    try:
        _ = fork_owned_or_close(pipe.copy(), True)
    except e:
        message = String(e)
    assert_true(message.find("injected fork failure") >= 0)
    assert_equal(open_fd_count_checked(), before)


def test_result_truth_rejects_duplicate_report_line() raises:
    var stub = _owned_report_child(
        0,
        (
            "result ok phase=complete case=- reason=ok requests=1"
            " connections=1\nresult ok phase=complete case=- reason=ok"
            " requests=1 connections=1\n"
        ),
    )
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "duplicate_report")


def test_cleanup_failure_is_observable() raises:
    # LC01/D36: cleanup failure must be observable, never silently swallowed.
    var state = PipedChildState(
        pid=0,
        report_fd=-1,
        pending="",
        eof=False,
        closed=False,
        deadline_ms=100,
        expected_requests=1,
        reaped=False,
        ok=False,
        phase="pending",
        case_label="-",
        reason="not_reaped",
        requests=0,
        connections=0,
        cleanup_error="",
        status=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed=ProcessStatus("pending", False, -1, 0, 0, ""),
        observed_valid=False,
    )
    var stub = SpawnedMaxLocalStub(0, 0, state^)
    stub.cleanup()
    assert_true(stub.cleanup_error().find("unreaped") >= 0)
    assert_true(not stub.status().cleanup_proved())


def test_result_truth_rejects_wrong_request_count() raises:
    var stub = _owned_report_child(
        0,
        "result ok phase=complete case=- reason=ok requests=2 connections=1\n",
    )
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "request_count_mismatch")


def test_result_truth_rejects_invalid_connection_count() raises:
    var stub = _owned_report_child(
        0,
        "result ok phase=complete case=- reason=ok requests=1 connections=5\n",
    )
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "connection_count_invalid")


def test_completion_probe_error_is_not_success() raises:
    # LC05: a non-timeout completion-probe I/O/setup error must not be read as
    # a successful completion.
    var pipe = make_pipe()
    var sock = RawSocket(c_int(pipe.read_fd), c_int(2), c_int(1), True)
    var stream = TcpStream(sock^, SocketAddr.localhost(UInt16(1)))
    var reader = ConnectionReader(stream^)
    var raised = False
    try:
        _ = reader.probe_completion(20)
    except e:
        raised = True
        _ = String(e)
    close_fd(pipe.write_fd)
    assert_true(raised)


def test_descriptor_census_detects_planted_socket() raises:
    # The census must count sockets, not only regular files.
    var before = open_fd_count()
    var sock = Int(external_call["socket", c_int](c_int(2), c_int(1), c_int(0)))
    assert_true(sock >= 0)
    var with_socket = open_fd_count()
    assert_true(with_socket > before)
    close_fd(sock)
    assert_true(open_fd_count() <= with_socket)


def test_ready_grammar_rejections() raises:
    var valid = 0
    var raised = ""
    try:
        valid = parse_ready_line("ready 65535", 256)
    except e:
        raised = String(e)
    assert_equal(valid, 65535)
    assert_equal(raised, "")
    var cases = List[String]()
    cases.append("")
    cases.append("ready")
    cases.append("ready ")
    cases.append("ready abc")
    cases.append("ready 12345x")
    cases.append("ready 70000")
    cases.append("ready 0")
    cases.append("not-ready")
    for probe in cases:
        var reason = ""
        try:
            _ = parse_ready_line(probe, 256)
        except e:
            reason = String(e)
        assert_true(reason != "")


def test_malformed_ready_line_terminates_owned_child() raises:
    # LC03: malformed readiness must clean up the exact owned child.
    var pipe = make_pipe()
    var pid = fork_pid()
    if pid == 0:
        close_fd(pipe.read_fd)
        _ = write_raw(pipe.write_fd, "garbage-not-ready\n")
        for _ in range(400):
            sleep_ms(50)
        child_exit(0)
    close_fd(pipe.write_fd)
    var line = read_line_bounded(pipe.read_fd, 256, 500)
    close_fd(pipe.read_fd)
    var message = ""
    try:
        _ = parse_ready_or_cleanup(pid, line, 256)
    except e:
        message = String(e)
    assert_true(message.find("ready_invalid:ready_grammar") >= 0)
    assert_true(message.find("cleanup=proved") >= 0)
    assert_true(pid_not_waitable(pid))


def test_status_observation_preserves_ownership_and_report() raises:
    # LC01/LC02: observing an exited child must not consume the report.
    var stub = _owned_report_child(
        0,
        "result ok phase=complete case=- reason=ok requests=1 connections=1\n",
    )
    var observed = ""
    for _ in range(200):
        observed = stub.status().state
        if observed != "running" and observed != "interrupted":
            break
        sleep_ms(20)
    assert_equal(observed, "reaped")
    var second = stub.status()
    assert_equal(second.state, "reaped")
    stub.reap()
    assert_true(stub.ok())
    assert_equal(stub.request_count(), 1)
    assert_true(stub.status().cleanup_proved())


def test_status_observation_then_terminate_is_safe() raises:
    var stub = _owned_report_child(0, "")
    sleep_ms(100)
    _ = stub.status()
    var owned_pid = stub.pid
    stub.terminate()
    stub.terminate()
    stub.reap()
    assert_true(pid_not_waitable(owned_pid))
    assert_true(not stub.ok())


# ── LC05: coalesced header cap accounting ───────────────────────────────────


def test_coalesced_large_body_does_not_charge_header_cap() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    with spawn_max_local_scripted(0, scripts^) as stub:
        var header_filler = String("")
        for _ in range(20000):
            header_filler += "a"
        var body_filler = String("")
        for _ in range(50000):
            body_filler += "b"
        var raw = (
            "POST /v1/chat/completions HTTP/1.1\r\nhost:"
            " 127.0.0.1\r\nx-filler: "
            + header_filler
            + "\r\ncontent-length: "
            + String(body_filler.byte_length())
            + "\r\nconnection: close\r\n\r\n"
            + body_filler
        )
        var response = _raw_exchange(stub.port, raw)
        assert_true(response.find("200") >= 0)
        stub.wait()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
