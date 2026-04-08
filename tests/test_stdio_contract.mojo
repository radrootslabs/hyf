from std.os import getenv, setenv, unsetenv
from std.subprocess import run
from std.testing import assert_equal, assert_true, TestSuite

from mojson import Value, loads


comptime _EXPECTED_INTERNAL_ERROR_MESSAGE = (
    "internal hyf daemon error; inspect local diagnostics"
)
comptime _PACKAGE_SURFACE_FAULT_ENV = (
    "HYF_TEST_FAULT_CURRENT_PACKAGE_SURFACE"
)


def _run_hyf(request_json: String) raises -> Value:
    var command = (
        "printf '%s\\n' '"
        + request_json
        + "' | mojo run src/main.mojo"
    )
    var output = run(command)
    if output == "":
        raise Error("hyf process returned no stdout payload")
    return loads(output)

def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def test_status_success() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"status-proc-1","trace_id":"trace-status-proc-1","capability":"sys.status","input":{}}'
    )

    assert_equal(Int(response["version"].int_value()), 1)
    assert_equal(response["request_id"].string_value(), "status-proc-1")
    assert_equal(response["trace_id"].string_value(), "trace-status-proc-1")
    assert_true(response["ok"].bool_value())
    assert_equal(
        response["output"]["build_identity"]["service_name"].string_value(),
        "hyf",
    )
    assert_equal(
        response["output"]["execution_mode_request_behavior"]["assisted"].string_value(),
        "backend_unavailable",
    )
    assert_equal(
        response["output"]["request_context_contract"]["accepted_features"][2].string_value(),
        "scope.listing_ids",
    )
    assert_equal(
        response["output"]["request_context_contract"]["effective_features"][0].string_value(),
        "execution_mode_preference",
    )


def test_invalid_envelope_preserves_correlation() raises:
    var response = _run_hyf(
        '{"version":2,"request_id":"bad-envelope-proc-1","trace_id":"trace-bad-envelope-proc-1","capability":"sys.status","input":{}}'
    )

    assert_equal(Int(response["version"].int_value()), 1)
    assert_equal(response["request_id"].string_value(), "bad-envelope-proc-1")
    assert_equal(
        response["trace_id"].string_value(), "trace-bad-envelope-proc-1"
    )
    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")


def test_assisted_request_fails_explicitly() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"assisted-proc-1","capability":"query_rewrite","context":{"execution_mode_preference":"assisted"},"input":{"text":"eggs near me"}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "backend_unavailable")


def test_semantic_rank_exports_heuristic_score_without_latency() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"rank-proc-1","capability":"semantic_rank","input":{"query":"eggs near me with weekend pickup","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_8k1p","title":"Free range eggs","farm":"Santa Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
    )

    assert_true(response["ok"].bool_value())
    assert_equal(
        response["output"]["scored_candidates"][0]["heuristic_score"].int_value(),
        102,
    )
    assert_true(not _has_key(response["output"]["scored_candidates"][0], "score"))
    assert_true(not _has_key(response["meta"], "latency_ms"))


def test_strict_query_rewrite_failure() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"rewrite-bad-proc-1","capability":"query_rewrite","input":{"text":"eggs near me","tone":"brief"}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_strict_semantic_rank_failure() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"rank-bad-proc-1","capability":"semantic_rank","input":{"query":"eggs near me","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}]}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_internal_error_is_bounded_on_wire() raises:
    var original_fault = getenv(_PACKAGE_SURFACE_FAULT_ENV, "")
    _ = setenv(
        _PACKAGE_SURFACE_FAULT_ENV, "invalid_unquoted_version"
    )
    try:
        var response = _run_hyf(
            '{"version":1,"request_id":"status-internal-proc-1","trace_id":"trace-status-internal-proc-1","capability":"sys.status","input":{}}'
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
            response["error"]["message"].string_value().find(
                "quoted string"
            )
            < 0
        )
    except e:
        if original_fault == "":
            _ = unsetenv(_PACKAGE_SURFACE_FAULT_ENV)
        else:
            _ = setenv(_PACKAGE_SURFACE_FAULT_ENV, original_fault)
        raise e^

    if original_fault == "":
        _ = unsetenv(_PACKAGE_SURFACE_FAULT_ENV)
    else:
        _ = setenv(_PACKAGE_SURFACE_FAULT_ENV, original_fault)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
