from std.collections import List
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
    parse_bounded_report,
    run_bounded_call,
)
from strict_fixture import ExchangeScript, exchange_script

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
