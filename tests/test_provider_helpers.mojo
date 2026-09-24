"""Strict fixture/script verification tests (ADR-0012 D29 / ADR-0014 D33).

Covers FX01-FX08 for both providers plus the in-memory mutation controls that
prove a negative control fails for the intended cause rather than for any
exception, signal or unrelated startup failure.
"""

from std.testing import TestSuite, assert_true, assert_equal
from std.ffi import ErrNo, c_int, external_call, get_errno

from flare.net import SocketAddr
from flare.net.socket import RawSocket
from flare.tcp import TcpListener, TcpStream

from parent_lifecycle import (
    CENSUS_MAX_FDS,
    CleanupGuard,
    PipedChildState,
    ProcessStatus,
    child_exit,
    classify_census_errno,
    classify_wait_errno,
    close_fd,
    descriptor_census,
    descriptor_census_with_faults,
    dup2_fd,
    finalize_owned_failure,
    fork_owned_or_close,
    fork_owned_or_close3,
    fork_pid,
    make_pipe,
    make_three_pipes,
    now_ms,
    open_fd_count,
    open_fd_count_checked,
    open_fd_count_checked_with_faults,
    parse_ready_line,
    parse_ready_or_cleanup,
    pid_not_waitable,
    pid_running,
    piped_child_state,
    read_all_bounded,
    read_line_bounded,
    sleep_ms,
    wait_nohang,
    write_fd_bounded,
    write_raw,
    write_raw_bytes,
)
from strict_fixture import (
    STRICT_MAX_REPORT_BYTES,
    ConnectionReader,
    ExchangeScript,
    FramedRequest,
    authorization_reason,
    classify_write_error_cause,
    exchange_script,
    is_peer_close_cause,
    json_escape,
    parse_report,
    render_write_api_error,
    report_status_matches_exit,
    verify_exchange,
    write_errno_class,
)
from max_local_process_helper import (
    SpawnedMaxLocalStub,
    reserve_loopback_port,
    spawn_max_local_scripted,
    spawn_max_local_stub,
)
from jev_provider_helper import (
    SpawnedJevStub,
    spawn_jev_scripted_auto,
    spawn_jev_stub,
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
    var guard_1 = CleanupGuard()
    with spawn_max_local_stub(0, "echo_body_bytes", 1, guard_1) as stub:
        var body = String("")
        for _ in range(9000):
            body += "x"
        var response = _request(stub.port, "POST", "/v1/chat/completions", body)
        assert_true(response.find('"received_bytes":9000') >= 0)
        stub.wait()

    guard_1.assert_clean()


def test_max_local_stub_counts_every_wire_attempt() raises:
    var requests = 3
    var guard_2 = CleanupGuard()
    with spawn_max_local_stub(0, "count_requests", requests, guard_2) as stub:
        for index in range(requests):
            var response = _request(
                stub.port, "POST", "/v1/chat/completions", "{}"
            )
            assert_true(
                response.find('"request_index":' + String(index + 1)) >= 0
            )
        stub.wait()

    guard_2.assert_clean()


def test_max_local_stub_rejects_unknown_path() raises:
    # FX02/FX04: an unexpected route must fail fixture verification, not be
    # answered 404 and then reported as a successful stub run.
    var guard_3 = CleanupGuard()
    with spawn_max_local_stub(0, "query_rewrite_ok", 1, guard_3) as stub:
        var response = _request(stub.port, "POST", "/not-a-route", "{}")
        assert_true(response.find("404") < 0)
        stub.reap()
        assert_true(not stub.ok())
        assert_equal(stub.phase(), "exchange")
        assert_equal(stub.reason(), "unexpected_path")

    guard_3.assert_clean()


def test_max_local_stub_binds_and_reports_port() raises:
    var guard_4 = CleanupGuard()
    with spawn_max_local_stub(0, "count_requests", 1, guard_4) as stub:
        assert_true(stub.port > 0)
        var response = _request(stub.port, "POST", "/v1/chat/completions", "{}")
        assert_true(response.find('"request_index":1') >= 0)
        stub.wait()

    guard_4.assert_clean()


def test_jev_stub_observes_bearer_sentinel_at_intended_origin() raises:
    var guard_5 = CleanupGuard()
    with spawn_jev_stub_auto("echo_authorization", 1, guard_5) as started:
        var response = _request(
            started.port,
            "POST",
            "/v1/systemone",
            "{}",
            "authorization: Bearer hyf-sentinel-token\r\n",
        )
        assert_true(response.find("hyf-sentinel-token") >= 0)
        started.stub.wait()

    guard_5.assert_clean()


def test_max_local_stub_stalled_child_is_reaped() raises:
    var guard_6 = CleanupGuard()
    with spawn_max_local_stub(0, "stall", 1, guard_6) as stub:
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

    guard_6.assert_clean()


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
    var guard_7 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_7) as stub:
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

    guard_7.assert_clean()


def test_max_local_scripted_rejects_wrong_method() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var guard_8 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_8) as stub:
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

    guard_8.assert_clean()


def test_max_local_scripted_rejects_wrong_path() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var guard_9 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_9) as stub:
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

    guard_9.assert_clean()


def test_max_local_scripted_rejects_wrong_selected_header() raises:
    var scripts = List[ExchangeScript]()
    var script = _default_script()
    script.headers = "x-sentinel:expected"
    scripts.append(script^)
    var guard_10 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_10) as stub:
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

    guard_10.assert_clean()


def test_max_local_scripted_rejects_wrong_body() raises:
    var scripts = List[ExchangeScript]()
    var script = _default_script()
    script.check_body = True
    script.body = '{"expected":true}'
    scripts.append(script^)
    var guard_11 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_11) as stub:
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

    guard_11.assert_clean()


def test_scripted_rejects_extra_pipelined_exchange() raises:
    var scripts = List[ExchangeScript]()
    var script = _default_script()
    script.close_connection = False
    scripts.append(script^)
    var guard_12 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_12) as stub:
        var first_frame = (
            "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
            "content-length: 2\r\nconnection: keep-alive\r\n\r\n{}"
        )
        var second_frame = String(first_frame)
        _raw_send_only(stub.port, first_frame + second_frame)
        stub.reap()
        assert_equal(stub.phase(), "accounting")
        assert_equal(stub.reason(), "extra_exchange_after_completion")

    guard_12.assert_clean()


def test_scripted_rejects_missing_exchange() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var guard_13 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_13) as stub:
        var client = TcpStream.connect(SocketAddr.localhost(UInt16(stub.port)))
        client.close()
        stub.reap()
        assert_equal(stub.phase(), "accounting")
        assert_equal(stub.reason(), "missing_exchanges")
        assert_equal(stub.request_count(), 0)

    guard_13.assert_clean()


def test_scripted_reports_unconsumed_remaining_scripts() raises:
    var scripts = List[ExchangeScript]()
    var first = _default_script()
    first.close_connection = False
    scripts.append(first^)
    scripts.append(_default_script())
    var guard_14 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_14) as stub:
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

    guard_14.assert_clean()


def _framing_failure(raw: String) raises -> FramingFailure:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var guard = CleanupGuard()
    var snapshot = FramingFailure(False, "", "-", "", 0, 0)
    with spawn_max_local_scripted(0, scripts^, guard) as stub:
        _raw_send_only(stub.port, raw)
        stub.reap()
        snapshot = FramingFailure(
            stub.ok(),
            stub.phase(),
            stub.failure_case(),
            stub.reason(),
            stub.request_count(),
            stub.connection_count(),
        )
    guard.assert_clean()
    return snapshot^


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
    var guard_16 = CleanupGuard()
    with spawn_jev_stub_auto("echo_authorization", 1, guard_16) as started:
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

    guard_16.assert_clean()


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
    var guard_17 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_17) as stub:
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

    guard_17.assert_clean()


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
    var guard_18 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_18) as stub:
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

    guard_18.assert_clean()


def test_jev_scripted_wrong_route_auth_not_bypassed() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "jev_expect", "POST", "/v1/systemone", 200, '{"ok":true}'
    )
    script.require_bearer = True
    scripts.append(script^)
    var guard_19 = CleanupGuard()
    with spawn_jev_scripted_auto(scripts^, guard_19) as started:
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

    guard_19.assert_clean()


def test_scripted_rejects_duplicate_authorization() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "dup_auth", "POST", "/v1/chat/completions", 200, '{"ok":true}'
    )
    script.require_bearer = True
    scripts.append(script^)
    var guard_20 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_20) as stub:
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

    guard_20.assert_clean()


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
    var guard_21 = CleanupGuard()
    with spawn_jev_scripted_auto(scripts^, guard_21) as started:
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

    guard_21.assert_clean()


def test_startup_failure_distinct_from_exchange_failure() raises:
    # Occupy a port so the fixture child cannot bind; the parent must observe
    # a bounded startup/serve_failed report, not a generic exception or a
    # script/parser rejection (FX07 / R61).
    var blocker = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(blocker.local_addr().port)
    var message = ""
    try:
        var guard_22 = CleanupGuard()
        with spawn_max_local_stub(port, "count_requests", 1, guard_22) as stub:
            stub.terminate()
        guard_22.assert_clean()
    except e:
        message = String(e)
    blocker.close()
    assert_true(message.find("phase=startup") >= 0)
    assert_true(message.find("reason=serve_failed") >= 0)
    assert_true(message.find("exited=") >= 0 or message.find("signal=") >= 0)


def test_provider_stub_parent_deadline_watchdog() raises:
    # No client connects, so the child blocks in accept until the parent's own
    # finite deadline fires and the owned child is terminated and reaped.
    var guard_23 = CleanupGuard()
    with spawn_max_local_stub(0, "count_requests", 1, guard_23, 800) as stub:
        stub.reap()
        assert_true(not stub.ok())
        assert_equal(stub.phase(), "watchdog")
        assert_equal(stub.reason(), "timeout")
        assert_true(pid_not_waitable(stub.pid))

    guard_23.assert_clean()


def test_jev_stub_parent_deadline_watchdog() raises:
    var guard_24 = CleanupGuard()
    with spawn_jev_stub_auto("ok", 1, guard_24, 800) as started:
        started.stub.reap()
        assert_true(not started.stub.ok())
        assert_equal(started.stub.phase(), "watchdog")
        assert_equal(started.stub.reason(), "timeout")
        assert_true(pid_not_waitable(started.stub.pid))

    guard_24.assert_clean()


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


def test_real_write_to_closed_descriptor_is_ebadf() raises:
    # RP03: a real (non-synthetic) descriptor/write failure. An exact-owned pipe
    # write end is closed and then written to, so the OS returns a real EBADF.
    # The raw errno is recorded and the actual classification function maps the
    # rendered write-API cause to invalid_descriptor, which can never be a peer
    # close. No product or fork source is involved.
    var pipe = make_pipe()
    close_fd(pipe.write_fd)
    var written = write_raw(pipe.write_fd, "x")
    assert_true(written < 0)
    var errno_value = Int(get_errno().value)
    assert_equal(errno_value, Int(ErrNo.EBADF.value))
    assert_equal(write_errno_class(errno_value), "invalid_descriptor")
    var rendered = render_write_api_error(errno_value)
    assert_true(rendered.find("Bad file descriptor") >= 0)
    assert_equal(classify_write_error_cause(rendered), "invalid_descriptor")
    assert_true(not is_peer_close_cause("invalid_descriptor"))
    close_fd(pipe.read_fd)


def test_owned_child_reaped_after_early_terminate() raises:
    var guard_25 = CleanupGuard()
    with spawn_max_local_stub(0, "count_requests", 1, guard_25) as stub:
        stub.terminate()
        assert_true(pid_not_waitable(stub.pid))

    guard_25.assert_clean()


def test_repeated_failures_leave_no_owned_child() raises:
    for _ in range(3):
        var scripts = List[ExchangeScript]()
        scripts.append(_default_script())
        var guard_26 = CleanupGuard()
        with spawn_max_local_scripted(0, scripts^, guard_26) as stub:
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

        guard_26.assert_clean()


def test_repeated_teardown_does_not_leak_descriptors() raises:
    var before = open_fd_count()
    assert_true(before > 0)
    for _ in range(5):
        var guard_27 = CleanupGuard()
        with spawn_max_local_stub(0, "count_requests", 1, guard_27) as stub:
            stub.terminate()
            assert_true(pid_not_waitable(stub.pid))
        guard_27.assert_clean()
    var after = open_fd_count()
    assert_true(after > 0)
    assert_true(after <= before)


def test_timeout_terminates_and_reaps_stalled_child() raises:
    var guard_28 = CleanupGuard()
    with spawn_max_local_stub(0, "stall", 1, guard_28) as stub:
        _raw_send_only(
            stub.port,
            (
                "POST /v1/chat/completions HTTP/1.1\r\nhost: 127.0.0.1\r\n"
                "content-length: 2\r\nconnection: close\r\n\r\n{}"
            ),
        )
        stub.terminate()
        assert_true(pid_not_waitable(stub.pid))

    guard_28.assert_clean()


def _owned_report_child(
    mut guard: CleanupGuard, exit_code: Int, report: String
) raises -> SpawnedMaxLocalStub:
    """Fork a test-owned child that writes ``report`` to stdout and exits.

    Lets LC02 prove real forged/empty/mismatched reports fail for their cause,
    independent of the fixture serve loop. The caller holds ``guard`` so the
    cleanup outcome stays observable.
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
    var state = piped_child_state(
        pid, pipe.read_fd, 2000, 1, UnsafePointer(to=guard)
    )
    return SpawnedMaxLocalStub(pid, 0, state^)


def _owned_jev_report_child(
    mut guard: CleanupGuard, exit_code: Int, report: String
) raises -> SpawnedJevStub:
    """Same controlled report child, reaped through the Jev provider path."""
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
    var state = piped_child_state(
        pid, pipe.read_fd, 2000, 1, UnsafePointer(to=guard)
    )
    return SpawnedJevStub(pid, 0, state^)


# ── LC01: automatic scope ownership ─────────────────────────────────────────


def test_scope_cleanup_on_assertion_failure() raises:
    var held_pid = 0
    var caught = False
    try:
        var guard_29 = CleanupGuard()
        with spawn_max_local_stub(0, "count_requests", 1, guard_29) as stub:
            held_pid = stub.pid
            assert_true(False)
        guard_29.assert_clean()
    except:
        caught = True
    assert_true(caught)
    assert_true(held_pid > 0)
    assert_true(pid_not_waitable(held_pid))


def test_scope_cleanup_on_generic_error() raises:
    var held_pid = 0
    var message = ""
    try:
        var guard_30 = CleanupGuard()
        with spawn_max_local_stub(0, "count_requests", 1, guard_30) as stub:
            held_pid = stub.pid
            raise Error("intentional scope error")
        guard_30.assert_clean()
    except e:
        message = String(e)
    assert_equal(message, "intentional scope error")
    assert_true(pid_not_waitable(held_pid))


def _early_return_owner(mut guard: CleanupGuard) raises -> Int:
    # The guard is caller-held so the cleanup outcome stays observable even
    # though this scope exits through a ``return`` before any post-scope line.
    with spawn_max_local_stub(0, "count_requests", 1, guard) as stub:
        return stub.pid
    return 0


def test_scope_cleanup_on_early_return() raises:
    var guard = CleanupGuard()
    var held_pid = _early_return_owner(guard)
    assert_true(held_pid > 0)
    assert_true(pid_not_waitable(held_pid))
    guard.assert_clean()


def test_jev_scope_cleanup_on_assertion_failure() raises:
    var held_pid = 0
    var caught = False
    try:
        var guard_32 = CleanupGuard()
        with spawn_jev_stub_auto("ok", 1, guard_32) as started:
            held_pid = started.stub.pid
            assert_true(False)
        guard_32.assert_clean()
    except:
        caught = True
    assert_true(caught)
    assert_true(held_pid > 0)
    assert_true(pid_not_waitable(held_pid))


def test_jev_scope_cleanup_on_generic_error() raises:
    var held_pid = 0
    var message = ""
    try:
        var guard_33 = CleanupGuard()
        with spawn_jev_stub_auto("ok", 1, guard_33) as started:
            held_pid = started.stub.pid
            raise Error("intentional jev scope error")
        guard_33.assert_clean()
    except e:
        message = String(e)
    assert_equal(message, "intentional jev scope error")
    assert_true(pid_not_waitable(held_pid))


def _jev_early_return_owner(mut guard: CleanupGuard) raises -> Int:
    # The guard is caller-held so the cleanup outcome stays observable even
    # though this scope exits through a ``return`` before any post-scope line.
    with spawn_jev_stub_auto("ok", 1, guard) as started:
        return started.stub.pid
    return 0


def test_jev_scope_cleanup_on_early_return() raises:
    var guard = CleanupGuard()
    var held_pid = _jev_early_return_owner(guard)
    assert_true(held_pid > 0)
    assert_true(pid_not_waitable(held_pid))
    guard.assert_clean()


def test_jev_early_return_cleanup_failure_is_observable() raises:
    # RA01: an early return that leaves cleanup unproved must still fail the
    # owning test through the caller-held guard, for the Jev provider path.
    var guard = CleanupGuard()
    var held_pid = 0
    with spawn_jev_stub_auto("ok", 1, guard) as started:
        held_pid = started.stub.pid
        started.stub.inject_cleanup_failure()
    var failure = ""
    try:
        guard.assert_clean()
    except e:
        failure = String(e)
    assert_true(failure.find("cleanup-unproved") >= 0)
    assert_true(held_pid > 0)
    # The retained exact-owned child is still recoverable, not a message only.
    assert_true(guard.retained() >= 1)
    assert_equal(guard.recover_all(), 0)
    guard.assert_clean()
    assert_true(pid_not_waitable(held_pid))


def test_jev_startup_failure_is_truthful_and_cause_specific() raises:
    # PC02/LC01: the Jev startup-readiness failure path executes against a real
    # owned child, reports its cause and exposes the finalizer's cleanup truth.
    # The caller-held guard is the enforcement point: a startup finalization
    # that could not prove cleanup fails this test instead of being discarded.
    var blocker = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(blocker.local_addr().port)
    var message = ""
    var guard = CleanupGuard()
    try:
        var started = spawn_jev_stub(port, "ok", 1, guard)
        started.cleanup()
    except e:
        message = String(e)
    blocker.close()
    guard.assert_clean()
    assert_true(message.find("phase=startup") >= 0)
    assert_true(message.find("reason=serve_failed") >= 0)
    assert_true(message.find("cleanup=") >= 0)
    assert_true(message.find("pid=") >= 0)


def test_wait_error_taxonomy_distinguishes_causes() raises:
    assert_equal(classify_wait_errno(Int(ErrNo.EINTR.value)), "interrupted")
    assert_equal(classify_wait_errno(Int(ErrNo.ECHILD.value)), "gone")
    assert_equal(classify_wait_errno(9999), "wait_error")
    assert_equal(wait_nohang(0).state, "wait_error")
    var live_pid = 0
    var guard_35 = CleanupGuard()
    with spawn_max_local_stub(0, "count_requests", 1, guard_35) as stub:
        live_pid = stub.pid
        assert_equal(wait_nohang(live_pid).state, "running")
        stub.terminate()
        assert_equal(wait_nohang(live_pid).state, "gone")
    guard_35.assert_clean()
    assert_true(pid_not_waitable(live_pid))


def test_repeated_reap_and_terminate_are_owned_and_idempotent() raises:
    var guard_36 = CleanupGuard()
    with spawn_max_local_stub(0, "count_requests", 1, guard_36) as stub:
        var owned_pid = stub.pid
        stub.terminate()
        stub.terminate()
        stub.reap()
        assert_true(pid_not_waitable(owned_pid))
        var cached = stub.status()
        assert_true(cached.cleanup_proved())
        assert_true(not stub.ok())

    # ── LC02: strict result truth ───────────────────────────────────────────────

    guard_36.assert_clean()


def test_result_truth_rejects_empty_exit_zero_report() raises:
    var guard_101 = CleanupGuard()
    var stub = _owned_report_child(guard_101, 0, "")
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "missing_report")

    guard_101.assert_clean()


def test_result_truth_rejects_forged_success_with_nonzero_exit() raises:
    var guard_102 = CleanupGuard()
    var stub = _owned_report_child(
        guard_102,
        7,
        "result ok phase=complete case=- reason=ok requests=1 connections=1\n",
    )
    stub.reap()
    assert_true(not stub.ok())
    assert_true(stub.reason().startswith("report_status_mismatch"))

    guard_102.assert_clean()


def test_result_truth_accepts_matching_report_and_exit() raises:
    var guard_103 = CleanupGuard()
    var stub = _owned_report_child(
        guard_103,
        0,
        "result ok phase=complete case=- reason=ok requests=1 connections=1\n",
    )
    stub.reap()
    assert_true(stub.ok())
    assert_equal(stub.phase(), "complete")
    assert_equal(stub.request_count(), 1)
    assert_equal(stub.connection_count(), 1)

    guard_103.assert_clean()


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
    var guard = CleanupGuard()
    var state = piped_child_state(
        pid=0,
        report_fd=pipe.read_fd,
        deadline_ms=500,
        expected_requests=1,
        guard=UnsafePointer(to=guard),
    )
    var ready = state.read_line(2048, 500)
    var report = state.read_line(2048, 500)
    state.close_reader()
    close_fd(pipe.write_fd)
    assert_equal(ready, "ready 4242")
    assert_true(report.startswith("result ok"))
    guard.assert_clean()


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
    var guard_37 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_37) as stub:
        var response = _request(
            stub.port,
            "POST",
            "/v1/chat/completions",
            "{}",
            "x-ows:   value  \r\n",
        )
        assert_true(response.find("200") >= 0)
        stub.wait()

    guard_37.assert_clean()


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


def test_stdio_fork_failure_closes_all_owned_pipes() raises:
    # LC01: the stdio helper's fork failure must close all three pipe pairs.
    var before = open_fd_count_checked()
    var pipes = make_three_pipes()
    var message = ""
    try:
        _ = fork_owned_or_close3(pipes.copy(), True)
    except e:
        message = String(e)
    assert_true(message.find("injected fork failure") >= 0)
    assert_equal(open_fd_count_checked(), before)


def test_result_truth_rejects_duplicate_report_line() raises:
    var guard_104 = CleanupGuard()
    var stub = _owned_report_child(
        guard_104,
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

    guard_104.assert_clean()


def test_cleanup_failure_is_observable() raises:
    # RA01/RA02: a cleanup failure must be observable through the required
    # caller-held guard, must not claim the child was collected, and must retain
    # retryable ownership rather than only a message.
    var guard = CleanupGuard()
    var state = piped_child_state(0, -1, 100, 1, UnsafePointer(to=guard))
    var stub = SpawnedMaxLocalStub(0, 0, state^)
    stub.cleanup()
    assert_true(stub.cleanup_error().find("unreaped") >= 0)
    assert_true(not stub.status().cleanup_proved())
    assert_equal(guard.count(), 1)
    assert_true(guard.first().find("unproved") >= 0)
    assert_equal(guard.retained(), 1)
    # A second cleanup still retries the same owned identity rather than
    # short-circuiting on a false "reaped" flag.
    stub.cleanup()
    assert_equal(guard.count(), 2)
    var failure = ""
    try:
        guard.assert_clean()
    except e:
        failure = String(e)
    assert_true(failure.find("cleanup-unproved") >= 0)


def test_result_truth_rejects_wrong_request_count() raises:
    var guard_105 = CleanupGuard()
    var stub = _owned_report_child(
        guard_105,
        0,
        "result ok phase=complete case=- reason=ok requests=2 connections=1\n",
    )
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "request_count_mismatch")

    guard_105.assert_clean()


def test_result_truth_rejects_invalid_connection_count() raises:
    var guard_106 = CleanupGuard()
    var stub = _owned_report_child(
        guard_106,
        0,
        "result ok phase=complete case=- reason=ok requests=1 connections=5\n",
    )
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "connection_count_invalid")

    guard_106.assert_clean()


def test_completion_probe_read_error_is_distinct_from_setup_and_timeout() raises:
    # LC05/PC04: a real socket read error after a successful timeout setup must
    # propagate as the exact read cause, not be read as success, a setup
    # failure or a timeout.
    #
    # 1. Successful setup on a real (unconnected) socket, then a real read
    #    error (ENOTCONN): the probe must raise and never return success.
    var sock = RawSocket(c_int(2), c_int(1))
    var stream = TcpStream(sock^, SocketAddr.localhost(UInt16(1)))
    var setup_ok = False
    try:
        stream.set_recv_timeout(20)
        setup_ok = True
    except e:
        _ = String(e)
    assert_true(setup_ok)
    var reader = ConnectionReader(stream^)
    var read_message = ""
    var read_result = ""
    try:
        read_result = reader.probe_completion(20)
    except e:
        read_message = String(e)
    assert_true(read_result == "")
    assert_true(read_message.find("recv") >= 0)
    assert_true(read_message.find("timeout") < 0)

    # 2. A non-socket descriptor fails at setup, a distinct cause.
    var pipe = make_pipe()
    var pipe_sock = RawSocket(c_int(pipe.read_fd), c_int(2), c_int(1), True)
    var pipe_stream = TcpStream(pipe_sock^, SocketAddr.localhost(UInt16(1)))
    var pipe_reader = ConnectionReader(pipe_stream^)
    var setup_failure = ""
    try:
        _ = pipe_reader.probe_completion(20)
    except e:
        setup_failure = String(e)
    close_fd(pipe.write_fd)
    assert_true(setup_failure != "")
    assert_true(setup_failure.find("setsockopt") >= 0)

    # 3. A quiet connected socket times out, which is the probe's success path
    #    and stays distinct from the read error above.
    var listener = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(listener.local_addr().port)
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    var server = listener.accept()
    var server_reader = ConnectionReader(server^)
    var quiet = server_reader.probe_completion(20)
    client.close()
    assert_equal(quiet, "")


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
    var guard_107 = CleanupGuard()
    var stub = _owned_report_child(
        guard_107,
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

    guard_107.assert_clean()


def test_status_observation_then_terminate_is_safe() raises:
    var guard_108 = CleanupGuard()
    var stub = _owned_report_child(guard_108, 0, "")
    sleep_ms(100)
    _ = stub.status()
    var owned_pid = stub.pid
    stub.terminate()
    stub.terminate()
    stub.reap()
    assert_true(pid_not_waitable(owned_pid))
    assert_true(not stub.ok())

    # ── LC05: coalesced header cap accounting ───────────────────────────────────

    guard_108.assert_clean()


def test_coalesced_large_body_does_not_charge_header_cap() raises:
    var scripts = List[ExchangeScript]()
    scripts.append(_default_script())
    var guard_38 = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard_38) as stub:
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

    # ── PC01/PC02/PC04: complete report truth and retained ownership ─────────────

    guard_38.assert_clean()


comptime VALID_REPORT = (
    "result ok phase=complete case=- reason=ok requests=1 connections=1\n"
)


def _report_controls(
    report: String, exit_code: Int, expected_reason: String
) raises:
    """Every report-framing control must fail for its cause on BOTH providers.
    """
    var guard_109 = CleanupGuard()
    var stub = _owned_report_child(guard_109, exit_code, report)
    var owned = stub.pid
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), expected_reason)
    assert_true(pid_not_waitable(owned))
    var guard_110 = CleanupGuard()
    var jev_stub = _owned_jev_report_child(guard_110, exit_code, report)
    var jev_owned = jev_stub.pid
    jev_stub.reap()
    assert_true(not jev_stub.ok())
    assert_equal(jev_stub.reason(), expected_reason)
    assert_true(pid_not_waitable(jev_owned))

    guard_109.assert_clean()
    guard_110.assert_clean()


def test_report_stream_controls_both_providers() raises:
    # PC01: the complete bounded report stream is validated through EOF; a
    # positive control and the aligned/split/coalesced duplicate, no-LF,
    # malformed and inconsistent-field controls all execute on both providers.
    var guard_111 = CleanupGuard()
    var stub = _owned_report_child(guard_111, 0, VALID_REPORT)
    stub.reap()
    assert_true(stub.ok())
    assert_equal(stub.phase(), "complete")
    assert_equal(stub.request_count(), 1)
    var guard_112 = CleanupGuard()
    var jev_stub = _owned_jev_report_child(guard_112, 0, VALID_REPORT)
    jev_stub.reap()
    assert_true(jev_stub.ok())
    assert_equal(jev_stub.request_count(), 1)

    var first = "result ok phase=complete case="
    var tail = " reason=ok requests=1 connections=1\n"
    while first.byte_length() + tail.byte_length() < 512:
        first += "x"
    first += tail
    assert_equal(first.byte_length(), 512)
    _report_controls(first + VALID_REPORT, 0, "duplicate_report")
    _report_controls(VALID_REPORT + VALID_REPORT, 0, "duplicate_report")
    var split_first = "result ok phase=complete case="
    while split_first.byte_length() + tail.byte_length() < 700:
        split_first += "y"
    split_first += tail
    assert_equal(split_first.byte_length(), 700)
    _report_controls(split_first + VALID_REPORT, 0, "duplicate_report")
    var guard_113 = CleanupGuard()
    var split_positive = _owned_report_child(guard_113, 0, split_first)
    split_positive.reap()
    assert_true(split_positive.ok())
    var guard_114 = CleanupGuard()
    var jev_split = _owned_jev_report_child(guard_114, 0, split_first)
    jev_split.reap()
    assert_true(jev_split.ok())
    var unterminated = String(
        VALID_REPORT[byte = 0 : VALID_REPORT.byte_length() - 1]
    )
    _report_controls(unterminated, 0, "unterminated_report")
    _report_controls(
        (
            "result ok phase=read case=- reason=io_error requests=1"
            " connections=1\n"
        ),
        0,
        "inconsistent_status",
    )
    _report_controls(
        "result ok phase= case=- reason=ok requests=1 connections=1\n",
        0,
        "empty_field",
    )
    _report_controls(
        "result ok phase=complete case=- reason=ok requests=1\n",
        0,
        "missing_field",
    )
    _report_controls(
        (
            "result maybe phase=complete case=- reason=ok requests=1"
            " connections=1\n"
        ),
        0,
        "unknown_status",
    )
    _report_controls(
        "result ok phase=complete case=- reason=ok requests=x connections=1\n",
        0,
        "invalid_count",
    )
    _report_controls(
        (
            "result ok phase=complete case=- reason=ok requests=1 connections=1"
            " extra=z\n"
        ),
        0,
        "unknown_field",
    )
    _report_controls(
        (
            "result ok phase=complete case=- reason=ok requests=1 requests=1"
            " connections=1\n"
        ),
        0,
        "duplicate_field",
    )
    var oversize = "result ok phase=complete case="
    while (
        oversize.byte_length() + tail.byte_length()
        <= STRICT_MAX_REPORT_BYTES + 1
    ):
        oversize += "z"
    oversize += tail
    _report_controls(oversize, 0, "ready_output_overflow")

    guard_111.assert_clean()
    guard_112.assert_clean()
    guard_113.assert_clean()
    guard_114.assert_clean()


def test_startup_failure_cleanup_ownership_is_truthful() raises:
    # PC02/RA02: the shared startup-failure finalizer used by both provider
    # spawners must not claim an unproved termination as reaped; it records the
    # exact pid/reap status in the required guard and retains a usable
    # ownership handle for recovery.
    var guard = CleanupGuard()
    var state = piped_child_state(0, -1, 100, 1, UnsafePointer(to=guard))
    var status = finalize_owned_failure(state, 0, "startup cleanup unproved")
    assert_true(not status.cleanup_proved())
    assert_true(not state.reaped)
    assert_true(state.cleanup_error.startswith("unreaped"))
    assert_equal(guard.count(), 1)
    assert_equal(guard.retained(), 1)
    assert_true(guard.first().find("startup cleanup unproved") >= 0)
    assert_true(guard.first().find("pid=0") >= 0)

    var stub = _owned_report_child(guard, 0, VALID_REPORT)
    var owned = stub.pid
    var proved = finalize_owned_failure(stub.state, owned, "startup cleanup")
    assert_true(proved.cleanup_proved())
    assert_true(stub.state.reaped)
    assert_true(pid_not_waitable(owned))
    assert_equal(guard.count(), 1)
    # The real child was collected, so only the synthetic entry above remains.
    assert_true(not guard.is_clean())
    # The required check reports that unresolved entry truthfully rather than
    # silently discarding it.
    var synthetic = ""
    try:
        guard.assert_clean()
    except e:
        synthetic = String(e)
    assert_true(synthetic.find("cleanup-unproved") >= 0)


def test_descriptor_read_error_is_distinct_from_eof() raises:
    # PC01/PC03: an unavailable descriptor is a bounded read error, never an
    # EOF/empty success, for both the shared reader and the owned-child state.
    var pipe = make_pipe()
    var closed_fd = pipe.read_fd
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)
    var line_message = ""
    try:
        _ = read_line_bounded(closed_fd, 64, 200)
    except e:
        line_message = String(e)
    assert_equal(line_message, "read_error")
    var guard = CleanupGuard()
    var state = piped_child_state(
        closed_fd, closed_fd, 200, 1, UnsafePointer(to=guard)
    )
    var state_message = ""
    try:
        _ = state.read_line(64, 200)
    except e:
        state_message = String(e)
    assert_equal(state_message, "read_error")
    assert_true(not state.last_terminated)
    guard.assert_clean()


def test_multibyte_surplus_is_not_decoded_prematurely() raises:
    # PC01/LC03: a chunk that splits a multi-byte character after a newline must
    # be retained as bytes instead of raising a premature UTF-8 decode error.
    var pipe = make_pipe()
    _ = write_raw(pipe.write_fd, "ready 4242\n")
    var lead = List[UInt8]()
    lead.append(UInt8(0xC3))
    _ = write_raw_bytes(pipe.write_fd, lead)
    var guard = CleanupGuard()
    var state = piped_child_state(
        pid=0,
        report_fd=pipe.read_fd,
        deadline_ms=500,
        expected_requests=1,
        guard=UnsafePointer(to=guard),
    )
    var ready = state.read_line(64, 500)
    assert_equal(ready, "ready 4242")
    assert_true(state.last_terminated)
    var trail = List[UInt8]()
    trail.append(UInt8(0xA9))
    trail.append(UInt8(10))
    _ = write_raw_bytes(pipe.write_fd, trail)
    var letter = state.read_line(64, 500)
    state.close_reader()
    close_fd(pipe.write_fd)
    assert_equal(letter, "\u00e9")
    assert_true(state.last_terminated)
    guard.assert_clean()


def test_cleanup_failure_preserves_retryable_ownership() raises:
    # RA02: a controlled cleanup failure on a real owned child (the fault seam
    # reports an unproved cleanup while the real forked child keeps running)
    # must not mark it reaped or discard ownership; the retry collects the exact
    # same identity and the earlier entry is resolved, not left as a message.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var stub = spawn_max_local_stub(0, "count_requests", 1, guard, 2000)
    var actual = stub.pid
    stub.state.faults.cleanup_failures = 1
    stub.cleanup()
    assert_true(stub.cleanup_error().find("unreaped") >= 0)
    assert_true(not stub.status().cleanup_proved())
    assert_equal(guard.count(), 1)
    assert_equal(guard.retained(), 1)
    assert_true(pid_running(actual))
    stub.cleanup()
    assert_true(stub.status().cleanup_proved())
    assert_true(pid_not_waitable(actual))
    guard.assert_clean()
    assert_true(open_fd_count_checked() <= fd_before)

    var jev_guard = CleanupGuard()
    var jev_fd_before = open_fd_count_checked()
    var jev_stub = spawn_jev_stub_auto("ok", 1, jev_guard, 2000)
    var jev_actual = jev_stub.stub.pid
    jev_stub.stub.state.faults.cleanup_failures = 1
    jev_stub.stub.cleanup()
    assert_true(jev_stub.stub.cleanup_error().find("unreaped") >= 0)
    assert_equal(jev_guard.retained(), 1)
    assert_true(pid_running(jev_actual))
    jev_stub.stub.cleanup()
    assert_true(jev_stub.stub.status().cleanup_proved())
    assert_true(pid_not_waitable(jev_actual))
    jev_guard.assert_clean()
    assert_true(open_fd_count_checked() <= jev_fd_before)


def test_cleanup_recovery_through_guard_both_providers() raises:
    # RA02: a startup/scope cleanup failure must retain a *usable* ownership
    # handle on the required guard, and recovery must collect the exact real
    # child rather than only reporting a string.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var stub = spawn_max_local_stub(0, "count_requests", 1, guard, 2000)
    var actual = stub.pid
    stub.state.faults.cleanup_failures = 1
    stub.cleanup()
    assert_equal(guard.retained(), 1)
    assert_equal(guard.recover_all(), 0)
    assert_true(pid_not_waitable(actual))
    guard.assert_clean()
    # Recovery closes the retained report descriptor exactly once.
    assert_true(open_fd_count_checked() <= fd_before)

    var jev_guard = CleanupGuard()
    var jev_fd_before = open_fd_count_checked()
    var jev_stub = spawn_jev_stub_auto("ok", 1, jev_guard, 2000)
    var jev_actual = jev_stub.stub.pid
    jev_stub.stub.state.faults.cleanup_failures = 1
    jev_stub.stub.cleanup()
    assert_equal(jev_guard.retained(), 1)
    assert_equal(jev_guard.recover_all(), 0)
    assert_true(pid_not_waitable(jev_actual))
    jev_guard.assert_clean()
    assert_true(open_fd_count_checked() <= jev_fd_before)


def test_released_retained_descriptor_is_not_reclaimed_both_providers() raises:
    # MC03/RA02: once a retained report descriptor is released, a following
    # owned child that reuses that descriptor number must close its own
    # descriptor. The shared guard must not claim a reused number, which would
    # leak one descriptor per recovered failure (period-11 R73).
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var stub = spawn_max_local_stub(0, "count_requests", 1, guard, 2000)
    stub.state.faults.cleanup_failures = 1
    stub.cleanup()
    assert_equal(guard.retained(), 1)
    assert_equal(guard.recover_all(), 0)
    guard.assert_clean()
    var reused = spawn_max_local_stub(0, "count_requests", 1, guard, 2000)
    reused.cleanup()
    guard.assert_clean()
    assert_equal(open_fd_count_checked() - fd_before, 0)

    var jev_guard = CleanupGuard()
    var jev_fd_before = open_fd_count_checked()
    var jev_stub = spawn_jev_stub_auto("ok", 1, jev_guard, 2000)
    jev_stub.stub.state.faults.cleanup_failures = 1
    jev_stub.stub.cleanup()
    assert_equal(jev_guard.retained(), 1)
    assert_equal(jev_guard.recover_all(), 0)
    jev_guard.assert_clean()
    var jev_reused = spawn_jev_stub_auto("ok", 1, jev_guard, 2000)
    jev_reused.stub.cleanup()
    jev_guard.assert_clean()
    assert_equal(open_fd_count_checked() - jev_fd_before, 0)


def test_reap_wait_error_retains_ownership_both_providers() raises:
    # RA02: a transient wait error consumed by reap() must stay retryable and
    # must not become a cached terminal result; the retry reports success.
    var guard = CleanupGuard()
    var stub = _owned_report_child(guard, 0, VALID_REPORT)
    var actual = stub.pid
    stub.state.faults.wait_errors = 1
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "wait_error")
    assert_true(not stub.status().cleanup_proved())
    assert_equal(guard.retained(), 1)
    # The transient error must not be cached as a terminal observation.
    assert_true(stub.status().state != "wait_error")
    # A retry must observe the real child and still decode its valid report.
    stub.reap()
    assert_true(stub.ok())
    assert_equal(stub.phase(), "complete")
    assert_equal(stub.request_count(), 1)
    assert_true(stub.status().cleanup_proved())
    assert_true(pid_not_waitable(actual))
    guard.assert_clean()
    # A repeated reap is idempotent and does not re-wait or re-read.
    stub.reap()
    assert_true(stub.ok())
    assert_equal(stub.request_count(), 1)

    var jev_guard = CleanupGuard()
    var jev_stub = _owned_jev_report_child(jev_guard, 0, VALID_REPORT)
    var jev_actual = jev_stub.pid
    jev_stub.state.faults.wait_errors = 1
    jev_stub.reap()
    assert_true(not jev_stub.ok())
    assert_equal(jev_stub.reason(), "wait_error")
    assert_equal(jev_guard.retained(), 1)
    jev_stub.reap()
    assert_true(jev_stub.ok())
    assert_equal(jev_stub.request_count(), 1)
    assert_true(pid_not_waitable(jev_actual))
    jev_guard.assert_clean()


def test_unexpected_nonterminal_status_fails_closed_both_providers() raises:
    # RA02: an unexpected nonterminal wait status must fail closed and keep the
    # exact ownership instead of falling through to a report success.
    var guard = CleanupGuard()
    var stub = _owned_report_child(guard, 0, VALID_REPORT)
    var actual = stub.pid
    stub.state.faults.nonterminal = 1
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "unexpected_status")
    assert_true(not stub.status().cleanup_proved())
    assert_equal(guard.retained(), 1)
    # Recovery still collects the exact owned child.
    guard.recover_all()
    guard.assert_clean()
    assert_true(pid_not_waitable(actual))

    var jev_guard = CleanupGuard()
    var jev_stub = _owned_jev_report_child(jev_guard, 0, VALID_REPORT)
    var jev_actual = jev_stub.pid
    jev_stub.state.faults.nonterminal = 1
    jev_stub.reap()
    assert_true(not jev_stub.ok())
    assert_equal(jev_stub.reason(), "unexpected_status")
    jev_guard.recover_all()
    jev_guard.assert_clean()
    assert_true(pid_not_waitable(jev_actual))


def test_cleanup_failure_fails_normal_scope_exit_both_providers() raises:
    # RA01: an ordinary supported provider scope that exits normally must not
    # silently discard a cleanup failure. The exact-owned child is retained for
    # recovery, and the required guard check fails the owning test.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var held_pid = 0
    with spawn_max_local_stub(0, "count_requests", 1, guard) as stub:
        held_pid = stub.pid
        stub.inject_cleanup_failure()
    assert_true(pid_running(held_pid))
    var failure = ""
    try:
        guard.assert_clean()
    except e:
        failure = String(e)
    assert_true(failure.find("cleanup-unproved") >= 0)
    assert_equal(guard.recover_all(), 0)
    guard.assert_clean()
    assert_true(pid_not_waitable(held_pid))
    assert_true(open_fd_count_checked() <= fd_before)

    var jev_guard = CleanupGuard()
    var jev_fd_before = open_fd_count_checked()
    var jev_pid = 0
    with spawn_jev_stub_auto("ok", 1, jev_guard) as started:
        jev_pid = started.stub.pid
        started.stub.inject_cleanup_failure()
    var jev_failure = ""
    try:
        jev_guard.assert_clean()
    except e:
        jev_failure = String(e)
    assert_true(jev_failure.find("cleanup-unproved") >= 0)
    assert_equal(jev_guard.recover_all(), 0)
    jev_guard.assert_clean()
    assert_true(pid_not_waitable(jev_pid))
    assert_true(open_fd_count_checked() <= jev_fd_before)


def test_cleanup_failure_separately_exposed_with_body_cause() raises:
    # RA01: on the exception path the body/assertion cause must be preserved
    # exactly while the cleanup failure is separately exposed by the guard.
    var guard = CleanupGuard()
    var body_message = ""
    var held_pid = 0
    try:
        with spawn_max_local_stub(0, "count_requests", 1, guard) as stub:
            held_pid = stub.pid
            stub.inject_cleanup_failure()
            raise Error("intentional scope error")
    except e:
        body_message = String(e)
    # Body cause preserved, not replaced by the cleanup failure.
    assert_equal(body_message, "intentional scope error")
    assert_equal(guard.retained(), 1)
    var failure = ""
    try:
        guard.assert_clean()
    except e:
        failure = String(e)
    assert_true(failure.find("cleanup-unproved") >= 0)
    assert_equal(guard.recover_all(), 0)
    guard.assert_clean()
    assert_true(pid_not_waitable(held_pid))


def test_provider_reap_descriptor_read_error_both_paths() raises:
    # PC01: the descriptor-read control executes through BOTH provider reap
    # paths, not only the shared reader: a real owned child with an unavailable
    # report descriptor fails with read_error, never a silent EOF/empty report.
    var pipe = make_pipe()
    var closed_fd = pipe.read_fd
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)
    var pid = fork_pid()
    if pid == 0:
        child_exit(0)
    var guard = CleanupGuard()
    var state = piped_child_state(
        pid, closed_fd, 2000, 1, UnsafePointer(to=guard)
    )
    var stub = SpawnedMaxLocalStub(pid, 0, state^)
    stub.reap()
    assert_true(not stub.ok())
    assert_equal(stub.reason(), "read_error")
    assert_true(pid_not_waitable(pid))
    guard.assert_clean()

    var jev_pipe = make_pipe()
    var jev_closed_fd = jev_pipe.read_fd
    close_fd(jev_pipe.read_fd)
    close_fd(jev_pipe.write_fd)
    var jev_pid = fork_pid()
    if jev_pid == 0:
        child_exit(0)
    var jev_guard = CleanupGuard()
    var jev_state = piped_child_state(
        jev_pid, jev_closed_fd, 2000, 1, UnsafePointer(to=jev_guard)
    )
    var jev_stub = SpawnedJevStub(jev_pid, 0, jev_state^)
    jev_stub.reap()
    assert_true(not jev_stub.ok())
    assert_equal(jev_stub.reason(), "read_error")
    assert_true(pid_not_waitable(jev_pid))
    jev_guard.assert_clean()


def test_cleanup_failure_survives_scope_exit() raises:
    # RA01/PC02: cleanup failure must remain observable after the owning handle
    # is destroyed at scope exit, for BOTH provider handles, because the guard
    # is owned by the calling test rather than the handle.
    var guard = CleanupGuard()
    var state = piped_child_state(0, -1, 100, 1, UnsafePointer(to=guard))
    with SpawnedMaxLocalStub(0, 0, state^) as holder:
        _ = holder
    assert_equal(guard.count(), 1)
    assert_true(guard.first().find("unproved") >= 0)
    var jev_state = piped_child_state(0, -1, 100, 1, UnsafePointer(to=guard))
    with SpawnedJevStub(0, 0, jev_state^) as jev_holder:
        _ = jev_holder
    assert_equal(guard.count(), 2)
    assert_true(guard.first().find("unproved") >= 0)
    var failure = ""
    try:
        guard.assert_clean()
    except e:
        failure = String(e)
    assert_true(failure.find("cleanup-unproved") >= 0)


@fieldwise_init
struct ForkedReportChild(Movable):
    """A real owned child whose bounded report emission is controlled by delay.
    """

    var pid: Int
    var read_fd: Int


def _fork_budget_child(
    delay_ms: Int, report: String
) raises -> ForkedReportChild:
    """Fork a real owned child that writes ``report`` after ``delay_ms``."""
    var pipe = make_pipe()
    var pid = fork_pid()
    if pid == 0:
        close_fd(pipe.read_fd)
        sleep_ms(delay_ms)
        if report != "":
            _ = write_raw(pipe.write_fd, report)
        close_fd(pipe.write_fd)
        child_exit(0)
    close_fd(pipe.write_fd)
    return ForkedReportChild(pid, pipe.read_fd)


def test_report_after_work_budget_is_rejected_both_providers() raises:
    # RA03: the period-9 counterexample. The child emits a *valid* report after
    # 200 ms while the declared budget is 100 ms and the parent observes it at
    # 300 ms; the late report must be rejected and the exact-owned child
    # collected within the bounded cleanup allowance, never accepted with a
    # fresh success interval.
    for provider in range(2):
        var guard = CleanupGuard()
        var probe = _fork_budget_child(200, VALID_REPORT)
        var start = now_ms()
        var state = piped_child_state(
            probe.pid, probe.read_fd, 100, 1, UnsafePointer(to=guard)
        )
        # The parent consumes its declared budget without observing the child,
        # exactly as in the period-9 counterexample.
        sleep_ms(300)
        if provider == 0:
            var stub = SpawnedMaxLocalStub(probe.pid, 0, state^)
            stub.reap()
            assert_true(not stub.ok())
            assert_equal(stub.reason(), "work_budget_expired")
            assert_true(stub.status().cleanup_proved())
        else:
            var stub = SpawnedJevStub(probe.pid, 0, state^)
            stub.reap()
            assert_true(not stub.ok())
            assert_equal(stub.reason(), "work_budget_expired")
            assert_true(stub.status().cleanup_proved())
        var elapsed = now_ms() - start
        # Only the bounded cleanup allowance is added after the budget expired.
        assert_true(elapsed <= 100 + 2000 + 500)
        assert_true(pid_not_waitable(probe.pid))
        guard.assert_clean()


def test_report_within_work_budget_succeeds_both_providers() raises:
    # RA03 positive control: the same budgeted path accepts a report that is
    # emitted and observed inside the declared budget.
    for provider in range(2):
        var guard = CleanupGuard()
        var probe = _fork_budget_child(20, VALID_REPORT)
        var state = piped_child_state(
            probe.pid, probe.read_fd, 4000, 1, UnsafePointer(to=guard)
        )
        if provider == 0:
            var stub = SpawnedMaxLocalStub(probe.pid, 0, state^)
            stub.reap()
            assert_true(stub.ok())
            assert_equal(stub.phase(), "complete")
            assert_equal(stub.request_count(), 1)
        else:
            var stub = SpawnedJevStub(probe.pid, 0, state^)
            stub.reap()
            assert_true(stub.ok())
            assert_equal(stub.phase(), "complete")
            assert_equal(stub.request_count(), 1)
        assert_true(pid_not_waitable(probe.pid))
        guard.assert_clean()


def test_report_drain_deadline_is_bounded() raises:
    # RA03: the report EOF-drain stage honours a finite deadline instead of a
    # fresh unbounded interval; a report descriptor that never reaches EOF must
    # fail with the drain deadline cause, never hang or succeed.
    var pipe = make_pipe()
    _ = write_raw(
        pipe.write_fd,
        "result ok phase=complete case=- reason=ok requests=1 connections=1\n",
    )
    var guard = CleanupGuard()
    var state = piped_child_state(
        0, pipe.read_fd, 500, 1, UnsafePointer(to=guard)
    )
    var line = state.read_line(STRICT_MAX_REPORT_BYTES, 500)
    assert_true(state.last_terminated)
    assert_true(line.startswith("result ok"))
    var reason = ""
    try:
        _ = state.drain_surplus(STRICT_MAX_REPORT_BYTES, 60)
    except e:
        reason = String(e)
    state.close_reader()
    close_fd(pipe.write_fd)
    assert_equal(reason, "read_deadline_expired")
    guard.assert_clean()


def test_work_budget_delay_rejects_before_report_both_providers() raises:
    # RA03: time consumed inside the wait phase counts against the same finite
    # budget, so an exhausted budget rejects even when a valid report is already
    # buffered on the owned descriptor.
    for provider in range(2):
        var guard = CleanupGuard()
        var probe = _fork_budget_child(0, VALID_REPORT)
        var state = piped_child_state(
            probe.pid, probe.read_fd, 400, 1, UnsafePointer(to=guard)
        )
        state.faults.wait_delay_ms = 900
        if provider == 0:
            var stub = SpawnedMaxLocalStub(probe.pid, 0, state^)
            stub.reap()
            assert_true(not stub.ok())
            assert_equal(stub.reason(), "work_budget_expired")
            assert_true(stub.status().cleanup_proved())
        else:
            var stub = SpawnedJevStub(probe.pid, 0, state^)
            stub.reap()
            assert_true(not stub.ok())
            assert_equal(stub.reason(), "work_budget_expired")
            assert_true(stub.status().cleanup_proved())
        assert_true(pid_not_waitable(probe.pid))
        guard.assert_clean()


def test_descriptor_census_error_classes() raises:
    # RA04: EBADF is a closed slot, EINTR is a bounded retry, and any other
    # lookup error makes the census unavailable instead of silently lowering
    # the count. The seam changes no host limit.
    assert_equal(classify_census_errno(9), "closed")
    assert_equal(classify_census_errno(4), "retry")
    assert_equal(classify_census_errno(5), "unavailable")
    var before = open_fd_count_checked()
    assert_true(before > 0)
    # EBADF at an open slot is a closed slot: the count is simply lower.
    assert_equal(descriptor_census_with_faults(3, 0, 9), 2)
    # Any other lookup error makes the whole census unavailable.
    assert_equal(descriptor_census_with_faults(3, 0, 5), -1)
    var unavailable = ""
    try:
        _ = open_fd_count_checked_with_faults(3, 0, 5)
    except e:
        unavailable = String(e)
    assert_equal(unavailable, "descriptor_census_unavailable")
    assert_equal(open_fd_count_checked(), before)


def test_descriptor_census_unavailable_propagates() raises:
    # PC04: an unavailable or incomplete-range census must fail explicitly
    # through the checked caller rather than look like a small passing count.
    assert_equal(descriptor_census(0), -1)
    var zero_reason = ""
    try:
        _ = open_fd_count_checked(0)
    except e:
        zero_reason = String(e)
    assert_equal(zero_reason, "descriptor_census_unavailable")
    var ceiling_reason = ""
    try:
        _ = open_fd_count_checked(CENSUS_MAX_FDS + 1)
    except e:
        ceiling_reason = String(e)
    assert_equal(ceiling_reason, "descriptor_census_unavailable")
    assert_true(open_fd_count_checked() > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
