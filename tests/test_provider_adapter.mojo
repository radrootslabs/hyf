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
from parent_lifecycle import CleanupGuard, now_ms
from max_local_process_helper import (
    reserve_loopback_port,
    spawn_max_local_scripted,
    spawn_max_local_stub,
)
from bounded_call_helper import BoundedCallReport, run_bounded_call
from strict_fixture import ExchangeScript, exchange_script

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


def test_provider_connect_timeout_is_bounded_and_specific() raises:
    # H007: a refused connection is a bounded, cause-specific transport failure,
    # not a hang. No provider client policy is changed here.
    var guard = CleanupGuard()
    var dead_port = reserve_loopback_port()
    var config = _bounded_timeout_provider_config(dead_port, 300)
    var context = default_request_context()
    var body = build_query_rewrite_request_body(config, "eggs near me", context)
    var start = now_ms()
    var outcome = post_max_local_chat_completion(config, body)
    var elapsed = now_ms() - start
    assert_true(outcome.failure)
    assert_true(not outcome.response)
    assert_equal(outcome.failure.value().kind, "transport")
    # Current characterized gap: a fast refused connection is not distinguished
    # from an unknown transport error, because the elapsed time is below the
    # declared request budget.
    assert_equal(outcome.failure.value().reason, "unknown_transport")
    assert_true(elapsed < 5000)
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
        var config = _bounded_timeout_provider_config(
            provider_stub.port, timeout_ms
        )
        var context = default_request_context()
        var body = build_query_rewrite_request_body(
            config, "eggs near me", context
        )
        var start = now_ms()
        var outcome = post_max_local_chat_completion(config, body)
        var elapsed = now_ms() - start
        assert_true(not outcome.failure)
        assert_true(outcome.response)
        assert_equal(outcome.response.value().status, 200)
        assert_true(elapsed >= 1200)
        assert_true(elapsed < 5000)
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
        var config = _bounded_timeout_provider_config(
            provider_stub.port, timeout_ms
        )
        var context = default_request_context()
        var body = build_query_rewrite_request_body(
            config, "eggs near me", context
        )
        var start = now_ms()
        var outcome = post_max_local_chat_completion(config, body)
        var elapsed = now_ms() - start
        assert_true(not outcome.failure)
        assert_true(outcome.response)
        assert_equal(outcome.response.value().status, 200)
        assert_true(elapsed >= 1200)
        assert_true(elapsed < 5000)
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
            "max_local", provider_stub.port, 5000, 5000, guard
        )
        assert_true(report.completed)
        assert_true(not report.stopped)
        assert_true(report.cleanup_proved)
        assert_true(report.report.find("ok max_local 200") >= 0)
        provider_stub.wait()
        assert_true(provider_stub.ok())
        assert_equal(provider_stub.request_count(), 1)
        assert_equal(provider_stub.connection_count(), 1)
    guard.assert_clean()


def test_provider_stall_sends_headers_before_body() raises:
    # TC02: prove the fixture delivered the response head before the bounded
    # body stall, so the stall control characterizes a body-read stall rather
    # than an unrelated connect/refusal condition.
    var scripts = List[ExchangeScript]()
    var script = exchange_script(
        "head_then_stall", "POST", "/v1/chat/completions", 200, '{"choices":[]}'
    )
    script.stall_after_head_ms = 800
    scripts.append(script^)
    var guard = CleanupGuard()
    with spawn_max_local_scripted(0, scripts^, guard) as provider_stub:
        var client = TcpStream.connect(
            SocketAddr.localhost(UInt16(provider_stub.port))
        )
        var start = now_ms()
        client.write_all(
            Span[UInt8, _](_raw_request_text("/v1/chat/completions").as_bytes())
        )
        var head = String("")
        var buffer = InlineArray[Byte, 1024](fill=0)
        while head.find("\r\n\r\n") < 0:
            var n = client.read(buffer.unsafe_ptr(), 1024)
            assert_true(n > 0)
            head += String(
                unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n))
            )
        var head_ms = now_ms() - start
        var body = String("")
        while True:
            var n2 = client.read(buffer.unsafe_ptr(), 1024)
            if n2 <= 0:
                break
            body += String(
                unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n2))
            )
        var total_ms = now_ms() - start
        client.close()
        assert_true(head_ms < 400)
        assert_true(total_ms >= 700)
        assert_true(body.find("choices") >= 0)
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
    # TC01: an unrelated injected handler error (here a write timeout) must not
    # be accepted even when a peer close was declared, because the bounded
    # observed cause differs from the declared cause.
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
                "unexpected_write_write_timeout_body_stall"
            )
            >= 0
        )
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
            "max_local", provider_stub.port, 5000, 600, guard
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
    var report = run_bounded_call("never_return", 0, 300, 400, guard)
    assert_true(report.stopped)
    assert_true(not report.completed)
    assert_true(report.cleanup_proved)
    assert_true(report.elapsed_ms >= 350)
    assert_true(report.elapsed_ms < 5000)
    guard.assert_clean()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
