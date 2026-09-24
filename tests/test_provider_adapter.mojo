from std.collections import List
from std.ffi import ErrNo
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from json import Value, loads

from hyf_assist.contract import max_local_query_rewrite_route
from hyf_core.request_context import default_request_context
from hyf_provider.client import (
    get_max_local_health,
    max_local_chat_completions_url,
    post_max_local_chat_completion,
)
from hyf_provider.config import (
    MaxLocalProviderConfig,
    max_local_provider_config_from_runtime,
)
from hyf_provider.health import max_local_health_failure_from_reason
from hyf_provider.max_local import max_local_query_rewrite_failure_from_reason
from hyf_provider.result import parse_query_analysis_from_chat_completion
from hyf_provider.schema import build_query_rewrite_request_body
from hyf_runtime.config import (
    HyfAssistedRuntimeConfig,
    HyfExecutionRuntimeConfig,
    HyfLoadedRuntimeConfig,
    HyfMaxLocalProviderRuntimeConfig,
    HyfRuntimeConfig,
    HyfServiceRuntimeConfig,
    default_loaded_runtime_config,
)
from parent_lifecycle import CleanupGuard, now_ms, open_fd_count_checked
from max_local_process_helper import (
    reserve_loopback_port,
    spawn_max_local_scripted,
    spawn_max_local_stub,
)
from bounded_call_helper import (
    BoundedCallReport,
    account_raw_bytes,
    parse_bounded_report,
    run_bounded_call,
)
from strict_fixture import (
    ExchangeScript,
    exchange_script,
    is_peer_close_cause,
    json_escape,
    write_errno_class,
)

# H007 BC02: each bounded-call invocation carries its own correlation value, so
# a report produced for one call can never be accepted for another.
comptime BOUNDED_CORRELATION_REFUSAL = 101
comptime BOUNDED_CORRELATION_BODY_STALL = 102
comptime BOUNDED_CORRELATION_DELAYED_HEAD = 103
comptime BOUNDED_CORRELATION_DELAYED_SUCCESS = 104
comptime BOUNDED_CORRELATION_RAW_HEAD_BODY = 105
comptime BOUNDED_CORRELATION_BOUNDED_STALL = 106
comptime BOUNDED_CORRELATION_NEVER_RETURN = 107
comptime BOUNDED_CORRELATION_RETAINED_CLEANUP = 108
comptime BOUNDED_CORRELATION_REUSED_DESCRIPTOR = 109
comptime BOUNDED_CORRELATION_MUTANT_EXIT7 = 111
comptime BOUNDED_CORRELATION_MUTANT_UNTERMINATED = 112
comptime BOUNDED_CORRELATION_MUTANT_DUPLICATE = 113
comptime BOUNDED_CORRELATION_MUTANT_DELAYED = 114
comptime BOUNDED_CORRELATION_MUTANT_HUGE = 115
comptime BOUNDED_CORRELATION_WAIT_ERROR = 116
# H007 RP01: distinct correlations for the repaired raw byte-accounting controls.
comptime BOUNDED_CORRELATION_RAW_COALESCED = 117
comptime BOUNDED_CORRELATION_RAW_EMPTY = 118
comptime BOUNDED_CORRELATION_RAW_TRUNCATED = 119
comptime BOUNDED_CORRELATION_RAW_SPLIT_UTF8 = 120
# H007 RP02: distinct correlations for the real-consumer error/retry controls.
comptime BOUNDED_CORRELATION_EARLY_EOF = 121
comptime BOUNDED_CORRELATION_SIGNALED = 122
comptime BOUNDED_CORRELATION_INVALID_UTF8 = 123
comptime BOUNDED_CORRELATION_LATE_EXIT = 124
comptime BOUNDED_CORRELATION_EINTR_RETRY = 125
comptime BOUNDED_CORRELATION_EINTR_DEADLINE = 126
comptime BOUNDED_CORRELATION_POLL_ERROR = 127
# H007 RP03: distinct correlations for the real/synthetic write-error controls.
comptime BOUNDED_CORRELATION_SYNTHETIC_TIMEOUT = 128
comptime BOUNDED_CORRELATION_SYNTHETIC_DESCRIPTOR = 129
comptime BOUNDED_CORRELATION_REAL_ERRNO = 130
comptime BOUNDED_CORRELATION_DECLARED_VS_SYNTHETIC = 131
# H007 RP01: malformed/error raw-observation controls.
comptime BOUNDED_CORRELATION_RAW_EOF = 132
comptime BOUNDED_CORRELATION_RAW_MALFORMED = 133
# H007 OB01-OB03: period-14 observation-integrity controls.
comptime BOUNDED_CORRELATION_OB_UNKNOWN_LENGTH = 140
comptime BOUNDED_CORRELATION_OB_JUNK_LENGTH = 141
comptime BOUNDED_CORRELATION_OB_DUP_LENGTH = 142
comptime BOUNDED_CORRELATION_OB_OVER_CAP = 143
comptime BOUNDED_CORRELATION_OB_SURPLUS = 144
comptime BOUNDED_CORRELATION_OB_NO_LENGTH = 145
comptime BOUNDED_CORRELATION_OB_SPLIT_TERMINATOR = 146
comptime BOUNDED_CORRELATION_OB_SPLIT_BODY = 147
comptime BOUNDED_CORRELATION_OB_NEAR_CAP = 148
comptime BOUNDED_CORRELATION_OB_MALFORMED_HEAD = 149
comptime BOUNDED_CORRELATION_OB_SYNTHETIC = 150
# H007 D44/IL01: distinct correlations for the inclusive raw-body-cap boundary
# controls (declared and EOF-delimited) through the actual acquisition path.
comptime BOUNDED_CORRELATION_OB_CAP_DECLARED_MINUS = 151
comptime BOUNDED_CORRELATION_OB_CAP_DECLARED_EXACT = 152
comptime BOUNDED_CORRELATION_OB_CAP_DECLARED_PLUS = 153
comptime BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_MINUS = 154
comptime BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_EXACT = 155
comptime BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_PLUS = 156
comptime BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_STALL = 157

from flare.net import SocketAddr
from flare.tcp import TcpStream


def _provider_runtime_config() -> HyfLoadedRuntimeConfig:
    var runtime = HyfExecutionRuntimeConfig()
    runtime.default_execution_mode = "deterministic"
    runtime.allow_assisted = True
    var assisted = HyfAssistedRuntimeConfig()
    assisted.provider = "max_local"
    assisted.max_local = HyfMaxLocalProviderRuntimeConfig(
        enabled=True,
        base_url="http://127.0.0.1:8000/v1/",
        health_url="http://127.0.0.1:8000/health",
        model="max-local-query-rewrite",
        request_timeout_ms=15000,
    )
    return HyfLoadedRuntimeConfig(
        artifact_present=True,
        loaded=True,
        compiled_defaults_active=False,
        load_state="loaded",
        load_error="",
        effective=HyfRuntimeConfig(
            service=HyfServiceRuntimeConfig(transport="stdio"),
            runtime=runtime.copy(),
            assisted=assisted.copy(),
        ),
    )


def _provider_config() -> MaxLocalProviderConfig:
    return MaxLocalProviderConfig(
        base_url="http://127.0.0.1:8000/v1/",
        health_url="http://127.0.0.1:8000/health",
        model="max-local-query-rewrite",
        request_timeout_ms=15000,
    )


def _provider_config_for_port(port: Int) -> MaxLocalProviderConfig:
    return MaxLocalProviderConfig(
        base_url="http://127.0.0.1:" + String(port) + "/v1/",
        health_url="http://127.0.0.1:" + String(port) + "/health",
        model="max-local-query-rewrite",
        request_timeout_ms=15000,
    )


def _invalid_base_url_provider_config() -> MaxLocalProviderConfig:
    return MaxLocalProviderConfig(
        base_url="ftp://127.0.0.1:8000/v1/",
        health_url="http://127.0.0.1:8000/health",
        model="max-local-query-rewrite",
        request_timeout_ms=15000,
    )


def _invalid_health_url_provider_config() -> MaxLocalProviderConfig:
    return MaxLocalProviderConfig(
        base_url="http://127.0.0.1:8000/v1/",
        health_url="ftp://127.0.0.1:8000/health",
        model="max-local-query-rewrite",
        request_timeout_ms=15000,
    )


def _analysis_json_text() -> String:
    return (
        '{"original_text":"eggs near me",'
        '"normalized_text":"eggs near me",'
        '"rewritten_text":"eggs",'
        '"query_terms":["eggs"],'
        '"normalization_signals":["local_intent_detected"],'
        '"ranking_hints":["prefer_local_results"],'
        '"extracted_filters":{'
        '"local_intent":true,'
        '"fulfillment":"unspecified",'
        '"time_window":"unspecified"'
        "}}"
    )


def _chat_completion_response_with_content(content: String) raises -> Value:
    var response = loads("{}")
    var choices = loads("[]")
    var choice = loads("{}")
    var message = loads("{}")
    message.set("content", Value(content))
    choice.set("message", message)
    choices.append(choice)
    response.set("choices", choices)
    return response^


def _chat_completion_response() raises -> Value:
    return _chat_completion_response_with_content(_analysis_json_text())


def _assert_query_rewrite_failure(
    reason: String, expected_kind: String, expected_reason: String
) raises:
    var failure = max_local_query_rewrite_failure_from_reason(reason)
    assert_equal(failure.kind, expected_kind)
    assert_equal(failure.reason, expected_reason)


def _assert_health_failure(
    reason: String, expected_kind: String, expected_reason: String
) raises:
    var failure = max_local_health_failure_from_reason(reason)
    assert_equal(failure.kind, expected_kind)
    assert_equal(failure.reason, expected_reason)


def _assert_chat_completion_parse_failure(
    response: Value, expected_error: String
) raises:
    try:
        _ = parse_query_analysis_from_chat_completion(response)
    except e:
        assert_equal(String(e), expected_error)
        return
    raise Error("expected chat completion parse failure")


def test_provider_config_maps_runtime_config() raises:
    var config = max_local_provider_config_from_runtime(
        _provider_runtime_config()
    )

    assert_equal(config.base_url, "http://127.0.0.1:8000/v1/")
    assert_equal(config.health_url, "http://127.0.0.1:8000/health")
    assert_equal(config.model, "max-local-query-rewrite")
    assert_equal(config.request_timeout_ms, 15000)


def test_max_local_route_is_derived_from_assisted_contract() raises:
    assert_equal(
        max_local_query_rewrite_route(),
        "provider_runtime.query_rewrite.max_local",
    )


def test_max_local_provider_failure_mapping_preserves_reason_tokens() raises:
    _assert_query_rewrite_failure("timeout", "transport", "timeout")
    _assert_query_rewrite_failure(
        "connection_failed", "transport", "connection_failed"
    )
    _assert_query_rewrite_failure("invalid_url", "transport", "invalid_url")
    _assert_query_rewrite_failure(
        "provider_non_2xx", "http_status", "provider_non_2xx"
    )
    _assert_query_rewrite_failure(
        "provider_error_payload",
        "provider_payload",
        "provider_error_payload",
    )
    _assert_query_rewrite_failure(
        "provider_invalid_json",
        "provider_payload",
        "provider_invalid_json",
    )
    _assert_query_rewrite_failure(
        "provider_schema_invalid",
        "provider_payload",
        "provider_schema_invalid",
    )
    _assert_query_rewrite_failure(
        "provider_empty_choices",
        "provider_payload",
        "provider_empty_choices",
    )
    _assert_query_rewrite_failure(
        "provider_missing_content",
        "provider_payload",
        "provider_missing_content",
    )
    _assert_query_rewrite_failure(
        "unknown_transport", "provider", "provider_error"
    )
    _assert_query_rewrite_failure(
        "unknown_provider", "provider", "provider_error"
    )


def test_max_local_health_failure_mapping_preserves_reason_tokens() raises:
    _assert_health_failure("timeout", "transport", "timeout")
    _assert_health_failure("invalid_url", "transport", "invalid_url")
    _assert_health_failure(
        "connection_failed", "transport", "connection_failed"
    )
    _assert_health_failure("non_2xx", "http_status", "non_2xx")
    _assert_health_failure(
        "unknown_transport", "transport", "connection_failed"
    )


def test_provider_config_rejects_unconfigured_runtime() raises:
    with assert_raises():
        _ = max_local_provider_config_from_runtime(
            default_loaded_runtime_config()
        )


def test_max_local_chat_completions_url_trims_base_url() raises:
    assert_equal(
        max_local_chat_completions_url(_provider_config()),
        "http://127.0.0.1:8000/v1/chat/completions",
    )


def test_max_local_transport_boundary_rejects_invalid_chat_url() raises:
    var outcome = post_max_local_chat_completion(
        _invalid_base_url_provider_config(), loads("{}")
    )

    assert_true(outcome.failure)
    assert_true(not outcome.response)
    assert_equal(outcome.failure.value().kind, "transport")
    assert_equal(outcome.failure.value().reason, "invalid_url")


def test_max_local_transport_boundary_rejects_invalid_health_url() raises:
    var outcome = get_max_local_health(_invalid_health_url_provider_config())

    assert_true(outcome.failure)
    assert_true(not outcome.response)
    assert_equal(outcome.failure.value().kind, "transport")
    assert_equal(outcome.failure.value().reason, "invalid_url")


def test_max_local_transport_boundary_reports_unknown_chat_transport() raises:
    var guard_1 = CleanupGuard()
    with spawn_max_local_stub(
        0, "query_rewrite_malformed_http", 1, guard_1
    ) as provider_stub:
        var provider_port = provider_stub.port
        var outcome = post_max_local_chat_completion(
            _provider_config_for_port(provider_port), loads("{}")
        )

        assert_true(outcome.failure)
        assert_true(not outcome.response)
        assert_equal(outcome.failure.value().kind, "transport")
        assert_equal(outcome.failure.value().reason, "unknown_transport")

        provider_stub.wait()

    guard_1.assert_clean()


def test_max_local_transport_boundary_reports_unknown_health_transport() raises:
    var guard_2 = CleanupGuard()
    with spawn_max_local_stub(
        0, "health_malformed_http", 1, guard_2
    ) as provider_stub:
        var provider_port = provider_stub.port
        var outcome = get_max_local_health(
            _provider_config_for_port(provider_port)
        )

        assert_true(outcome.failure)
        assert_true(not outcome.response)
        assert_equal(outcome.failure.value().kind, "transport")
        assert_equal(outcome.failure.value().reason, "unknown_transport")

        provider_stub.wait()

    guard_2.assert_clean()


def test_query_rewrite_request_body_sets_schema_contract() raises:
    var context = default_request_context()
    context.return_provenance = True
    var body = build_query_rewrite_request_body(
        _provider_config(), "eggs near me", context
    )

    assert_equal(body["model"].string_value(), "max-local-query-rewrite")
    assert_equal(body["messages"][0]["role"].string_value(), "system")
    assert_equal(body["messages"][1]["role"].string_value(), "user")
    assert_true(
        body["messages"][1]["content"].string_value().find("eggs near me") >= 0
    )
    assert_equal(body["response_format"]["type"].string_value(), "json_schema")
    assert_equal(
        body["response_format"]["json_schema"]["name"].string_value(),
        "query_rewrite",
    )
    assert_equal(
        body["response_format"]["json_schema"]["strict"].bool_value(), True
    )
    assert_equal(
        body["response_format"]["json_schema"]["schema"]["type"].string_value(),
        "object",
    )


def test_chat_completion_response_parses_query_analysis() raises:
    var analysis = parse_query_analysis_from_chat_completion(
        _chat_completion_response()
    )

    assert_equal(analysis.original_text, "eggs near me")
    assert_equal(analysis.normalized_text, "eggs near me")
    assert_equal(analysis.rewritten_text, "eggs")
    assert_equal(len(analysis.query_terms), 1)
    assert_equal(analysis.query_terms[0], "eggs")
    assert_equal(analysis.extracted_filters.local_intent, True)


def test_chat_completion_response_rejects_invalid_json_content() raises:
    _assert_chat_completion_parse_failure(
        _chat_completion_response_with_content("not json"),
        "provider_invalid_json",
    )


def test_chat_completion_response_rejects_schema_invalid_content() raises:
    _assert_chat_completion_parse_failure(
        _chat_completion_response_with_content('{"original_text":"eggs"}'),
        "provider_schema_invalid",
    )


def test_chat_completion_response_rejects_empty_choices() raises:
    with assert_raises():
        _ = parse_query_analysis_from_chat_completion(loads('{"choices":[]}'))


def test_chat_completion_response_rejects_top_level_scalar() raises:
    with assert_raises():
        _ = parse_query_analysis_from_chat_completion(loads('"not object"'))


def test_chat_completion_response_rejects_top_level_array() raises:
    with assert_raises():
        _ = parse_query_analysis_from_chat_completion(loads("[]"))


def test_chat_completion_response_rejects_top_level_null() raises:
    with assert_raises():
        _ = parse_query_analysis_from_chat_completion(loads("null"))


def _bounded_timeout_provider_config(
    port: Int, timeout_ms: Int
) -> MaxLocalProviderConfig:
    return MaxLocalProviderConfig(
        base_url="http://127.0.0.1:" + String(port) + "/v1/",
        health_url="http://127.0.0.1:" + String(port) + "/health",
        model="max-local-query-rewrite",
        request_timeout_ms=timeout_ms,
    )


def test_provider_refused_connection_is_bounded_and_specific() raises:
    # H007/BC01: a refused connection is a bounded, cause-specific transport
    # failure, not a hang. The risky product call runs under the parent-enforced
    # finite deadline through the shared bounded-call consumer, and it is
    # explicitly characterized as a refusal, not as a real connect-timeout
    # scenario. No provider client policy is changed here.
    var guard = CleanupGuard()
    var dead_port = reserve_loopback_port()
    var report = run_bounded_call(
        "max_local", dead_port, 300, 5000, guard, BOUNDED_CORRELATION_REFUSAL
    )
    assert_true(report.completed)
    assert_true(not report.stopped)
    assert_true(report.problem == "")
    assert_true(report.domain_failure())
    assert_equal(report.outcome, "fail")
    assert_equal(report.cause, "transport")
    # Current characterized gap: a fast refused connection is not distinguished
    # from an unknown transport error, because the elapsed time is below the
    # declared request budget.
    assert_equal(report.reason, "unknown_transport")
    assert_true(report.cleanup_proved)
    assert_true(report.elapsed_ms < 5000)
    guard.assert_clean()


def test_provider_headers_then_stall_is_bounded_and_specific() raises:
    # H007: the fixture delivers the response head and then stalls the body.
    # Characterized current gap: the declared request timeout does not bound a
    # body-read stall, so the response is returned only after the stall
    # completes. The control is non-hanging and does not change client policy.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "headers_then_stall",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.stall_after_head_ms = 1200
    scripts.append(script^)
    var guard_2 = CleanupGuard()
    var timeout_ms = 300
    with spawn_max_local_scripted(0, scripts^, guard_2) as provider_stub:
        var report = run_bounded_call(
            "max_local",
            provider_stub.port,
            timeout_ms,
            5000,
            guard_2,
            BOUNDED_CORRELATION_BODY_STALL,
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_true(report.latency_ms >= 1200)
        assert_true(report.elapsed_ms < 5000)
        provider_stub.wait()
    guard_2.assert_clean()


def test_provider_delayed_head_is_bounded_and_specific() raises:
    # H007: a fixture that delays the whole response beyond the request budget
    # is characterized as the same pre-migration gap: the declared timeout does
    # not bound the delayed response, which is still returned after it arrives.
    # The control is non-hanging and does not change client policy.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "delayed_head",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.delay_ms = 1200
    scripts.append(script^)
    var guard_3 = CleanupGuard()
    var timeout_ms = 300
    with spawn_max_local_scripted(0, scripts^, guard_3) as provider_stub:
        var report = run_bounded_call(
            "max_local",
            provider_stub.port,
            timeout_ms,
            5000,
            guard_3,
            BOUNDED_CORRELATION_DELAYED_HEAD,
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_true(report.latency_ms >= 1200)
        assert_true(report.elapsed_ms < 5000)
        provider_stub.wait()
    guard_3.assert_clean()


def _raw_request_text(path: String) -> String:
    return (
        "POST "
        + path
        + " HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 2\r\n"
        "connection: close\r\n\r\n{}"
    )


def _raw_send_then_close(port: Int, path: String) raises:
    """A deliberately owned raw client that closes right after its request.

    Used to produce a real peer close during the scripted delayed/body-stall
    write without any host or policy change.
    """
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    client.write_all(Span[UInt8, _](_raw_request_text(path).as_bytes()))
    client.close()


def _raw_send_and_read(port: Int, path: String) raises -> String:
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    client.write_all(Span[UInt8, _](_raw_request_text(path).as_bytes()))
    var response = String("")
    var buffer = InlineArray[Byte, 1024](fill=0)
    while True:
        var n = client.read(buffer.unsafe_ptr(), 1024)
        if n <= 0:
            break
        response += String(
            unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n))
        )
    client.close()
    return response^


def _delayed_script(label: String, delay_ms: Int) -> ExchangeScript:
    var script = exchange_script(
        label, "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.delay_ms = delay_ms
    return script^


def test_provider_strict_delayed_success_under_bounded_harness() raises:
    # TC01/TC02: a delayed response is not permission to swallow errors. With a
    # client budget above the delay the strict scripted exchange must succeed,
    # and the risky call runs under the exact-owned parent-bounded mechanism.
    var scripts = List[ExchangeScript]()
    var script = _delayed_script("delayed_success", 300)
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "max_local",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_DELAYED_SUCCESS,
        )
        assert_true(report.ok())
        assert_true(not report.stopped)
        assert_equal(report.status, 200)
        assert_equal(report.problem, "")
        assert_true(report.latency_ms >= 300)
        assert_true(report.cleanup_proved)
        provider_stub.wait()
        assert_true(provider_stub.ok())
        assert_equal(provider_stub.request_count(), 1)
        assert_equal(provider_stub.connection_count(), 1)
    guard.assert_clean()


def test_provider_stall_sends_headers_before_body() raises:
    # TC02/BC01: prove the fixture delivered the response head before the
    # bounded body stall, so the stall control characterizes a body-read stall
    # rather than an unrelated connect/refusal condition. The raw header/body
    # observation runs through the same parent-bounded consumer as the product
    # call, so a hanging peer cannot hang the owning test.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "head_then_stall", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 800
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_RAW_HEAD_BODY,
            "/v1/chat/completions",
            "choices",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_true(report.head_ms < 400)
        assert_true(report.total_ms >= 700)
        assert_equal(report.body_match, "yes")
        assert_true(report.body_bytes > 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_accounts_coalesced_body() raises:
    # RP01: a body that arrives coalesced with the header terminator must be
    # accounted as body bytes, never discarded. The scripted exchange writes
    # head and body together, so the unchanged raw observer must report the
    # exact eight-byte BODYMARK body with a matching declared length.
    var scripts = List[ExchangeScript]()
    scripts.append(
        exchange_script(
            "coalesced_body", "POST", "/v1/chat/completions", 200, "BODYMARK"
        )
    )
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_RAW_COALESCED,
            "/v1/chat/completions",
            "BODYMARK",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, 8)
        assert_equal(report.body_match, "yes")
        assert_equal(report.declared_bytes, 8)
        assert_equal(report.length_match, "yes")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_accounts_empty_body() raises:
    # RP01: a declared zero-length body is an exact observation, not a missing
    # one: body_bytes is 0 while the declared length still matches.
    var scripts = List[ExchangeScript]()
    scripts.append(
        exchange_script("empty_body", "POST", "/v1/chat/completions", 200, "")
    )
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_RAW_EMPTY,
            "/v1/chat/completions",
            "",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, 0)
        assert_equal(report.body_match, "unknown")
        assert_equal(report.declared_bytes, 0)
        assert_equal(report.length_match, "yes")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_reports_truncated_length_mismatch() raises:
    # OB02: an explicit truncation control. The peer declares twenty body bytes
    # but sends five and closes; the observer must report an explicit
    # incomplete observation with the exact five observed bytes and the twenty
    # declared, never an unqualified successful call.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "truncated_body", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n"
        "content-length: 20\r\nconnection: close\r\n\r\nSHORT"
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_RAW_TRUNCATED,
            "/v1/chat/completions",
            "SHORT",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_body_incomplete")
        assert_equal(report.status, 0)
        assert_equal(report.body_bytes, 5)
        assert_equal(report.body_match, "yes")
        assert_equal(report.declared_bytes, 20)
        assert_equal(report.length_match, "no")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_split_utf8_body_is_preserved() raises:
    # RP01: a multi-byte body is preserved whole. The observer accumulates
    # bytes and searches them directly, so a split character can never be
    # misread as a read/packet boundary.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "split_utf8_body",
        "POST",
        "/v1/chat/completions",
        200,
        '{"mark":"a☃b"}',
    )
    script.stall_after_head_ms = 250
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_RAW_SPLIT_UTF8,
            "/v1/chat/completions",
            "a☃b",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, '{"mark":"a☃b"}'.byte_length())
        assert_equal(report.body_match, "yes")
        assert_equal(report.length_match, "yes")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_raw_accounting_preserves_split_utf8_bytes() raises:
    # RP01: the byte accounting itself is chunk-independent. The same bytes are
    # supplied as two pieces whose boundary falls inside the three-byte
    # character, and the observation is still exact.
    var head = "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\n"
    var body = "a☃b"
    var raw = List[UInt8]()
    for byte in head.as_bytes():
        raw.append(UInt8(Int(byte)))
    for byte in body.as_bytes():
        raw.append(UInt8(Int(byte)))
    assert_equal(len(raw), head.byte_length() + body.byte_length())
    var boundary = head.byte_length() + 3
    var split = List[UInt8]()
    for index in range(boundary):
        split.append(raw[index])
    for index in range(boundary, len(raw)):
        split.append(raw[index])
    var accounting = account_raw_bytes(split^, "☃")
    assert_equal(accounting.problem, "")
    assert_equal(accounting.status, 200)
    assert_equal(accounting.body_bytes, 5)
    assert_equal(accounting.body_match, "yes")
    assert_equal(accounting.declared_bytes, 5)
    assert_equal(accounting.length_match, "yes")


def test_raw_accounting_reports_incomplete_head() raises:
    # RP01: a buffer with no header terminator is an explicit incomplete-head
    # observation, never a completed call with invented fields.
    var raw = List[UInt8]()
    for byte in "HTTP/1.1 200 OK\r\ncontent-length: 3".as_bytes():
        raw.append(UInt8(Int(byte)))
    var accounting = account_raw_bytes(raw^, "abc")
    assert_equal(accounting.problem, "raw_head_incomplete")
    assert_equal(accounting.body_bytes, 0)
    assert_equal(accounting.status, 0)


def test_raw_accounting_reports_undecodable_head() raises:
    # RP01: an undecodable header block is a bounded decode failure, not a
    # silently accepted status/body observation.
    var raw = List[UInt8]()
    for byte in "HTTP/1.1 200 OK\r\nx: ".as_bytes():
        raw.append(UInt8(Int(byte)))
    raw.append(UInt8(0xFF))
    for byte in "\r\n\r\n".as_bytes():
        raw.append(UInt8(Int(byte)))
    var accounting = account_raw_bytes(raw^, "")
    assert_equal(accounting.problem, "raw_head_decode")
    assert_equal(accounting.status, 0)


def test_provider_raw_head_body_reports_peer_close_without_head() raises:
    # RP01: a peer that closes before sending any response head is a bounded
    # raw_eof domain failure, not a hang and not an invented status.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "close_without_head", "POST", "/v1/chat/completions", 200, "{}"
    )
    script.close_before_response = True
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_RAW_EOF,
            "/v1/chat/completions",
            "x",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_eof")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_reports_malformed_status() raises:
    # RP01: a malformed response with a terminator but no HTTP status line must
    # be reported as a bounded malformed observation (status_missing), never
    # read as a successful response with an invented status.
    var guard = CleanupGuard()
    with spawn_max_local_stub(
        0, "query_rewrite_malformed_http", 1, guard
    ) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_RAW_MALFORMED,
            "/v1/chat/completions",
            "x",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_status_missing")
        provider_stub.wait()
    guard.assert_clean()


def test_provider_scripted_permitted_peer_close_is_declared() raises:
    # TC01: a script may declare an expected peer close with an exact bounded
    # cause and phase. The fixture verifies that declaration and records the
    # observed outcome; it no longer tolerates arbitrary write errors.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "permitted_close", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 300
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "body_stall"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _raw_send_then_close(provider_stub.port, "/v1/chat/completions")
        provider_stub.wait()
        assert_true(provider_stub.ok())
        assert_true(provider_stub.failure_case().find("_peer_close_") >= 0)
        assert_true(provider_stub.failure_case().find("_body_stall") >= 0)
    guard.assert_clean()


def test_provider_scripted_unexpected_peer_close_fails() raises:
    # TC01: an ordinary delayed/stalled script that never declared an expected
    # close must fail with a bounded, cause-specific reason instead of
    # swallowing the write error.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "unexpected_close",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.stall_after_head_ms = 300
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _raw_send_then_close(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(provider_stub.reason().find("unexpected_write_") >= 0)
        assert_true(provider_stub.reason().find("_body_stall") >= 0)
    guard.assert_clean()


def test_provider_scripted_wrong_phase_close_fails() raises:
    # TC01: a declaration whose phase does not match the observed phase is
    # rejected, so a close in the wrong phase can never pass as expected.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "wrong_phase", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 300
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "delayed_write"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _raw_send_then_close(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_true(provider_stub.reason().find("_body_stall") >= 0)
    guard.assert_clean()


def test_provider_scripted_injected_write_error_fails() raises:
    # TC01: an injected write error is never a peer close, so it must not be
    # accepted even when a peer close was declared.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "injected_error", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 200
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "body_stall"
    script.inject_write_error = "Timeout"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(
            provider_stub.reason().find(
                "unexpected_write_unrelated_error_body_stall"
            )
            >= 0
        )
    guard.assert_clean()


def test_provider_scripted_injected_invalid_descriptor_fails() raises:
    # TC01: an injected invalid-descriptor write error must also fail rather
    # than being accepted as a declared peer close.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "injected_descriptor",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.stall_after_head_ms = 200
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "body_stall"
    script.inject_write_error = "Bad file descriptor"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(
            provider_stub.reason().find(
                "unexpected_write_unrelated_error_body_stall"
            )
            >= 0
        )
    guard.assert_clean()


def _realerrno_from_reason(reason: String) raises -> Int:
    """Raw errno recorded in a bounded write-failure reason, or -1."""
    var marker = "realerrno"
    var at = reason.find(marker)
    if at < 0:
        return -1
    var digits = String(reason[byte = at + marker.byte_length() :])
    var end = digits.find("_")
    if end >= 0:
        digits = String(digits[byte=0:end])
    if digits.byte_length() == 0:
        return -1
    return Int(digits)


def test_provider_scripted_synthetic_write_timeout_is_not_peer_close() raises:
    # RP03: a narrowly scoped syscall-result seam mapped exactly to the flare
    # write API's EAGAIN/EWOULDBLOCK rendering. The synthetic failure exercises
    # the actual classification and serve rejection path, is labelled synthdecl
    # and can never be accepted as a peer close.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "synthetic_timeout",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.stall_after_head_ms = 200
    script.inject_write_errno = Int(ErrNo.EAGAIN.value)
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(not is_peer_close_cause("write_timeout"))
        assert_true(
            provider_stub.reason().find(
                "unexpected_write_write_timeout_body_stall_synthdecl"
            )
            >= 0
        )
    guard.assert_clean()


def test_provider_scripted_synthetic_invalid_descriptor_is_not_peer_close() raises:
    # RP03: the same seam mapped to the flare write API's EBADF rendering. The
    # invalid descriptor is classified as invalid_descriptor, labelled synthetic
    # and rejected even when a peer close was declared.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "synthetic_descriptor",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.stall_after_head_ms = 200
    script.inject_write_errno = Int(ErrNo.EBADF.value)
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "body_stall"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(
            provider_stub.reason().find(
                "unexpected_write_invalid_descriptor_body_stall_synthdecl"
            )
            >= 0
        )
    guard.assert_clean()


def test_provider_scripted_declared_peer_close_rejects_synthetic_timeout() raises:
    # RP03: declaring a real peer close does not waive a synthetic timeout. The
    # declared cause is compared against the observed class, so a non-peer-close
    # failure stays a failure.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "declared_vs_synthetic",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.stall_after_head_ms = 200
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "body_stall"
    script.inject_write_errno = Int(ErrNo.EAGAIN.value)
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_true(provider_stub.reason().find("write_timeout") >= 0)
    guard.assert_clean()


def test_provider_scripted_real_peer_close_records_raw_errno() raises:
    # RP03: the real (non-synthetic) write failure. A real peer close makes the
    # fixture's real send(2) fail; the fixture records the raw errno alongside
    # the classification, and the errno's class must equal the observed class.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "real_errno", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 300
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "body_stall"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _raw_send_then_close(provider_stub.port, "/v1/chat/completions")
        provider_stub.wait()
        assert_true(provider_stub.ok())
        var token = provider_stub.failure_case()
        assert_true(token.find("realerrno") >= 0)
        var errno = _realerrno_from_reason(token)
        assert_true(errno > 0)
        var observed = write_errno_class(errno)
        assert_true(observed == "broken_pipe" or observed == "peer_reset")
        assert_true(token.find("_peer_close_" + observed + "_") >= 0)
    guard.assert_clean()


def test_provider_scripted_declared_non_peer_cause_is_rejected() raises:
    # TC01: the declared expected cause is restricted to a real peer-close class,
    # so a write timeout can never be waived by declaring it as expected.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "declared_timeout",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.stall_after_head_ms = 200
    script.expect_peer_close = True
    script.expected_close_cause = "write_timeout"
    script.expected_close_phase = "body_stall"
    script.inject_write_error = "Timeout"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "declaration")
        assert_true(
            provider_stub.reason().find("invalid_expected_close_declaration")
            >= 0
        )
    guard.assert_clean()


def test_provider_scripted_invalid_phase_declaration_is_rejected() raises:
    # EC01: an unknown/empty expected-close phase is an invalid declaration and
    # cannot be satisfied by any real write step. It is rejected before any
    # response work even though the response write would have succeeded.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "invalid_phase",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "unknown_phase"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "declaration")
        assert_true(
            provider_stub.reason().find("invalid_expected_close_declaration")
            >= 0
        )
    guard.assert_clean()


def test_provider_scripted_missing_expected_close_fails() raises:
    # EC01: the script declares an expected peer close but the response write
    # succeeds, so the declared event never happened. A successful write is not
    # permission to accept a declared close that was not observed.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "missing_expected_close",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "delayed_write"
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(
            provider_stub.reason().find("missing_expected_close_delayed_write")
            >= 0
        )
    guard.assert_clean()


def test_provider_permitted_close_continues_script_sequence() raises:
    # EC01: a permitted peer close consumes that exchange only. The remaining
    # scripted exchange must still be served and counted, so a permitted close
    # can never terminate the whole sequence as successful with unused
    # exchanges.
    var scripts = List[ExchangeScript]()
    var closing = exchange_script(
        "permitted_then_next",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    closing.stall_after_head_ms = 300
    closing.expect_peer_close = True
    closing.expected_close_cause = "broken_pipe"
    closing.expected_close_phase = "body_stall"
    scripts.append(closing^)
    scripts.append(
        exchange_script(
            "after_permitted_close",
            "POST",
            "/v1/chat/completions",
            200,
            '{"choices":[]}',
        )
    )
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _raw_send_then_close(provider_stub.port, "/v1/chat/completions")
        var second = _raw_send_and_read(
            provider_stub.port, "/v1/chat/completions"
        )
        provider_stub.wait()
        assert_true(provider_stub.ok())
        assert_equal(provider_stub.request_count(), 2)
        assert_equal(provider_stub.connection_count(), 2)
        assert_true(provider_stub.failure_case().find("_peer_close_") >= 0)
        assert_true(second.find("choices") >= 0)
    guard.assert_clean()


def test_provider_stalled_call_is_parent_bounded() raises:
    # TC02: a real risky client call against a stalling peer runs under the
    # parent deadline and is stopped/reaped by the parent instead of hanging.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "bounded_stall", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 3000
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "max_local",
            provider_stub.port,
            5000,
            600,
            guard,
            BOUNDED_CORRELATION_BOUNDED_STALL,
        )
        assert_true(report.stopped)
        assert_true(not report.completed)
        assert_true(report.cleanup_proved)
        assert_true(report.elapsed_ms >= 500)
        assert_true(report.elapsed_ms < 3000)
        provider_stub.wait()
    guard.assert_clean()


def test_provider_never_returning_call_is_stopped_and_reaped() raises:
    # TC02: a deliberate never-returning control proves the parent can stop and
    # reap the call; this is the bounded-harness proof an elapsed assertion
    # after a synchronous call cannot provide.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "never_return", 0, 300, 400, guard, BOUNDED_CORRELATION_NEVER_RETURN
    )
    assert_true(report.stopped)
    assert_true(not report.completed)
    assert_true(report.cleanup_proved)
    assert_true(report.elapsed_ms >= 350)
    assert_true(report.elapsed_ms < 5000)
    guard.assert_clean()


def test_bounded_call_retained_cleanup_recovers_and_leaks_nothing() raises:
    # BC03: an unproved bounded-call cleanup must retain usable ownership in the
    # caller-held guard, recover the exact owned child on retry, and leave no
    # descriptor or child behind — including a following call whose pipe reuses
    # the descriptor number the recovery released.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var report = run_bounded_call(
        "never_return",
        0,
        300,
        400,
        guard,
        BOUNDED_CORRELATION_RETAINED_CLEANUP,
        "/v1/chat/completions",
        "",
        1,
        0,
    )
    assert_true(report.stopped)
    assert_true(not report.completed)
    assert_true(not report.cleanup_proved)
    assert_true(guard.retained() >= 1)
    assert_equal(guard.recover_all(), 0)
    guard.assert_clean()
    var follow = run_bounded_call(
        "never_return",
        0,
        300,
        400,
        guard,
        BOUNDED_CORRELATION_REUSED_DESCRIPTOR,
    )
    assert_true(follow.stopped)
    assert_true(follow.cleanup_proved)
    guard.assert_clean()
    assert_equal(open_fd_count_checked(), fd_before)
    assert_equal(guard.pending(), 0)


def test_bounded_call_rejects_nonzero_exit_after_valid_report() raises:
    # BC02 before/after control: the period-12 child-only mutation produced a
    # valid-looking report followed by exit 7 and the old consumer called it
    # completed. The unchanged parent consumer must reject the non-zero exit
    # after observing the natural exit, never kill the child and call it done.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_exit7",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_MUTANT_EXIT7,
    )
    assert_true(not report.completed)
    assert_true(not report.stopped)
    assert_equal(report.problem, "child_exit_7")
    assert_true(report.child_status.find("exited=7") >= 0)
    assert_true(report.cleanup_proved)
    guard.assert_clean()


def test_bounded_call_rejects_unterminated_report() raises:
    # BC02 before/after control: an unterminated report is a harness failure,
    # never a completed call.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_unterminated",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_MUTANT_UNTERMINATED,
    )
    assert_true(not report.completed)
    assert_equal(report.problem, "report_unterminated")
    assert_true(report.cleanup_proved)
    guard.assert_clean()


def test_bounded_call_rejects_duplicate_report() raises:
    # BC02 before/after control: a second report line is surplus through EOF and
    # can never be accepted, whatever its chunk alignment.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_duplicate",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_MUTANT_DUPLICATE,
    )
    assert_true(not report.completed)
    assert_equal(report.problem, "report_duplicate_report")
    assert_true(report.cleanup_proved)
    guard.assert_clean()


def test_bounded_call_rejects_overrunning_child_after_report() raises:
    # BC02/BC03 before/after control: the old consumer reported a valid-looking
    # completed call after killing a child that stayed alive past the budget.
    # The repaired consumer must stop and reap it and report an expiry, not
    # success.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_delayed",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_MUTANT_DELAYED,
    )
    assert_true(not report.completed)
    assert_true(report.stopped)
    assert_true(report.cleanup_proved)
    assert_true(report.elapsed_ms >= 400)
    assert_true(report.elapsed_ms < 3000)
    guard.assert_clean()


def test_bounded_report_grammar_rejects_invalid_fields() raises:
    # BC02: the shared parent consumer validates the declared call grammar. A
    # wrong correlation, an unknown/duplicate/missing field, a malformed token
    # or an incompatible outcome is rejected as a bounded problem, never as a
    # completed call for the declared kind.
    var good = "report kind=max_local correlation=7 outcome=ok status=200"
    var accepted = parse_bounded_report(good, "max_local", 7)
    assert_true(accepted.ok)
    assert_equal(accepted.status, 200)
    var failing_kind = parse_bounded_report(
        (
            "report kind=jev correlation=7 outcome=fail cause=transport"
            " reason=unknown_transport"
        ),
        "jev",
        7,
    )
    assert_true(failing_kind.domain_failure())
    assert_equal(failing_kind.cause, "transport")
    var cases = List[String]()
    cases.append(
        "not_a_report kind=max_local correlation=7 outcome=ok status=200"
    )
    cases.append("report kind=max_local correlation=7 outcome=ok")
    cases.append("report kind=max_local outcome=ok status=200")
    cases.append(
        "report kind=max_local correlation=7 outcome=ok status=200 bogus=1"
    )
    cases.append(
        "report kind=max_local correlation=7 outcome=ok status=200 status=200"
    )
    cases.append("report kind=jev correlation=7 outcome=ok status=200")
    cases.append("report kind=max_local correlation=8 outcome=ok status=200")
    cases.append("report kind=max_local correlation=7 outcome=maybe status=200")
    cases.append(
        "report kind=max_local correlation=7 outcome=fail cause=transport "
        "reason=unknown_transport status=200"
    )
    cases.append("report kind=max_local correlation=7 outcome=ok status=abc")
    cases.append("report kind=max_local correlation=7 outcome=ok status=999")
    cases.append(
        "report kind=max_local correlation=7 outcome=fail cause=transport"
    )
    cases.append("report x")
    var expected = List[String]()
    expected.append("report_prefix")
    expected.append("report_status_missing")
    expected.append("report_missing_field")
    expected.append("report_unknown_field_bogus")
    expected.append("report_duplicate_field_status")
    expected.append("report_kind_mismatch")
    expected.append("report_correlation_mismatch")
    expected.append("report_outcome_unknown_maybe")
    expected.append("report_incompatible_outcome")
    expected.append("report_non_numeric_status")
    expected.append("report_status_invalid")
    expected.append("report_cause_missing")
    expected.append("report_token_grammar")
    for index in range(len(cases)):
        var parsed = parse_bounded_report(cases[index], "max_local", 7)
        assert_true(not parsed.ok)
        assert_equal(parsed.problem, expected[index])


def test_bounded_call_rejects_report_past_the_byte_cap() raises:
    # BC02: a report line past the bounded cap is a cap-overflow harness
    # failure, never a completed call.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_huge",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_MUTANT_HUGE,
    )
    assert_true(not report.completed)
    assert_equal(report.problem, "ready_output_overflow")
    assert_true(report.cleanup_proved)
    guard.assert_clean()


def test_bounded_call_transient_wait_error_is_not_success() raises:
    # BC02/BC03: a transient child-exit wait error is a bounded harness failure
    # that stays retryable; it can never be reported as a completed call, and
    # the following cleanup still proves the exact owned child is collected.
    # The wait fault is a labelled test-only seam (never a real owned child
    # replaced by a synthetic identity).
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_valid",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_WAIT_ERROR,
        "/v1/chat/completions",
        "",
        0,
        1,
    )
    assert_true(not report.completed)
    assert_equal(report.problem, "child_wait_error")
    assert_true(report.cleanup_proved)
    assert_true(report.child_status.find("exited=0") >= 0)
    guard.assert_clean()


def test_bounded_call_rejects_early_eof_report() raises:
    # RP02: an early EOF with no report byte is a harness failure, never an
    # empty completed call, through the actual bounded consumer.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var report = run_bounded_call(
        "mutate_silent",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_EARLY_EOF,
    )
    assert_true(not report.completed)
    assert_equal(report.problem, "report_early_eof")
    assert_true(report.cleanup_proved)
    guard.assert_clean()
    assert_equal(open_fd_count_checked(), fd_before)


def test_bounded_call_rejects_signaled_child_after_valid_report() raises:
    # RP02: a valid report followed by a signaled child is a harness failure.
    # The parent must observe the signal, not accept the report or kill the
    # child and call it complete.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var report = run_bounded_call(
        "mutate_signaled",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_SIGNALED,
    )
    assert_true(not report.completed)
    assert_true(not report.stopped)
    assert_equal(report.problem, "child_signal_9")
    assert_true(report.child_status.find("signal=9") >= 0)
    assert_true(report.cleanup_proved)
    guard.assert_clean()
    assert_equal(open_fd_count_checked(), fd_before)


def test_bounded_call_rejects_invalid_utf8_report() raises:
    # RP02: an invalid UTF-8 byte in the report line is rejected by the bounded
    # decode, so a corrupted report can never be accepted as a completed call.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var report = run_bounded_call(
        "mutate_invalid_utf8",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_INVALID_UTF8,
    )
    assert_true(not report.completed)
    assert_equal(report.problem, "invalid_utf8")
    assert_true(report.cleanup_proved)
    guard.assert_clean()
    assert_equal(open_fd_count_checked(), fd_before)


def test_bounded_call_rejects_phase_isolated_late_exit() raises:
    # RP02: after the report pipe is closed with one complete report, a child
    # that outlives the budget must be isolated in the wait phase and stopped
    # and reaped, never reported as completed.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var report = run_bounded_call(
        "mutate_late_exit",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_LATE_EXIT,
    )
    assert_true(not report.completed)
    assert_true(report.stopped)
    assert_true(report.cleanup_proved)
    assert_true(report.elapsed_ms >= 400)
    assert_true(report.elapsed_ms < 3000)
    guard.assert_clean()
    assert_equal(open_fd_count_checked(), fd_before)


def test_bounded_call_retries_synthetic_eintr_without_error() raises:
    # RP02: a bounded test-only EINTR seam exercises the actual poll consumer's
    # retry branch. One interrupted poll must be retried, not reported as a read
    # error, and the complete report must still be accepted. The seam is
    # synthetic and disclosed as such; it changes no host signal state.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_valid",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_EINTR_RETRY,
        "/v1/chat/completions",
        "",
        0,
        0,
        1,
        0,
    )
    assert_true(report.completed)
    assert_equal(report.outcome, "ok")
    assert_equal(report.status, 200)
    assert_equal(report.problem, "")
    assert_true(report.cleanup_proved)
    guard.assert_clean()


def test_bounded_call_eintr_retry_is_bounded_by_deadline() raises:
    # RP02: an unbounded synthetic EINTR storm must terminate at the caller's
    # absolute deadline, never refresh the budget and never spin. The actual
    # consumer reports the expiry, so the parent stops and reaps the child.
    var guard = CleanupGuard()
    var report = run_bounded_call(
        "mutate_valid",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_EINTR_DEADLINE,
        "/v1/chat/completions",
        "",
        0,
        0,
        -1,
        0,
    )
    assert_true(not report.completed)
    assert_true(report.stopped)
    assert_true(report.cleanup_proved)
    assert_true(report.elapsed_ms >= 400)
    assert_true(report.elapsed_ms < 3000)
    guard.assert_clean()


def test_bounded_call_poll_error_is_bounded_failure() raises:
    # RP02: a real poll error (bounded test-only seam) is surfaced as
    # read_error by the actual consumer, and the exception path still proves
    # owned cleanup with no child or descriptor growth.
    var guard = CleanupGuard()
    var fd_before = open_fd_count_checked()
    var report = run_bounded_call(
        "mutate_valid",
        0,
        300,
        500,
        guard,
        BOUNDED_CORRELATION_POLL_ERROR,
        "/v1/chat/completions",
        "",
        0,
        0,
        0,
        1,
    )
    assert_true(not report.completed)
    assert_equal(report.problem, "read_error")
    assert_true(report.cleanup_proved)
    guard.assert_clean()
    assert_equal(guard.pending(), 0)
    assert_equal(open_fd_count_checked(), fd_before)


def test_maxlocal_wire_attempt_counts_are_exact() raises:
    # H008: a retryable non-2xx does not trigger a hidden retry. Each explicit
    # call makes exactly one counted wire attempt (request and connection).
    var scripts = List[ExchangeScript]()
    scripts.append(
        exchange_script("ml_500", "POST", "/v1/chat/completions", 500, "{}")
    )
    scripts.append(
        exchange_script(
            "ml_ok", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
        )
    )
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var config = _bounded_timeout_provider_config(provider_stub.port, 3000)
        var context = default_request_context()
        var body = build_query_rewrite_request_body(
            config, "eggs near me", context
        )
        var first = post_max_local_chat_completion(config, body)
        assert_true(first.failure)
        assert_equal(first.failure.value().kind, "http_status")
        var second = post_max_local_chat_completion(config, body)
        assert_true(not second.failure)
        assert_equal(second.response.value().status, 200)
        provider_stub.wait()
        assert_true(provider_stub.ok())
        assert_equal(provider_stub.request_count(), 2)
        assert_equal(provider_stub.connection_count(), 2)
    guard.assert_clean()


def test_maxlocal_wire_attempt_counts_for_non_retryable_status() raises:
    # H008: a non-2xx status that must not be retried is exactly one attempt.
    var scripts = List[ExchangeScript]()
    scripts.append(
        exchange_script("ml_400", "POST", "/v1/chat/completions", 400, "{}")
    )
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var config = _bounded_timeout_provider_config(provider_stub.port, 3000)
        var context = default_request_context()
        var body = build_query_rewrite_request_body(
            config, "eggs near me", context
        )
        var outcome = post_max_local_chat_completion(config, body)
        assert_true(outcome.failure)
        assert_equal(outcome.failure.value().kind, "http_status")
        provider_stub.wait()
        assert_true(provider_stub.ok())
        assert_equal(provider_stub.request_count(), 1)
        assert_equal(provider_stub.connection_count(), 1)
    guard.assert_clean()


# ── H009 query-analysis JSON boundary characterization ──────────────────────


def _analysis_envelope(content: String) raises -> Value:
    return loads(
        '{"choices":[{"message":{"content":' + json_escape(content) + "}}]}"
    )


def _analysis_content(fields: String) -> String:
    return "{" + fields + "}"


comptime ANALYSIS_TAIL = (
    '"normalization_signals":[],"ranking_hints":[],'
    '"extracted_filters":{"local_intent":true,"fulfillment":"unspecified",'
    '"time_window":"unspecified"}'
)


def test_query_analysis_boundary_characterizes_duplicate_and_null_fields() raises:
    # H009: pin current query-analysis boundary behavior. A duplicated field is
    # accepted first-wins; a null string field and a non-array field are
    # rejected as provider_schema_invalid.
    var duplicate = _analysis_envelope(
        _analysis_content(
            '"original_text":"a","original_text":"b","normalized_text":"a",'
            '"rewritten_text":"a","query_terms":["a"],'
            + ANALYSIS_TAIL
        )
    )
    var analysis = parse_query_analysis_from_chat_completion(duplicate)
    assert_equal(analysis.original_text, "a")
    assert_equal(len(analysis.query_terms), 1)
    var null_text = _analysis_envelope(
        _analysis_content(
            '"original_text":null,"normalized_text":"a","rewritten_text":"a",'
            '"query_terms":["a"],'
            + ANALYSIS_TAIL
        )
    )
    var message = ""
    try:
        _ = parse_query_analysis_from_chat_completion(null_text)
    except e:
        message = String(e)
    assert_true(message.find("provider_schema_invalid") >= 0)
    var numeric_terms = _analysis_envelope(
        _analysis_content(
            '"original_text":"a","normalized_text":"a","rewritten_text":"a",'
            '"query_terms":7,'
            + ANALYSIS_TAIL
        )
    )
    var terms_message = ""
    try:
        _ = parse_query_analysis_from_chat_completion(numeric_terms)
    except e:
        terms_message = String(e)
    assert_true(terms_message.find("provider_schema_invalid") >= 0)


def _raw_bytes(text: String) -> List[UInt8]:
    var raw = List[UInt8]()
    for byte in text.as_bytes():
        raw.append(UInt8(Int(byte)))
    return raw^


def _repeat_text(mark: String, count: Int) -> String:
    var out = List[UInt8]()
    var mark_bytes = mark.as_bytes()
    for _ in range(count):
        for index in range(len(mark_bytes)):
            out.append(UInt8(Int(mark_bytes[index])))
    return String(unsafe_from_utf8=Span(ptr=out.unsafe_ptr(), length=len(out)))


# OB01: the exact raw response grammar. A status-looking value inside a header
# is never the status; a different field name is preserved as unknown; junk,
# duplicate, conflicting, negative, overflowing or unsupported framing is an
# explicit bounded problem rather than a silently absent field.


def test_raw_accounting_preserves_unknown_length_like_field() raises:
    var accounting = account_raw_bytes(
        _raw_bytes("HTTP/1.1 200 OK\r\nX-Content-Length: 3\r\n\r\nabc"),
        "abc",
    )
    assert_equal(accounting.problem, "")
    assert_equal(accounting.status, 200)
    assert_equal(accounting.body_bytes, 3)
    assert_equal(accounting.declared_bytes, -1)
    assert_equal(accounting.length_match, "unknown")
    assert_equal(accounting.surplus_bytes, 0)


def test_raw_accounting_rejects_junk_content_length() raises:
    var accounting = account_raw_bytes(
        _raw_bytes("HTTP/1.1 200 OK\r\nContent-Length: 3junk\r\n\r\nabc"),
        "abc",
    )
    assert_equal(accounting.problem, "raw_content_length_malformed")


def test_raw_accounting_rejects_identical_duplicate_length() raises:
    var accounting = account_raw_bytes(
        _raw_bytes(
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n"
            "Content-Length: 3\r\n\r\nabc"
        ),
        "abc",
    )
    assert_equal(accounting.problem, "raw_content_length_duplicate")


def test_raw_accounting_rejects_conflicting_duplicate_length() raises:
    var accounting = account_raw_bytes(
        _raw_bytes(
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n"
            "Content-Length: 9\r\n\r\nabc"
        ),
        "abc",
    )
    assert_equal(accounting.problem, "raw_content_length_duplicate")


def test_raw_accounting_rejects_garbage_status_with_header_status_value() raises:
    # A status-looking string in a header after a garbage first line must never
    # be read as the response status.
    var accounting = account_raw_bytes(
        _raw_bytes(
            "garbage\r\nx-note: HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc"
        ),
        "abc",
    )
    assert_equal(accounting.problem, "raw_status_missing")
    assert_equal(accounting.status, 0)


def test_raw_accounting_rejects_unsupported_transfer_encoding() raises:
    var accounting = account_raw_bytes(
        _raw_bytes("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\nabc"),
        "abc",
    )
    assert_equal(accounting.problem, "raw_transfer_encoding_unsupported")


def test_raw_accounting_rejects_negative_content_length() raises:
    var accounting = account_raw_bytes(
        _raw_bytes("HTTP/1.1 200 OK\r\nContent-Length: -3\r\n\r\nabc"),
        "abc",
    )
    assert_equal(accounting.problem, "raw_content_length_malformed")


def test_raw_accounting_rejects_overflow_content_length() raises:
    var accounting = account_raw_bytes(
        _raw_bytes(
            "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\nabc"
        ),
        "abc",
    )
    assert_equal(accounting.problem, "raw_content_length_overflow")


def test_raw_accounting_rejects_malformed_header_line() raises:
    var accounting = account_raw_bytes(
        _raw_bytes("HTTP/1.1 200 OK\r\nbad header line\r\n\r\nabc"), "abc"
    )
    assert_equal(accounting.problem, "raw_header_malformed")


def test_raw_accounting_rejects_out_of_range_status() raises:
    # OB01: only a valid three-digit HTTP status (100..599) is accepted.
    var low = account_raw_bytes(
        _raw_bytes("HTTP/1.1 000 X\r\ncontent-length: 3\r\n\r\nabc"), "abc"
    )
    assert_equal(low.problem, "raw_status_malformed")
    var high = account_raw_bytes(
        _raw_bytes("HTTP/1.1 999 X\r\ncontent-length: 3\r\n\r\nabc"), "abc"
    )
    assert_equal(high.problem, "raw_status_malformed")


def test_raw_accounting_accepts_identity_transfer_encoding() raises:
    var accounting = account_raw_bytes(
        _raw_bytes("HTTP/1.1 200 OK\r\ntransfer-encoding: identity\r\n\r\nabc"),
        "abc",
    )
    assert_equal(accounting.problem, "")
    assert_equal(accounting.status, 200)
    assert_equal(accounting.declared_bytes, -1)
    assert_equal(accounting.length_match, "unknown")


def test_raw_accounting_rejects_transfer_with_length_conflict() raises:
    var accounting = account_raw_bytes(
        _raw_bytes(
            "HTTP/1.1 200 OK\r\ntransfer-encoding: identity\r\n"
            "content-length: 3\r\n\r\nabc"
        ),
        "abc",
    )
    assert_equal(accounting.problem, "raw_framing_conflict")


def test_raw_accounting_reports_buffered_surplus() raises:
    # OB02: bytes already buffered beyond the declared body are reported
    # explicitly instead of being silently folded into the declared length.
    var accounting = account_raw_bytes(
        _raw_bytes("HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\nabcde"),
        "abc",
    )
    assert_equal(accounting.problem, "")
    assert_equal(accounting.body_bytes, 5)
    assert_equal(accounting.declared_bytes, 3)
    assert_equal(accounting.length_match, "no")
    assert_equal(accounting.surplus_bytes, 2)


# OB02 acquisition controls through the actual incremental read path.


def test_provider_raw_head_body_accounts_buffered_surplus() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "buffered_surplus", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-length: 3\r\nconnection: close\r\n\r\nabcde"
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_SURPLUS,
            "/v1/chat/completions",
            "abc",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, 5)
        assert_equal(report.declared_bytes, 3)
        assert_equal(report.length_match, "no")
        assert_equal(report.surplus_bytes, 2)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_rejects_declared_over_cap() raises:
    # OB02: a declared length beyond the body cap is an explicit overflow, never
    # an accepted observation with a silently truncated prefix.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "declared_over_cap", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-length: 99999999\r\n"
        "connection: close\r\n\r\nabc"
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_OVER_CAP,
            "/v1/chat/completions",
            "abc",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_body_overflow")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_rejects_duplicate_length() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "duplicate_length", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-length: 3\r\ncontent-length: 3\r\n"
        "connection: close\r\n\r\nabc"
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_DUP_LENGTH,
            "/v1/chat/completions",
            "abc",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_content_length_duplicate")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_no_length_completes_at_eof() raises:
    # OB02: a response without a declared length completes at EOF inside the
    # cap, with an explicitly unknown length rather than an invented one.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "no_length", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nNOLENGTHBODY"
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_NO_LENGTH,
            "/v1/chat/completions",
            "NOLENGTHBODY",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, "NOLENGTHBODY".byte_length())
        assert_equal(report.body_match, "yes")
        assert_equal(report.declared_bytes, -1)
        assert_equal(report.length_match, "unknown")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_split_header_terminator_is_preserved() raises:
    # OB02: the real incremental acquisition path is driven with one-byte reads,
    # so the CRLFCRLF terminator is split across reads. Concatenating loops
    # before a pure parser call is not fragmentation proof, so the seam caps the
    # actual read.
    var scripts = List[ExchangeScript]()
    scripts.append(
        exchange_script(
            "split_terminator", "POST", "/v1/chat/completions", 200, "BODYMARK"
        )
    )
    var plan = List[Int]()
    plan.append(1)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_SPLIT_TERMINATOR,
            "/v1/chat/completions",
            "BODYMARK",
            raw_chunk_plan=plan,
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, 8)
        assert_equal(report.body_match, "yes")
        assert_equal(report.declared_bytes, 8)
        assert_equal(report.length_match, "yes")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_split_multibyte_body_is_preserved() raises:
    # OB02: a one-byte read seam splits the three-byte UTF-8 character across
    # reads; the byte accumulation must still preserve it whole.
    var scripts = List[ExchangeScript]()
    scripts.append(
        exchange_script(
            "split_multibyte",
            "POST",
            "/v1/chat/completions",
            200,
            '{"mark":"a☃b"}',
        )
    )
    var plan = List[Int]()
    plan.append(1)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_SPLIT_BODY,
            "/v1/chat/completions",
            "a☃b",
            raw_chunk_plan=plan,
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, '{"mark":"a☃b"}'.byte_length())
        assert_equal(report.body_match, "yes")
        assert_equal(report.length_match, "yes")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_near_cap_coalesced_body_is_not_head_overflow() raises:
    # OB02: the header cap counts bytes through the terminator only. A valid
    # near-cap header whose final 1000-byte read also carries coalesced body
    # bytes must not be reported as a header overflow.
    var pad = _repeat_text("a", 65459)
    var body = "ENDMARK" + _repeat_text("y", 593)
    var raw = (
        "HTTP/1.1 200 OK\r\nx-pad: "
        + pad
        + "\r\ncontent-length: 600\r\nconnection: close\r\n\r\n"
        + body
    )
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "near_cap", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = raw
    scripts.append(script^)
    var plan = List[Int]()
    plan.append(1000)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_NEAR_CAP,
            "/v1/chat/completions",
            "ENDMARK",
            raw_chunk_plan=plan,
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, 600)
        assert_equal(report.body_match, "yes")
        assert_equal(report.declared_bytes, 600)
        assert_equal(report.length_match, "yes")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_reports_malformed_length_grammar() raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "malformed_length", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-length: 3junk\r\nconnection:"
        " close\r\n\r\nabc"
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            5000,
            5000,
            guard,
            BOUNDED_CORRELATION_OB_MALFORMED_HEAD,
            "/v1/chat/completions",
            "abc",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_content_length_malformed")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


# D44/IL01: the inclusive 1,048,576-byte raw-body cap, proven through the
# actual incremental acquisition path for both a declared Content-Length and an
# EOF-delimited (no-length) response. Exact cap is inclusive; a real extra byte
# fails overflow; a stalled peer fails the existing parent deadline (timeout),
# never an invented overflow.

comptime RAW_BODY_CAP_TEST = 1048576


def _cap_body(count: Int) -> String:
    return _repeat_text("a", count)


def test_provider_raw_head_body_declared_cap_minus_one_succeeds() raises:
    var body = _cap_body(RAW_BODY_CAP_TEST - 1)
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "declared_cap_m1", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-length: "
        + String(RAW_BODY_CAP_TEST - 1)
        + "\r\nconnection: close\r\n\r\n"
        + body
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            10000,
            10000,
            guard,
            BOUNDED_CORRELATION_OB_CAP_DECLARED_MINUS,
            "/v1/chat/completions",
            "aaa",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, RAW_BODY_CAP_TEST - 1)
        assert_equal(report.declared_bytes, RAW_BODY_CAP_TEST - 1)
        assert_equal(report.length_match, "yes")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_declared_cap_exact_succeeds() raises:
    # D44/IL01: a declared body of exactly the cap is inclusive and completes
    # without a sentinel read, because the declared length already bounds it.
    var body = _cap_body(RAW_BODY_CAP_TEST)
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "declared_cap_exact", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-length: "
        + String(RAW_BODY_CAP_TEST)
        + "\r\nconnection: close\r\n\r\n"
        + body
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            10000,
            10000,
            guard,
            BOUNDED_CORRELATION_OB_CAP_DECLARED_EXACT,
            "/v1/chat/completions",
            "aaa",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, RAW_BODY_CAP_TEST)
        assert_equal(report.declared_bytes, RAW_BODY_CAP_TEST)
        assert_equal(report.length_match, "yes")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_declared_cap_plus_one_is_over_cap() raises:
    # D44/IL01: a declared length above the cap is rejected at the head grammar
    # (declared-length rejection), distinctly from an EOF acquisition overflow.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "declared_cap_p1", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = (
        "HTTP/1.1 200 OK\r\ncontent-length: "
        + String(RAW_BODY_CAP_TEST + 1)
        + "\r\nconnection: close\r\n\r\nabc"
    )
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            10000,
            10000,
            guard,
            BOUNDED_CORRELATION_OB_CAP_DECLARED_PLUS,
            "/v1/chat/completions",
            "abc",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_body_overflow")
        assert_equal(report.reason, "raw_body_overflow")
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_no_length_cap_minus_one_succeeds() raises:
    var body = _cap_body(RAW_BODY_CAP_TEST - 1)
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "nolen_cap_m1", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n" + body
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            10000,
            10000,
            guard,
            BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_MINUS,
            "/v1/chat/completions",
            "aaa",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, RAW_BODY_CAP_TEST - 1)
        assert_equal(report.declared_bytes, -1)
        assert_equal(report.length_match, "unknown")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_no_length_exact_cap_succeeds_at_eof() raises:
    # D44/IL01 regression: the exact inclusive cap is a success when the peer
    # closed at the cap. The one-byte sentinel observes EOF and is never
    # appended, so body_bytes stays at the cap.
    var body = _cap_body(RAW_BODY_CAP_TEST)
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "nolen_cap_exact", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n" + body
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            10000,
            10000,
            guard,
            BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_EXACT,
            "/v1/chat/completions",
            "aaa",
        )
        assert_true(report.ok())
        assert_equal(report.status, 200)
        assert_equal(report.body_bytes, RAW_BODY_CAP_TEST)
        assert_equal(report.declared_bytes, -1)
        assert_equal(report.length_match, "unknown")
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_no_length_cap_plus_one_overflows() raises:
    # D44/IL01: a real extra byte beyond the cap fails overflow through the
    # sentinel read; the sentinel is never appended, so body_bytes stays at the
    # inclusive maximum rather than exceeding it.
    var body = _cap_body(RAW_BODY_CAP_TEST + 1)
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "nolen_cap_p1", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n" + body
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            10000,
            10000,
            guard,
            BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_PLUS,
            "/v1/chat/completions",
            "aaa",
        )
        assert_true(report.completed)
        assert_true(report.domain_failure())
        assert_equal(report.cause, "raw_body_overflow")
        assert_equal(report.reason, "body_overflow")
        assert_equal(report.body_bytes, RAW_BODY_CAP_TEST)
        assert_equal(report.surplus_bytes, 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
    guard.assert_clean()


def test_provider_raw_head_body_no_length_exact_cap_stall_is_timeout() raises:
    # D44/IL01: a peer that delivers exactly the cap and then stalls must be
    # reported by the existing parent deadline as a stopped (timeout) call,
    # never as an invented raw_body_overflow. The fixture keeps the connection
    # open, so only the parent deadline can end the call.
    var body = _cap_body(RAW_BODY_CAP_TEST)
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "nolen_cap_stall", "POST", "/v1/chat/completions", 200, ""
    )
    script.raw_response = "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n" + body
    script.close_connection = False
    scripts.append(script^)
    scripts.append(
        exchange_script(
            "nolen_cap_stall_unused", "POST", "/v1/chat/completions", 200, ""
        )
    )
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var report = run_bounded_call(
            "raw_head_body",
            provider_stub.port,
            10000,
            1500,
            guard,
            BOUNDED_CORRELATION_OB_CAP_NO_LENGTH_STALL,
            "/v1/chat/completions",
            "aaa",
        )
        assert_true(report.stopped)
        assert_true(not report.completed)
        assert_true(report.cleanup_proved)
        assert_equal(report.problem, "")
        assert_equal(report.cause, "")
    guard.assert_clean()


# OB03: a synthetic write-error seam is never a real peer close.


def _assert_synthetic_errno_rejected(errno: Int, declared: Bool) raises:
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "synthetic_errno", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 200
    if declared:
        script.expect_peer_close = True
        script.expected_close_cause = "broken_pipe"
        script.expected_close_phase = "body_stall"
    script.inject_write_errno = errno
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(provider_stub.reason().find("unexpected_write_") >= 0)
        assert_true(provider_stub.reason().find("synthdecl") >= 0)
    guard.assert_clean()


def test_provider_scripted_epipe_with_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.EPIPE.value), True)


def test_provider_scripted_epipe_without_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.EPIPE.value), False)


def test_provider_scripted_econnreset_with_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.ECONNRESET.value), True)


def test_provider_scripted_econnreset_without_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.ECONNRESET.value), False)


def test_provider_scripted_eagain_with_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.EAGAIN.value), True)


def test_provider_scripted_eagain_without_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.EAGAIN.value), False)


def test_provider_scripted_ebadf_with_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.EBADF.value), True)


def test_provider_scripted_ebadf_without_declaration_is_not_peer_close() raises:
    _assert_synthetic_errno_rejected(Int(ErrNo.EBADF.value), False)


def _assert_synthetic_errno_delayed_write_rejected(errno: Int) raises:
    # OB03: the same provenance rule is exercised on the non-stall delayed_write
    # write step, not only the body_stall step.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "synthetic_delayed",
        "POST",
        "/v1/chat/completions",
        200,
        '{"choices":[]}',
    )
    script.expect_peer_close = True
    script.expected_close_cause = "broken_pipe"
    script.expected_close_phase = "delayed_write"
    script.inject_write_errno = errno
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        _ = _raw_send_and_read(provider_stub.port, "/v1/chat/completions")
        provider_stub.reap()
        assert_true(not provider_stub.ok())
        assert_equal(provider_stub.phase(), "peer_close")
        assert_true(provider_stub.reason().find("unexpected_write_") >= 0)
        assert_true(provider_stub.reason().find("_delayed_write_") >= 0)
        assert_true(provider_stub.reason().find("synthdecl") >= 0)
    guard.assert_clean()


def test_provider_scripted_epipe_delayed_write_is_not_peer_close() raises:
    _assert_synthetic_errno_delayed_write_rejected(Int(ErrNo.EPIPE.value))


def test_provider_scripted_econnreset_delayed_write_is_not_peer_close() raises:
    _assert_synthetic_errno_delayed_write_rejected(Int(ErrNo.ECONNRESET.value))


def test_provider_scripted_eagain_delayed_write_is_not_peer_close() raises:
    _assert_synthetic_errno_delayed_write_rejected(Int(ErrNo.EAGAIN.value))


def test_provider_scripted_ebadf_delayed_write_is_not_peer_close() raises:
    _assert_synthetic_errno_delayed_write_rejected(Int(ErrNo.EBADF.value))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
