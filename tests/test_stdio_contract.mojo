import std.os
from std.os.path import exists
from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite
from std.tempfile import TemporaryDirectory

from mojson import Value
from fixture_assertions import (
    assert_matches_scenario_response,
    load_scenario_request_json,
    status_request_with_invalid_version_json,
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


def test_status_success() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json("scenarios/status_ok.json")
    )
    assert_matches_scenario_response(response, "scenarios/status_ok.json")


def test_status_reports_repo_local_runtime_truth() raises:
    with TemporaryDirectory() as temp_dir:
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
                        "compiled_defaults_active"
                    ].bool_value(),
                    True,
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
                    "reserved_pending_shared_secret_storage",
                )
                assert_equal(
                    response["output"]["runtime"]["secret_storage"][
                        "identity_path"
                    ].string_value(),
                    temp_dir + "/secrets/services/hyf/identity.secret.json",
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
                    "reserved_pending_protected_store",
                )
                assert_equal(
                    response["output"]["runtime"]["protected_local_data"][
                        "default_dir"
                    ].string_value(),
                    temp_dir + "/data/services/hyf/protected",
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


def test_status_clears_repo_local_root_outside_repo_local_profile() raises:
    with TemporaryDirectory() as temp_dir:
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
                    response["output"]["runtime"]["paths"][
                        "config_path"
                    ].string_value().find(temp_dir)
                    < 0
                )


def test_status_reports_effective_diagnostics_override_truthfully() raises:
    with TemporaryDirectory() as temp_dir:
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
    with TemporaryDirectory() as temp_dir:
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
    with TemporaryDirectory() as temp_dir:
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
