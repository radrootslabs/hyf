from std.subprocess import run
from std.testing import assert_equal, assert_true, TestSuite

from mojson import Value, loads


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
