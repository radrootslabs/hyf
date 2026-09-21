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
from max_local_process_helper import (
    reserve_loopback_port,
    spawn_max_local_stub,
)


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
    var provider_stub = spawn_max_local_stub(
        0, "query_rewrite_malformed_http", 1
    )
    var provider_port = provider_stub.port
    var outcome = post_max_local_chat_completion(
        _provider_config_for_port(provider_port), loads("{}")
    )

    assert_true(outcome.failure)
    assert_true(not outcome.response)
    assert_equal(outcome.failure.value().kind, "transport")
    assert_equal(outcome.failure.value().reason, "unknown_transport")

    provider_stub.wait()


def test_max_local_transport_boundary_reports_unknown_health_transport() raises:
    var provider_stub = spawn_max_local_stub(0, "health_malformed_http", 1)
    var provider_port = provider_stub.port
    var outcome = get_max_local_health(_provider_config_for_port(provider_port))

    assert_true(outcome.failure)
    assert_true(not outcome.response)
    assert_equal(outcome.failure.value().kind, "transport")
    assert_equal(outcome.failure.value().reason, "unknown_transport")

    provider_stub.wait()


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
