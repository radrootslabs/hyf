import std.os
from std.os.path import exists
from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite
from safe_tempdir import SafeTempDir

from json import Value
from fixture_assertions import (
    assert_matches_scenario_response,
    load_scenario_request_json,
    status_request_with_invalid_version_json,
)
from max_local_process_helper import (
    reserve_loopback_port,
    spawn_max_local_stub,
)
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
    run_hyf_stdio,
    run_stdio_entrypoint,
)


comptime _EXPECTED_INTERNAL_ERROR_MESSAGE = (
    "internal hyf daemon error; inspect local diagnostics"
)
comptime _HYF_DIAGNOSTICS_DIR_ENV = "HYF_DIAGNOSTICS_DIR"


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _array_contains_string(value: Value, expected: String) raises -> Bool:
    for item in value.array_items():
        if item.is_string() and item.string_value() == expected:
            return True
    return False


def _assert_provider_runtime_fallback_meta(
    response: Value, expected_reason: String
) raises:
    assert_equal(
        response["meta"]["fallback_kind"].string_value(),
        "provider_runtime",
    )
    assert_equal(
        response["meta"]["fallback_reason"].string_value(),
        expected_reason,
    )
    assert_true(
        _business_fallback_reason_family(expected_reason) != "undeclared"
    )
    assert_true(expected_reason != "non_2xx")


def _assert_no_top_level_fallback_meta(response: Value) raises:
    assert_true(not _has_key(response["meta"], "fallback_kind"))
    assert_true(not _has_key(response["meta"], "fallback_reason"))


def _business_fallback_reason_family(reason: String) -> String:
    if reason == "timeout":
        return "provider_io"
    if reason == "connection_failed":
        return "provider_io"
    if reason == "invalid_url":
        return "provider_io"
    if reason == "provider_non_2xx":
        return "provider_io"
    if reason == "provider_error_payload":
        return "provider_io"
    if reason == "provider_invalid_json":
        return "provider_io"
    if reason == "provider_schema_invalid":
        return "provider_io"
    if reason == "provider_empty_choices":
        return "provider_io"
    if reason == "provider_missing_content":
        return "provider_io"
    if reason == "provider_error":
        return "provider_io"
    if reason == "invalid_config":
        return "runtime_config"
    if reason == "disabled_by_runtime_config":
        return "runtime_config"
    if reason == "provider_unconfigured":
        return "runtime_config"
    if reason == "unsupported_capability":
        return "capability_routing"
    return "undeclared"


def _assert_declared_business_fallback_reason(
    reason: String, expected_family: String
) raises:
    assert_equal(_business_fallback_reason_family(reason), expected_family)
    assert_true(reason != "non_2xx")


def _max_local_runtime_config_toml_with_urls(
    base_url: String, health_url: String, request_timeout_ms: Int
) -> String:
    return (
        '[service]\ntransport = "stdio"\n\n[runtime]\ndefault_execution_mode ='
        ' "deterministic"\nallow_assisted = true\n\n[assisted]\nprovider ='
        ' "max_local"\n\n[assisted.max_local]\nenabled = true\nbase_url = "'
        + base_url
        + '"\n'
        + 'health_url = "'
        + health_url
        + '"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = "
        + String(request_timeout_ms)
        + "\n"
    )


def _unavailable_max_local_runtime_config_toml() raises -> String:
    var provider_port = reserve_loopback_port()
    return _max_local_runtime_config_toml_with_urls(
        "http://127.0.0.1:" + String(provider_port) + "/v1",
        "http://127.0.0.1:" + String(provider_port) + "/health",
        250,
    )


def _query_rewrite_assisted_request_json(request_id: String) -> String:
    return _query_rewrite_assisted_request_json_with_deadline(request_id, 2500)


def _query_rewrite_assisted_request_json_with_deadline(
    request_id: String, deadline_ms: Int
) -> String:
    return (
        '{"version":1,"request_id":"'
        + request_id
        + '","trace_id":"'
        + request_id
        + '","capability":"query_rewrite","context":{"execution_mode_preference":"assisted","return_provenance":true,"deadline_ms":'
        + String(deadline_ms)
        + '},"input":{"query":"apples near me with weekend pickup"}}'
    )


def _query_rewrite_assisted_request_json_without_provenance(
    request_id: String,
) -> String:
    return (
        '{"version":1,"request_id":"'
        + request_id
        + '","trace_id":"'
        + request_id
        + '","capability":"query_rewrite","context":{"execution_mode_preference":"assisted","return_provenance":false,"deadline_ms":2500},"input":{"query":"apples'
        ' near me with weekend pickup"}}'
    )


def _semantic_rank_assisted_request_json(request_id: String) -> String:
    return (
        '{"version":1,"request_id":"'
        + request_id
        + '","trace_id":"'
        + request_id
        + '","capability":"semantic_rank","context":{"execution_mode_preference":"assisted","return_provenance":true},"input":{"query":"apples'
        " near me with weekend"
        ' pickup","candidates":[{"id":"listing_local_1","title":"Organic'
        ' apples","farm":"Local'
        ' Orchard","delivery":"pickup","distance_km":4.1,"freshness_minutes":3},{"id":"listing_regional_1","title":"Honeycrisp'
        ' apples","farm":"Regional'
        ' Orchard","delivery":"delivery","distance_km":28.0,"freshness_minutes":25}]}}'
    )


def _assert_query_rewrite_provider_fallback_with_requests(
    mode: String,
    expected_reason: String,
    request_timeout_ms: Int,
    requests: Int,
) raises:
    _assert_query_rewrite_provider_fallback_with_deadline(
        mode, expected_reason, request_timeout_ms, 2500, requests
    )


def _assert_query_rewrite_provider_fallback_with_deadline(
    mode: String,
    expected_reason: String,
    request_timeout_ms: Int,
    deadline_ms: Int,
    requests: Int,
) raises:
    with SafeTempDir() as temp_dir:
        var provider_stub = spawn_max_local_stub(0, mode, requests)
        var provider_port = provider_stub.port
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _max_local_runtime_config_toml_with_urls(
                "http://127.0.0.1:" + String(provider_port) + "/v1",
                "http://127.0.0.1:" + String(provider_port) + "/health",
                request_timeout_ms,
            )
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    _query_rewrite_assisted_request_json_with_deadline(
                        "rewrite-assisted-" + mode, deadline_ms
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["meta"]["execution_mode"].string_value(),
                    "deterministic",
                )
                assert_equal(
                    response["meta"]["backend"].string_value(),
                    "heuristic",
                )
                assert_true(not _has_key(response["meta"], "provider"))
                _assert_provider_runtime_fallback_meta(
                    response, expected_reason
                )
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "fallback_kind"
                    ].string_value(),
                    "provider_runtime",
                )
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "reason"
                    ].string_value(),
                    expected_reason,
                )
                assert_equal(
                    response["output"]["rewritten_text"].string_value(),
                    "apples",
                )

        provider_stub.wait()


def _assert_query_rewrite_provider_fallback(
    mode: String, expected_reason: String, request_timeout_ms: Int
) raises:
    _assert_query_rewrite_provider_fallback_with_requests(
        mode, expected_reason, request_timeout_ms, 2
    )


def _assert_query_rewrite_runtime_config_fallback(
    config_text: String, expected_reason: String, request_id: String
) raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(config_text)
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    _query_rewrite_assisted_request_json(request_id),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["meta"]["execution_mode"].string_value(),
                    "deterministic",
                )
                assert_equal(
                    response["meta"]["backend"].string_value(),
                    "heuristic",
                )
                assert_true(not _has_key(response["meta"], "provider"))
                _assert_provider_runtime_fallback_meta(
                    response, expected_reason
                )
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "fallback_kind"
                    ].string_value(),
                    "provider_runtime",
                )
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "reason"
                    ].string_value(),
                    expected_reason,
                )
                assert_equal(
                    response["output"]["rewritten_text"].string_value(),
                    "apples",
                )


def _assert_query_rewrite_runtime_config_fallback_without_provenance(
    config_text: String, expected_reason: String, request_id: String
) raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(config_text)
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    _query_rewrite_assisted_request_json_without_provenance(
                        request_id
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["meta"]["execution_mode"].string_value(),
                    "deterministic",
                )
                assert_equal(
                    response["meta"]["backend"].string_value(),
                    "heuristic",
                )
                assert_true(not _has_key(response["meta"], "provider"))
                assert_true(not _has_key(response["meta"], "provenance"))
                _assert_provider_runtime_fallback_meta(
                    response, expected_reason
                )
                assert_equal(
                    response["output"]["rewritten_text"].string_value(),
                    "apples",
                )


def _assert_invalid_runtime_config_load_error(
    config_text: String, expected_error_fragment: String
) raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "invalid-hyf-config.toml"
        startup_config_path.write_text(config_text)
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "loaded"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "load_state"
                    ].string_value(),
                    "invalid",
                )
                assert_true(
                    response["output"]["runtime"]["config"]["load_error"]
                    .string_value()
                    .find(expected_error_fragment)
                    >= 0
                )


def _assert_valid_runtime_config_load(config_text: String) raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(config_text)
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "loaded"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "load_state"
                    ].string_value(),
                    "loaded",
                )


def test_business_fallback_reason_taxonomy_declares_provider_io_family() raises:
    _assert_declared_business_fallback_reason("timeout", "provider_io")
    _assert_declared_business_fallback_reason(
        "connection_failed", "provider_io"
    )
    _assert_declared_business_fallback_reason("invalid_url", "provider_io")
    _assert_declared_business_fallback_reason("provider_non_2xx", "provider_io")
    _assert_declared_business_fallback_reason(
        "provider_error_payload", "provider_io"
    )
    _assert_declared_business_fallback_reason(
        "provider_invalid_json", "provider_io"
    )
    _assert_declared_business_fallback_reason(
        "provider_schema_invalid", "provider_io"
    )
    _assert_declared_business_fallback_reason(
        "provider_empty_choices", "provider_io"
    )
    _assert_declared_business_fallback_reason(
        "provider_missing_content", "provider_io"
    )
    _assert_declared_business_fallback_reason("provider_error", "provider_io")


def test_business_fallback_reason_taxonomy_declares_runtime_family() raises:
    _assert_declared_business_fallback_reason(
        "invalid_config", "runtime_config"
    )
    _assert_declared_business_fallback_reason(
        "disabled_by_runtime_config", "runtime_config"
    )
    _assert_declared_business_fallback_reason(
        "provider_unconfigured", "runtime_config"
    )


def test_business_fallback_reason_taxonomy_declares_capability_family() raises:
    _assert_declared_business_fallback_reason(
        "unsupported_capability", "capability_routing"
    )


def test_business_fallback_reason_taxonomy_excludes_control_health_reason() raises:
    assert_equal(
        _business_fallback_reason_family("non_2xx"),
        "undeclared",
    )


def test_business_fallback_reason_taxonomy_excludes_transport_boundary_reason() raises:
    assert_equal(
        _business_fallback_reason_family("unknown_transport"), "undeclared"
    )


def test_status_success() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json("scenarios/status_ok.json")
    )
    assert_matches_scenario_response(response, "scenarios/status_ok.json")


def test_status_reports_repo_local_runtime_truth() raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_equal(
                    response["output"]["runtime"]["id"].string_value(),
                    "hyf_runtime",
                )
                assert_equal(
                    response["output"]["runtime"]["namespace"].string_value(),
                    "services/hyf",
                )
                assert_equal(
                    response["output"]["runtime"][
                        "paths_profile"
                    ].string_value(),
                    "repo_local",
                )
                assert_equal(
                    response["output"]["runtime"][
                        "repo_local_base_root"
                    ].string_value(),
                    temp_dir,
                )
                assert_equal(
                    response["output"]["runtime"]["paths"][
                        "config_path"
                    ].string_value(),
                    temp_dir + "/config/services/hyf/config.toml",
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "artifact_path"
                    ].string_value(),
                    startup_config_path.__fspath__(),
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "artifact_path_source"
                    ].string_value(),
                    "startup_flag",
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "artifact_present"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "load_state"
                    ].string_value(),
                    "not_found",
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "compiled_defaults_active"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "default_execution_mode"
                    ].string_value(),
                    "deterministic",
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "allow_assisted"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "state"
                    ].string_value(),
                    "disabled_by_runtime_config",
                )
                assert_equal(
                    response["output"]["backend_reachability"][
                        "assisted_backend"
                    ].string_value(),
                    "disabled_by_runtime_config",
                )
                assert_equal(
                    response["output"]["runtime"]["paths"][
                        "diagnostics_dir"
                    ].string_value(),
                    temp_dir + "/logs/services/hyf/diagnostics",
                )
                assert_equal(
                    response["output"]["runtime"]["diagnostics"][
                        "canonical_dir"
                    ].string_value(),
                    temp_dir + "/logs/services/hyf/diagnostics",
                )
                assert_equal(
                    response["output"]["runtime"]["diagnostics"][
                        "effective_dir"
                    ].string_value(),
                    temp_dir + "/logs/services/hyf/diagnostics",
                )
                assert_equal(
                    response["output"]["runtime"]["diagnostics"][
                        "debug_override_active"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "default_backend"
                    ].string_value(),
                    "encrypted_file",
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "status"
                    ].string_value(),
                    "reserved",
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_path"
                    ].string_value(),
                    temp_dir + "/secrets/services/hyf/identity.secret.json",
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_material_configured"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "backend_implemented"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_material_loaded"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_material_created_by_startup"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "secret_values_reported"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "status"
                    ].string_value(),
                    "reserved",
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "default_dir"
                    ].string_value(),
                    temp_dir + "/data/services/hyf/protected",
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "configured"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "support_implemented"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "store_open"
                    ].bool_value(),
                    False,
                )
                assert_true(
                    not exists(
                        Path(temp_dir)
                        / "secrets"
                        / "services"
                        / "hyf"
                        / "identity.secret.json"
                    )
                )
                assert_true(
                    not exists(
                        Path(temp_dir)
                        / "data"
                        / "services"
                        / "hyf"
                        / "protected"
                    )
                )


def test_status_loads_valid_runtime_config_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _unavailable_max_local_runtime_config_toml()
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["enabled_execution_modes"][
                        "assisted"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["execution_mode_request_behavior"][
                        "assisted"
                    ].string_value(),
                    "provider_unavailable",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "state"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reason"
                    ].string_value(),
                    "connection_failed",
                )
                assert_equal(
                    response["output"]["assisted_runtime"]["id"].string_value(),
                    "hyf_provider_runtime",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "kind"
                    ].string_value(),
                    "provider_runtime",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "transport"
                    ].string_value(),
                    "http",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "backend_kind"
                    ].string_value(),
                    "max_local",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "provider"
                    ].string_value(),
                    "max_local",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "route"
                    ].string_value(),
                    "provider_runtime.query_rewrite.max_local",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "model"
                    ].string_value(),
                    "max-local-query-rewrite",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reachable"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["backend_reachability"][
                        "assisted_backend"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "artifact_present"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "loaded"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "load_state"
                    ].string_value(),
                    "loaded",
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "compiled_defaults_active"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "service_transport"
                    ].string_value(),
                    "stdio",
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "default_execution_mode"
                    ].string_value(),
                    "deterministic",
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "allow_assisted"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "assisted_runtime_enabled"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "assisted_runtime_configured"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "assisted_provider"
                    ].string_value(),
                    "max_local",
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "max_local_enabled"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "max_local_model"
                    ].string_value(),
                    "max-local-query-rewrite",
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "max_local_route"
                    ].string_value(),
                    "provider_runtime.query_rewrite.max_local",
                )
                assert_equal(
                    Int(
                        response["output"]["runtime"]["config"]["effective"][
                            "max_local_request_timeout_ms"
                        ].int_value()
                    ),
                    250,
                )
                assert_true(
                    not _has_key(
                        response["output"]["runtime"]["config"],
                        "load_error",
                    )
                )


def test_status_reports_invalid_runtime_config_without_crashing() raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "invalid-hyf-config.toml"
        startup_config_path.write_text(
            '[runtime]\ndefault_execution_mode = "assisted"\n'
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["enabled_execution_modes"][
                        "assisted"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["execution_mode_request_behavior"][
                        "assisted"
                    ].string_value(),
                    "invalid_config",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "state"
                    ].string_value(),
                    "invalid_config",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reason"
                    ].string_value(),
                    "invalid_config",
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "artifact_present"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "loaded"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "load_state"
                    ].string_value(),
                    "invalid",
                )
                assert_equal(
                    response["output"]["runtime"]["config"][
                        "compiled_defaults_active"
                    ].bool_value(),
                    True,
                )
                assert_true(
                    response["output"]["runtime"]["config"]["load_error"]
                    .string_value()
                    .find("default_execution_mode")
                    >= 0
                )
                assert_equal(
                    response["output"]["runtime"]["config"]["effective"][
                        "allow_assisted"
                    ].bool_value(),
                    False,
                )


def test_status_reports_unconfigured_assisted_runtime_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            '[service]\ntransport = "stdio"\n\n'
            + "[runtime]\ndefault_execution_mode ="
            ' "deterministic"\nallow_assisted = true\n\n'
            + '[assisted]\nprovider = "max_local"\n'
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["execution_mode_request_behavior"][
                        "assisted"
                    ].string_value(),
                    "provider_unconfigured",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "state"
                    ].string_value(),
                    "unconfigured",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reason"
                    ].string_value(),
                    "not_checked",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "transport"
                    ].string_value(),
                    "deferred",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "configured"
                    ].bool_value(),
                    False,
                )


def test_status_reports_non_2xx_max_local_health_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var provider_stub = spawn_max_local_stub(0, "health_non_2xx", 1)
        var provider_port = provider_stub.port
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _max_local_runtime_config_toml_with_urls(
                "http://127.0.0.1:" + String(provider_port) + "/v1",
                "http://127.0.0.1:" + String(provider_port) + "/health",
                15000,
            )
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "state"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reason"
                    ].string_value(),
                    "non_2xx",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reachable"
                    ].bool_value(),
                    False,
                )

        provider_stub.wait()


def test_status_reports_ready_max_local_provider_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var provider_stub = spawn_max_local_stub(0, "query_rewrite_ok", 1)
        var provider_port = provider_stub.port
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _max_local_runtime_config_toml_with_urls(
                "http://127.0.0.1:" + String(provider_port) + "/v1",
                "http://127.0.0.1:" + String(provider_port) + "/health",
                15000,
            )
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["execution_mode_request_behavior"][
                        "assisted"
                    ].string_value(),
                    "execute",
                )
                assert_equal(
                    response["output"]["backend_reachability"][
                        "assisted_backend"
                    ].string_value(),
                    "ready",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "state"
                    ].string_value(),
                    "ready",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reason"
                    ].string_value(),
                    "ready",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "transport"
                    ].string_value(),
                    "http",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "backend_kind"
                    ].string_value(),
                    "max_local",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "provider"
                    ].string_value(),
                    "max_local",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "route"
                    ].string_value(),
                    "provider_runtime.query_rewrite.max_local",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "model"
                    ].string_value(),
                    "max-local-query-rewrite",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reachable"
                    ].bool_value(),
                    True,
                )

        provider_stub.wait()


def test_status_bounds_max_local_health_probe_timeout() raises:
    with SafeTempDir() as temp_dir:
        var provider_stub = spawn_max_local_stub(0, "health_timeout", 1)
        var provider_port = provider_stub.port
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _max_local_runtime_config_toml_with_urls(
                "http://127.0.0.1:" + String(provider_port) + "/v1",
                "http://127.0.0.1:" + String(provider_port) + "/health",
                15000,
            )
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "state"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reason"
                    ].string_value(),
                    "timeout",
                )
                assert_equal(
                    response["output"]["assisted_runtime"][
                        "reachable"
                    ].bool_value(),
                    False,
                )

        provider_stub.wait()


def test_status_rejects_invalid_max_local_runtime_config() raises:
    var prefix = (
        '[service]\ntransport = "stdio"\n\n[runtime]\ndefault_execution_mode ='
        ' "deterministic"\nallow_assisted = true\n\n'
    )
    var disabled_prefix = (
        '[service]\ntransport = "stdio"\n\n[runtime]\ndefault_execution_mode ='
        ' "deterministic"\nallow_assisted = false\n\n'
    )
    var provider = '[assisted]\nprovider = "max_local"\n\n'
    var max_local_header = "[assisted.max_local]\nenabled = true\n"
    _assert_invalid_runtime_config_load_error(
        prefix + '[assisted]\nprovider = "unsupported"\n',
        "assisted.provider",
    )
    _assert_invalid_runtime_config_load_error(
        prefix + '[assisted]\nprovider = " max_local"\n',
        "assisted.provider",
    )
    _assert_invalid_runtime_config_load_error(
        disabled_prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "runtime.allow_assisted",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.base_url",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = " http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.base_url",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health "\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.health_url",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "file:///tmp/max"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.base_url",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = " max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.model",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = ""\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.model",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + 'route = "provider_runtime.query_rewrite.max_local"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + "[assisted.max_local] # provider route is derived\n"
        + "enabled = true\n"
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + 'route = "provider_runtime.query_rewrite.max_local"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + '"route" = "provider_runtime.query_rewrite.max_local"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "'route' = \"provider_runtime.query_rewrite.max_local\"\n"
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + "assisted.max_local.route ="
        ' "provider_runtime.query_rewrite.max_local"\n'
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + '"assisted"."max_local"."route" ='
        ' "provider_runtime.query_rewrite.max_local"\n'
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + "'assisted'.'max_local'.'route' ="
        ' "provider_runtime.query_rewrite.max_local"\n'
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + '[assisted."max_local"]\n'
        + "enabled = true\n"
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + 'route = "provider_runtime.query_rewrite.max_local"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + '["assisted"."max_local"]\n'
        + "enabled = true\n"
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + 'route = "provider_runtime.query_rewrite.max_local"\n'
        + "request_timeout_ms = 15000\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + "assisted.max_local = { enabled = true, "
        + 'base_url = "http://127.0.0.1:8000/v1", '
        + 'health_url = "http://127.0.0.1:8000/health", '
        + 'model = "max-local-query-rewrite", '
        + 'route = "provider_runtime.query_rewrite.max_local", '
        + "request_timeout_ms = 15000 }\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + "assisted.max_local = { enabled = true, "
        + 'base_url = "http://127.0.0.1:8000/v1", '
        + 'health_url = "http://127.0.0.1:8000/health", '
        + 'model = "max-local-query-rewrite, route = quoted literal", '
        + 'route = "provider_runtime.query_rewrite.max_local", '
        + "request_timeout_ms = 15000 }\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + "assisted.max_local = { enabled = true, "
        + 'base_url = "http://127.0.0.1:8000/v1", '
        + 'health_url = "http://127.0.0.1:8000/health", '
        + 'model = "max-local-query-rewrite", '
        + "'route' = \"provider_runtime.query_rewrite.max_local\", "
        + "request_timeout_ms = 15000 }\n",
        "assisted.max_local.route",
    )
    _assert_invalid_runtime_config_load_error(
        prefix
        + provider
        + max_local_header
        + 'base_url = "http://127.0.0.1:8000/v1"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite"\n'
        + "request_timeout_ms = 0\n",
        "assisted.max_local.request_timeout_ms",
    )


def test_status_allows_non_route_toml_mentions() raises:
    var config = (
        '[service]\ntransport = "stdio"\n\n'
        + '[runtime]\ndefault_execution_mode = "deterministic"\nallow_assisted'
        " = true\n\n"
        + '[assisted]\nprovider = "max_local"\n\n'
        + "# assisted.max_local.route is intentionally derived by HYF\n"
        + "[assisted.max_local]\n"
        + '# route = "provider_runtime.query_rewrite.max_local"\n'
        + "enabled = true\n"
        + "base_url ="
        ' "http://127.0.0.1:8000/v1?route=provider_runtime.query_rewrite.max_local"\n'
        + 'health_url = "http://127.0.0.1:8000/health"\n'
        + 'model = "max-local-query-rewrite-route-token"\n'
        + "request_timeout_ms = 15000\n"
    )
    _assert_valid_runtime_config_load(config)


def test_status_allows_inline_table_quoted_route_mentions() raises:
    var config = (
        '[service]\ntransport = "stdio"\n\n'
        + '[runtime]\ndefault_execution_mode = "deterministic"\nallow_assisted'
        " = true\n\n"
        + '[assisted]\nprovider = "max_local"\n\n'
        + "assisted.max_local = { enabled = true, "
        + 'base_url = "http://127.0.0.1:8000/v1", '
        + 'health_url = "http://127.0.0.1:8000/health", '
        + 'model = "max-local-query-rewrite, route = quoted literal", '
        + "request_timeout_ms = 15000 }\n"
    )
    _assert_valid_runtime_config_load(config)


def test_capabilities_reports_configured_provider_runtime_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _unavailable_max_local_runtime_config_toml()
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json(
                        "scenarios/capabilities_ok.json"
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["business_capabilities"][0][
                        "assisted_execution"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["business_capabilities"][0][
                        "assisted_backend_available"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "id"
                    ].string_value(),
                    "hyf_provider_runtime",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "kind"
                    ].string_value(),
                    "provider_runtime",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "state"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "reason"
                    ].string_value(),
                    "connection_failed",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "backend_kind"
                    ].string_value(),
                    "max_local",
                )


def test_capabilities_reports_ready_max_local_provider_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var provider_stub = spawn_max_local_stub(0, "query_rewrite_ok", 1)
        var provider_port = provider_stub.port
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _max_local_runtime_config_toml_with_urls(
                "http://127.0.0.1:" + String(provider_port) + "/v1",
                "http://127.0.0.1:" + String(provider_port) + "/health",
                15000,
            )
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json(
                        "scenarios/capabilities_ok.json"
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["business_capabilities"][0][
                        "assisted_execution"
                    ].string_value(),
                    "ready",
                )
                assert_equal(
                    response["output"]["business_capabilities"][0][
                        "assisted_backend_available"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["business_capabilities"][2][
                        "assisted_execution"
                    ].string_value(),
                    "unsupported_capability",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "state"
                    ].string_value(),
                    "ready",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "reason"
                    ].string_value(),
                    "ready",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "backend_kind"
                    ].string_value(),
                    "max_local",
                )

        provider_stub.wait()


def test_capabilities_bounds_max_local_health_probe_timeout() raises:
    with SafeTempDir() as temp_dir:
        var provider_stub = spawn_max_local_stub(0, "health_timeout", 1)
        var provider_port = provider_stub.port
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _max_local_runtime_config_toml_with_urls(
                "http://127.0.0.1:" + String(provider_port) + "/v1",
                "http://127.0.0.1:" + String(provider_port) + "/health",
                15000,
            )
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json(
                        "scenarios/capabilities_ok.json"
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["output"]["business_capabilities"][0][
                        "assisted_execution"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["business_capabilities"][0][
                        "assisted_backend_available"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "state"
                    ].string_value(),
                    "unavailable",
                )
                assert_equal(
                    response["output"]["assisted_runtime_capabilities"][0][
                        "reason"
                    ].string_value(),
                    "timeout",
                )

        provider_stub.wait()


def test_query_rewrite_falls_back_deterministically_when_provider_is_unavailable() raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _unavailable_max_local_runtime_config_toml()
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    _query_rewrite_assisted_request_json(
                        "rewrite-assisted-fallback-1"
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["meta"]["execution_mode"].string_value(),
                    "deterministic",
                )
                assert_equal(
                    response["meta"]["backend"].string_value(),
                    "heuristic",
                )
                assert_true(not _has_key(response["meta"], "provider"))
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "fallback_kind"
                    ].string_value(),
                    "provider_runtime",
                )
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "reason"
                    ].string_value(),
                    "connection_failed",
                )
                assert_equal(
                    response["output"]["rewritten_text"].string_value(),
                    "apples",
                )


def test_query_rewrite_falls_back_on_unconfigured_provider_runtime() raises:
    _assert_query_rewrite_runtime_config_fallback(
        '[service]\ntransport = "stdio"\n\n'
        + '[runtime]\ndefault_execution_mode = "deterministic"\nallow_assisted'
        " = true\n\n"
        + '[assisted]\nprovider = "max_local"\n',
        "provider_unconfigured",
        "rewrite-assisted-unconfigured-runtime-1",
    )


def test_query_rewrite_falls_back_on_invalid_provider_runtime_config() raises:
    _assert_query_rewrite_runtime_config_fallback(
        '[runtime]\ndefault_execution_mode = "assisted"\n',
        "invalid_config",
        "rewrite-assisted-invalid-runtime-1",
    )


def test_query_rewrite_fallback_metadata_is_visible_without_provenance() raises:
    _assert_query_rewrite_runtime_config_fallback_without_provenance(
        '[service]\ntransport = "stdio"\n\n'
        + '[runtime]\ndefault_execution_mode = "deterministic"\nallow_assisted'
        " = true\n\n"
        + '[assisted]\nprovider = "max_local"\n',
        "provider_unconfigured",
        "rewrite-assisted-no-provenance-1",
    )


def test_assisted_semantic_rank_falls_back_as_unsupported_provider_capability() raises:
    with SafeTempDir() as temp_dir:
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _unavailable_max_local_runtime_config_toml()
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    _semantic_rank_assisted_request_json(
                        "rank-assisted-unsupported-1"
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["meta"]["execution_mode"].string_value(),
                    "deterministic",
                )
                assert_equal(
                    response["meta"]["backend"].string_value(),
                    "heuristic",
                )
                assert_true(not _has_key(response["meta"], "provider"))
                _assert_provider_runtime_fallback_meta(
                    response, "unsupported_capability"
                )
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "fallback_kind"
                    ].string_value(),
                    "provider_runtime",
                )
                assert_equal(
                    response["meta"]["provenance"]["fallback"][
                        "reason"
                    ].string_value(),
                    "unsupported_capability",
                )
                assert_equal(
                    response["output"]["ranked_ids"][0].string_value(),
                    "listing_local_1",
                )


def test_query_rewrite_uses_max_local_provider_when_ready() raises:
    with SafeTempDir() as temp_dir:
        var provider_stub = spawn_max_local_stub(0, "query_rewrite_ok", 2)
        var provider_port = provider_stub.port
        var startup_config_path = Path(temp_dir) / "explicit-hyf-config.toml"
        startup_config_path.write_text(
            _max_local_runtime_config_toml_with_urls(
                "http://127.0.0.1:" + String(provider_port) + "/v1",
                "http://127.0.0.1:" + String(provider_port) + "/health",
                15000,
            )
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    (
                        '{"version":1,"request_id":"rewrite-assisted-max-local-1","trace_id":"rewrite-assisted-max-local-1","capability":"query_rewrite","context":{"execution_mode_preference":"assisted","return_provenance":true},"input":{"query":"local'
                        ' apples pickup weekend"}}'
                    ),
                    "--config",
                    startup_config_path.__fspath__(),
                )

                assert_true(response["ok"].bool_value())
                assert_equal(
                    response["meta"]["execution_mode"].string_value(),
                    "assisted",
                )
                assert_equal(
                    response["meta"]["backend"].string_value(),
                    "provider_runtime",
                )
                assert_equal(
                    response["meta"]["provider"].string_value(),
                    "max_local",
                )
                assert_equal(
                    response["meta"]["route"].string_value(),
                    "provider_runtime.query_rewrite.max_local",
                )
                assert_equal(
                    response["meta"]["model"].string_value(),
                    "max-local-query-rewrite",
                )
                assert_true(
                    Int(response["meta"]["latency_ms"].int_value()) >= 0
                )
                assert_equal(
                    Int(response["meta"]["schema_version"].int_value()), 1
                )
                assert_equal(
                    response["meta"]["prompt_version"].string_value(),
                    "max_local_query_rewrite_v1",
                )
                assert_equal(
                    response["meta"]["provenance"]["kind"].string_value(),
                    "assisted",
                )
                assert_true(
                    response["meta"]["provenance"]["fallback"].is_null()
                )
                _assert_no_top_level_fallback_meta(response)
                assert_equal(
                    response["output"]["rewritten_text"].string_value(),
                    "apples pickup weekend",
                )
                assert_equal(
                    response["output"]["query_terms"][0].string_value(),
                    "apples",
                )
                assert_equal(
                    response["output"]["query_terms"][1].string_value(),
                    "pickup",
                )
                assert_equal(
                    response["output"]["query_terms"][2].string_value(),
                    "weekend",
                )

        provider_stub.wait()


def test_query_rewrite_falls_back_on_provider_non_2xx() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_non_2xx", "provider_non_2xx", 15000
    )


def test_query_rewrite_falls_back_on_provider_timeout() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_timeout", "timeout", 100
    )


def test_query_rewrite_falls_back_on_unknown_transport_as_provider_error() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_malformed_http", "provider_error", 15000
    )


def test_query_rewrite_falls_back_when_provider_readiness_probe_times_out() raises:
    _assert_query_rewrite_provider_fallback_with_requests(
        "health_timeout", "timeout", 100, 1
    )


def test_query_rewrite_falls_back_on_health_non_2xx_with_business_reason() raises:
    _assert_query_rewrite_provider_fallback_with_requests(
        "health_non_2xx", "provider_non_2xx", 15000, 1
    )


def test_query_rewrite_completion_uses_remaining_deadline_after_readiness() raises:
    _assert_query_rewrite_provider_fallback_with_deadline(
        "query_rewrite_remaining_deadline_timeout",
        "timeout",
        1000,
        500,
        2,
    )


def test_query_rewrite_falls_back_on_provider_invalid_json() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_invalid_json", "provider_invalid_json", 15000
    )


def test_query_rewrite_falls_back_on_provider_schema_invalid_json() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_schema_invalid", "provider_schema_invalid", 15000
    )


def test_query_rewrite_falls_back_on_provider_top_level_string() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_top_level_string", "provider_schema_invalid", 15000
    )


def test_query_rewrite_falls_back_on_provider_top_level_array() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_top_level_array", "provider_schema_invalid", 15000
    )


def test_query_rewrite_falls_back_on_provider_top_level_null() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_top_level_null", "provider_schema_invalid", 15000
    )


def test_query_rewrite_falls_back_on_provider_empty_choices() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_empty_choices", "provider_empty_choices", 15000
    )


def test_query_rewrite_falls_back_on_provider_missing_content() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_missing_content", "provider_missing_content", 15000
    )


def test_query_rewrite_falls_back_on_provider_error_payload() raises:
    _assert_query_rewrite_provider_fallback(
        "query_rewrite_error_payload", "provider_error_payload", 15000
    )


def test_status_reports_configured_but_deferred_custody_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var identity_dir = Path(temp_dir) / "secrets" / "services" / "hyf"
        _ = std.os.makedirs(identity_dir.__fspath__(), exist_ok=True)
        (identity_dir / "identity.secret.json").write_text(
            '{"configured":"test-only-placeholder"}'
        )

        var protected_dir = (
            Path(temp_dir) / "data" / "services" / "hyf" / "protected"
        )
        _ = std.os.makedirs(protected_dir.__fspath__(), exist_ok=True)

        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                )

                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "status"
                    ].string_value(),
                    "reserved",
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "backend_implemented"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_material_configured"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_material_loaded"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_material_created_by_startup"
                    ].bool_value(),
                    False,
                )

                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "status"
                    ].string_value(),
                    "reserved",
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "configured"
                    ].bool_value(),
                    True,
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "support_implemented"
                    ].bool_value(),
                    False,
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "store_open"
                    ].bool_value(),
                    False,
                )


def test_status_clears_repo_local_root_outside_repo_local_profile() raises:
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "interactive_user"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                )

                assert_equal(
                    response["output"]["runtime"][
                        "paths_profile"
                    ].string_value(),
                    "interactive_user",
                )
                assert_equal(
                    response["output"]["runtime"][
                        "repo_local_base_root"
                    ].string_value(),
                    "",
                )
                assert_true(
                    response["output"]["runtime"]["paths"]["config_path"]
                    .string_value()
                    .find(temp_dir)
                    < 0
                )


def test_status_reports_effective_diagnostics_override_truthfully() raises:
    with SafeTempDir() as temp_dir:
        var diagnostics_override_dir = (
            Path(temp_dir) / "debug-diagnostics-override"
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                with ScopedEnvVar(
                    _HYF_DIAGNOSTICS_DIR_ENV,
                    diagnostics_override_dir.__fspath__(),
                ):
                    var response = run_stdio_entrypoint(
                        "src/main.mojo",
                        load_scenario_request_json("scenarios/status_ok.json"),
                    )

                    assert_equal(
                        response["output"]["runtime"]["paths"][
                            "diagnostics_dir"
                        ].string_value(),
                        temp_dir + "/logs/services/hyf/diagnostics",
                    )
                    assert_equal(
                        response["output"]["runtime"]["diagnostics"][
                            "canonical_dir"
                        ].string_value(),
                        temp_dir + "/logs/services/hyf/diagnostics",
                    )
                    assert_equal(
                        response["output"]["runtime"]["diagnostics"][
                            "effective_dir"
                        ].string_value(),
                        diagnostics_override_dir.__fspath__(),
                    )
                    assert_equal(
                        response["output"]["runtime"]["diagnostics"][
                            "debug_override_active"
                        ].bool_value(),
                        True,
                    )


def test_capabilities_success() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json("scenarios/capabilities_ok.json")
    )
    assert_matches_scenario_response(response, "scenarios/capabilities_ok.json")


def test_invalid_envelope_preserves_correlation() raises:
    var response = run_hyf_stdio(status_request_with_invalid_version_json())

    assert_equal(Int(response["version"].int_value()), 1)
    assert_equal(response["request_id"].string_value(), "status-fixture-1")
    assert_equal(response["trace_id"].string_value(), "trace-status-fixture-1")
    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")


def test_assisted_request_fails_explicitly() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json(
            "scenarios/assisted_backend_unavailable.json"
        )
    )
    assert_matches_scenario_response(
        response, "scenarios/assisted_backend_unavailable.json"
    )


def test_deferred_capability_returns_disabled_error() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json(
            "scenarios/deferred_capability_disabled.json"
        )
    )
    assert_matches_scenario_response(
        response, "scenarios/deferred_capability_disabled.json"
    )


def test_query_rewrite_success() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json(
            "scenarios/query_rewrite_local_pickup_weekend.json"
        )
    )
    assert_matches_scenario_response(
        response, "scenarios/query_rewrite_local_pickup_weekend.json"
    )
    _assert_no_top_level_fallback_meta(response)


def test_query_rewrite_does_not_create_protected_local_artifacts() raises:
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json(
                        "scenarios/query_rewrite_local_pickup_weekend.json"
                    ),
                )

                assert_true(response["ok"].bool_value())
                assert_true(
                    not exists(
                        Path(temp_dir)
                        / "data"
                        / "services"
                        / "hyf"
                        / "protected"
                    )
                )
                assert_true(
                    not exists(Path(temp_dir) / "cache" / "services" / "hyf")
                )


def test_semantic_rank_exports_heuristic_score_without_latency() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json(
            "scenarios/semantic_rank_local_pickup_weekend.json"
        )
    )
    assert_matches_scenario_response(
        response, "scenarios/semantic_rank_local_pickup_weekend.json"
    )


def test_explain_result_success() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json(
            "scenarios/explain_result_local_pickup_weekend.json"
        )
    )
    assert_matches_scenario_response(
        response, "scenarios/explain_result_local_pickup_weekend.json"
    )


def test_strict_query_rewrite_failure() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json(
            "scenarios/query_rewrite_unexpected_field.json"
        )
    )
    assert_matches_scenario_response(
        response, "scenarios/query_rewrite_unexpected_field.json"
    )


def test_strict_semantic_rank_failure() raises:
    var response = run_hyf_stdio(
        '{"version":1,"request_id":"rank-bad-proc-1","capability":"semantic_rank","input":{"query":"eggs'
        ' near me","candidates":[{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}]}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_duplicate_candidate_ids_fail_explicitly() raises:
    var response = run_hyf_stdio(
        '{"version":1,"request_id":"rank-dup-proc-1","capability":"semantic_rank","input":{"query":"eggs'
        ' near me","candidates":[{"id":"lst_dup","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_dup","title":"Free'
        ' range eggs","farm":"Santa'
        ' Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"]
        .string_value()
        .find("duplicate candidate id")
        >= 0
    )


def test_missing_input_fails_explicitly() raises:
    var response = run_hyf_stdio(
        '{"version":1,"request_id":"missing-input-proc-1","capability":"query_rewrite"}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"]
        .string_value()
        .find("field 'input' is required")
        >= 0
    )


def test_internal_error_is_bounded_on_wire() raises:
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "tests/internal_error_stdio_main.mojo",
                    '{"version":1,"request_id":"status-internal-proc-1","trace_id":"trace-status-internal-proc-1","capability":"sys.status","input":{}}',
                )

                assert_equal(Int(response["version"].int_value()), 1)
                assert_equal(
                    response["request_id"].string_value(),
                    "status-internal-proc-1",
                )
                assert_equal(
                    response["trace_id"].string_value(),
                    "trace-status-internal-proc-1",
                )
                assert_true(not response["ok"].bool_value())
                assert_equal(
                    response["error"]["code"].string_value(), "internal_error"
                )
                assert_equal(
                    response["error"]["message"].string_value(),
                    _EXPECTED_INTERNAL_ERROR_MESSAGE,
                )
                assert_true(
                    response["error"]["message"]
                    .string_value()
                    .find("simulated test-only")
                    < 0
                )


def test_internal_error_records_detail_in_canonical_runtime_diagnostics_dir() raises:
    with SafeTempDir() as temp_dir:
        var diagnostics_dir = (
            Path(temp_dir) / "logs" / "services" / "hyf" / "diagnostics"
        )
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var response = run_stdio_entrypoint(
                    "tests/internal_error_stdio_main.mojo",
                    '{"version":1,"request_id":"status-internal-proc-diag-1","trace_id":"trace-status-internal-proc-diag-1","capability":"sys.status","input":{}}',
                )

                assert_true(not response["ok"].bool_value())
                assert_equal(
                    response["error"]["code"].string_value(),
                    "internal_error",
                )
                assert_true(exists(diagnostics_dir))

                var entries = std.os.listdir(diagnostics_dir)
                assert_equal(len(entries), 1)
                assert_true(entries[0].startswith("hyf-internal-error-pid-"))

                var content = (diagnostics_dir / entries[0]).read_text()
                assert_true(
                    content.find('request_id="status-internal-proc-diag-1"')
                    >= 0
                )
                assert_true(
                    content.find('trace_id="trace-status-internal-proc-diag-1"')
                    >= 0
                )
                assert_true(
                    content.find(
                        'detail="simulated test-only status builder failure"'
                    )
                    >= 0
                )
                assert_true(
                    (diagnostics_dir / entries[0])
                    .__fspath__()
                    .startswith(temp_dir + "/logs/services/hyf/diagnostics/")
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
