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
    HYF_DIAGNOSTICS_DIR_ENV,
    ScopedEnvVar,
    run_hyf_stdio,
    run_stdio_entrypoint,
)


comptime _EXPECTED_INTERNAL_ERROR_MESSAGE = (
    "internal hyf daemon error; inspect local diagnostics"
)
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


def test_capabilities_success() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json("scenarios/capabilities_ok.json")
    )
    assert_matches_scenario_response(response, "scenarios/capabilities_ok.json")


def test_invalid_envelope_preserves_correlation() raises:
    var response = run_hyf_stdio(status_request_with_invalid_version_json())

    assert_equal(Int(response["version"].int_value()), 1)
    assert_equal(
        response["request_id"].string_value(), "status-fixture-1"
    )
    assert_equal(
        response["trace_id"].string_value(), "trace-status-fixture-1"
    )
    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")


def test_assisted_request_fails_explicitly() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json("scenarios/assisted_backend_unavailable.json")
    )
    assert_matches_scenario_response(
        response, "scenarios/assisted_backend_unavailable.json"
    )


def test_deferred_capability_returns_disabled_error() raises:
    var response = run_hyf_stdio(
        load_scenario_request_json("scenarios/deferred_capability_disabled.json")
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
        '{"version":1,"request_id":"rank-bad-proc-1","capability":"semantic_rank","input":{"query":"eggs near me","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}]}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_duplicate_candidate_ids_fail_explicitly() raises:
    var response = run_hyf_stdio(
        '{"version":1,"request_id":"rank-dup-proc-1","capability":"semantic_rank","input":{"query":"eggs near me","candidates":[{"id":"lst_dup","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_dup","title":"Free range eggs","farm":"Santa Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("duplicate candidate id")
        >= 0
    )


def test_missing_input_fails_explicitly() raises:
    var response = run_hyf_stdio(
        '{"version":1,"request_id":"missing-input-proc-1","capability":"query_rewrite"}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("field 'input' is required")
        >= 0
    )


def test_internal_error_is_bounded_on_wire() raises:
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
        response["error"]["message"].string_value().find("simulated test-only")
        < 0
    )


def test_internal_error_records_detail_in_explicit_diagnostics_dir() raises:
    with TemporaryDirectory() as temp_dir:
        var diagnostics_dir = Path(temp_dir) / "hyf-internal-diagnostics"
        with ScopedEnvVar(
            HYF_DIAGNOSTICS_DIR_ENV, diagnostics_dir.__fspath__()
        ):
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
                content.find(
                    'request_id="status-internal-proc-diag-1"'
                )
                >= 0
            )
            assert_true(
                content.find(
                    'trace_id="trace-status-internal-proc-diag-1"'
                )
                >= 0
            )
            assert_true(
                content.find(
                    'detail="simulated test-only status builder failure"'
                )
                >= 0
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
