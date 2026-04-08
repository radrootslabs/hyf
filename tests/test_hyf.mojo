from std.pathlib import Path, _dir_of_current_file
from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from mojson import Value, loads

from hyf_core.backends.selector import (
    execute_capability as execute_core_capability,
    resolve_backend,
)
from hyf_core.metadata import current_build_identity, current_package_surface
from hyf_core.request_context import default_request_context
from hyf_stdio.control.capabilities import build_capabilities_output
from hyf_stdio.codec import decode_request, encode_error, encode_success
from hyf_stdio.envelope import WireErrorResponse, WireSuccessResponse
from hyf_stdio.errors import WireError
from hyf_stdio.server import (
    handle_request_line,
    handle_request_line_with_control_builders,
)


comptime _EXPECTED_INTERNAL_ERROR_MESSAGE = (
    "internal hyf daemon error; inspect local diagnostics"
)


def _dispatch(line: String) raises -> Value:
    return loads(handle_request_line(line))


def _failing_status_output() raises -> Value:
    raise Error("simulated test-only status builder failure")


def _test_manifest_path() raises -> Path:
    return _dir_of_current_file() / ".." / "pixi.toml"


def _parse_manifest_quoted_value(value: String) raises -> String:
    var trimmed = value.strip()
    if (
        trimmed.byte_length() < 2
        or not trimmed.startswith("\"")
        or not trimmed.endswith("\"")
    ):
        raise Error("manifest assignment value must be quoted")
    return String(trimmed[byte=1 : trimmed.byte_length() - 1])


def _manifest_workspace_value(target_key: String) raises -> String:
    var in_workspace = False

    for raw_line in _test_manifest_path().read_text().splitlines():
        var line = String(raw_line).strip()
        if line == "" or line.startswith("#"):
            continue

        if line.startswith("["):
            in_workspace = line == "[workspace]"
            continue

        if not in_workspace:
            continue

        var equals_index = line.find("=")
        if equals_index < 0:
            continue

        var key = String(line[byte=0:equals_index]).strip()
        if key != target_key:
            continue

        return _parse_manifest_quoted_value(
            String(line[byte=equals_index + 1 :])
        )

    raise Error("missing workspace manifest key '" + target_key + "'")


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _business_capability(result: Value, capability_id: String) raises -> Value:
    for capability in result["output"]["business_capabilities"].array_items():
        if capability["id"].string_value() == capability_id:
            return capability.clone()
    raise Error("missing capability '" + capability_id + "' in response")


def _array_string_values(value: Value) raises -> List[String]:
    var items = List[String]()
    for item in value.array_items():
        items.append(item.string_value())
    return items^


def test_decode_request_parses_context_and_input() raises:
    var request = decode_request(
        '{"version":1,"request_id":"req-1","trace_id":"trace-1","capability":"query_rewrite","context":{"consumer":"radroots-cli","execution_mode_preference":"deterministic","return_provenance":true},"input":{"query":"eggs near me"}}'
    )

    assert_equal(request.version, 1)
    assert_equal(request.request_id, "req-1")
    assert_equal(request.trace_id.value(), "trace-1")
    assert_equal(request.capability, "query_rewrite")
    assert_equal(request.context.consumer, "radroots-cli")
    assert_equal(
        request.context.execution_mode_preference, "deterministic"
    )
    assert_equal(request.context.return_provenance, True)
    assert_equal(request.input["query"].string_value(), "eggs near me")


def test_decode_request_rejects_unexpected_field() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-1","capability":"query_rewrite","input":{"query":"eggs"},"unexpected":true}'
        )


def test_decode_request_rejects_unsupported_context_field() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-ctx-1","capability":"query_rewrite","context":{"deadline_ms":2500},"input":{"query":"eggs"}}'
        )


def test_decode_request_rejects_unsupported_scope_field() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-scope-1","capability":"semantic_rank","context":{"scope":{"farm_ids":["farm-1"]}},"input":{"query":"eggs","candidates":[{"id":"lst_1","title":"Eggs","farm":"One Farm","delivery":"pickup","distance_km":1.0,"freshness_minutes":5}]}}'
        )


def test_encode_success_and_error_shapes() raises:
    var output = loads("{}")
    output.set("kind", Value("ok"))

    var meta = loads("{}")
    meta.set("execution_mode", Value("deterministic"))

    var success = loads(
        encode_success(
            WireSuccessResponse(
                version=1,
                request_id="req-success",
                trace_id=String("trace-success"),
                output=output.copy(),
                meta=meta.copy(),
            )
        )
    )
    assert_equal(Int(success["version"].int_value()), 1)
    assert_equal(success["request_id"].string_value(), "req-success")
    assert_equal(success["trace_id"].string_value(), "trace-success")
    assert_equal(success["ok"].bool_value(), True)
    assert_equal(success["output"]["kind"].string_value(), "ok")
    assert_equal(
        success["meta"]["execution_mode"].string_value(),
        "deterministic",
    )
    assert_true(not _has_key(success["meta"], "latency_ms"))

    var failure = loads(
        encode_error(
            WireErrorResponse(
                version=1,
                request_id="req-error",
                trace_id=String("trace-error"),
                error=WireError(code="invalid_request", message="bad request"),
            )
        )
    )
    assert_equal(Int(failure["version"].int_value()), 1)
    assert_equal(failure["request_id"].string_value(), "req-error")
    assert_equal(failure["trace_id"].string_value(), "trace-error")
    assert_equal(failure["ok"].bool_value(), False)
    assert_equal(failure["error"]["code"].string_value(), "invalid_request")
    assert_equal(failure["error"]["message"].string_value(), "bad request")


def test_handle_request_line_returns_invalid_request_for_bad_line() raises:
    var result = _dispatch("")
    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["request_id"].string_value(), "")
    assert_equal(_has_key(result, "trace_id"), False)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["error"]["code"].string_value(), "invalid_request")


def test_current_build_identity_matches_manifest_package_surface() raises:
    var package_surface = current_package_surface()
    var build_identity = current_build_identity()
    var manifest_package_name = _manifest_workspace_value("name")
    var manifest_package_version = _manifest_workspace_value("version")

    assert_equal(package_surface.package_name, manifest_package_name)
    assert_equal(package_surface.package_version, manifest_package_version)
    assert_equal(build_identity.package_name, manifest_package_name)
    assert_equal(
        build_identity.package_version, manifest_package_version
    )


def test_status_reports_registered_deterministic_ready() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"status-1","trace_id":"trace-status-1","capability":"sys.status","input":{}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["trace_id"].string_value(), "trace-status-1")
    assert_equal(result["ok"].bool_value(), True)
    assert_equal(
        result["output"]["build_identity"]["service_name"].string_value(),
        "hyf",
    )
    assert_equal(
        result["output"]["build_identity"]["package_name"].string_value(),
        "hyf",
    )
    assert_equal(
        result["output"]["build_identity"]["package_version"].string_value(),
        "0.1.0",
    )
    assert_equal(
        result["output"]["build_identity"]["protocol_version"].int_value(),
        1,
    )
    assert_equal(
        result["output"]["build_identity"]["default_execution_mode"].string_value(),
        "deterministic",
    )
    assert_equal(
        result["output"]["build_identity"]["deterministic_execution_available"].bool_value(),
        True,
    )
    assert_equal(
        result["output"]["build_identity"]["assisted_execution_available"].bool_value(),
        False,
    )
    assert_equal(
        result["output"]["implementation_status"].string_value(),
        "bootstrap_registered_deterministic_ready",
    )
    assert_equal(
        result["output"]["backend_reachability"]["deterministic_backend"].string_value(),
        "available",
    )
    assert_equal(
        result["output"]["execution_mode_request_behavior"]["deterministic"].string_value(),
        "execute",
    )
    assert_equal(
        result["output"]["execution_mode_request_behavior"]["assisted"].string_value(),
        "backend_unavailable",
    )
    assert_equal(
        Int(
            result["output"]["counts"]["deterministic_registered_business_capabilities"].int_value()
        ),
        3,
    )
    assert_equal(
        Int(
            result["output"]["counts"]["deterministic_implemented_business_capabilities"].int_value()
        ),
        3,
    )
    assert_true(
        not _has_key(result["output"]["limits"], "request_context_features")
    )
    var status_request_context_contract = result["output"][
        "request_context_contract"
    ]
    var status_accepted = _array_string_values(
        status_request_context_contract["accepted_features"]
    )
    assert_equal(len(status_accepted), 4)
    assert_equal(status_accepted[0], "consumer")
    assert_equal(status_accepted[1], "execution_mode_preference")
    assert_equal(status_accepted[2], "scope.listing_ids")
    assert_equal(status_accepted[3], "return_provenance")
    var status_effective = _array_string_values(
        status_request_context_contract["effective_features"]
    )
    assert_equal(len(status_effective), 3)
    assert_equal(status_effective[0], "execution_mode_preference")
    assert_equal(status_effective[1], "scope.listing_ids")
    assert_equal(status_effective[2], "return_provenance")
    assert_equal(
        status_request_context_contract["unsupported_field_behavior"].string_value(),
        "reject",
    )


def test_capabilities_report_implemented_and_disabled_states() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"caps-1","capability":"sys.capabilities","input":{}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    var query_rewrite = _business_capability(result, "query_rewrite")
    var semantic_rank = _business_capability(result, "semantic_rank")
    var explain_result = _business_capability(result, "explain_result")
    var filter_extraction = _business_capability(result, "filter_extraction")

    assert_equal(query_rewrite["implemented"].bool_value(), True)
    assert_equal(query_rewrite["callable"].bool_value(), True)
    assert_equal(
        semantic_rank["implementation_status"].string_value(), "implemented"
    )
    assert_equal(
        explain_result["implementation_status"].string_value(), "implemented"
    )
    assert_equal(
        filter_extraction["deterministic_execution"].string_value(),
        "disabled",
    )
    assert_equal(
        filter_extraction["disabled_reason"].string_value(),
        "deferred_bootstrap_capability",
    )
    assert_true(
        not _has_key(result["output"], "request_context_features")
    )
    var capabilities_request_context_contract = result["output"][
        "request_context_contract"
    ]
    var capabilities_accepted = _array_string_values(
        capabilities_request_context_contract["accepted_features"]
    )
    assert_equal(len(capabilities_accepted), 4)
    assert_equal(capabilities_accepted[0], "consumer")
    assert_equal(
        capabilities_accepted[1], "execution_mode_preference"
    )
    assert_equal(capabilities_accepted[2], "scope.listing_ids")
    assert_equal(capabilities_accepted[3], "return_provenance")
    var capabilities_effective = _array_string_values(
        capabilities_request_context_contract["effective_features"]
    )
    assert_equal(len(capabilities_effective), 3)
    assert_equal(
        capabilities_effective[0], "execution_mode_preference"
    )
    assert_equal(capabilities_effective[1], "scope.listing_ids")
    assert_equal(capabilities_effective[2], "return_provenance")
    assert_equal(
        capabilities_request_context_contract["unsupported_field_behavior"].string_value(),
        "reject",
    )


def test_disabled_capability_returns_capability_disabled() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"disabled-1","capability":"filter_extraction","input":{}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "disabled-1")
    assert_equal(result["error"]["code"].string_value(), "capability_disabled")


def test_backend_selector_routes_deterministic_wave() raises:
    var context = default_request_context()
    var selection = resolve_backend(context)

    assert_equal(selection.backend_name, "heuristic")
    assert_equal(selection.available, True)

    var result = execute_core_capability(
        "query_rewrite",
        loads('{"text":"eggs near me with weekend pickup"}'),
        context,
    )

    assert_true(result.success)
    assert_equal(
        result.success.value().meta.value().backend,
        "heuristic",
    )
    assert_equal(
        result.success.value().meta.value().execution_mode,
        "deterministic",
    )


def test_backend_selector_reports_assisted_unavailable() raises:
    var context = default_request_context()
    context.execution_mode_preference = "assisted"

    var selection = resolve_backend(context)
    assert_equal(selection.backend_name, "assisted_execution")
    assert_equal(selection.available, False)

    var result = execute_core_capability(
        "query_rewrite",
        loads('{"text":"eggs near me"}'),
        context,
    )

    assert_true(result.failure)
    assert_equal(result.failure.value().error.code, "backend_unavailable")


def test_query_rewrite_returns_deterministic_output() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rewrite-1","trace_id":"trace-rewrite-1","capability":"query_rewrite","input":{"text":"eggs near me with weekend pickup"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["trace_id"].string_value(), "trace-rewrite-1")
    assert_equal(result["ok"].bool_value(), True)
    assert_equal(
        result["output"]["rewritten_text"].string_value(),
        "eggs",
    )
    assert_equal(
        result["output"]["extracted_filters"]["fulfillment"].string_value(),
        "pickup",
    )
    assert_equal(result["meta"]["backend"].string_value(), "heuristic")
    assert_true(not _has_key(result["meta"], "latency_ms"))


def test_query_rewrite_accepts_query_alias_with_same_behavior() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rewrite-query-1","capability":"query_rewrite","input":{"query":"eggs near me with weekend pickup"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), True)
    assert_equal(
        result["output"]["rewritten_text"].string_value(),
        "eggs",
    )
    assert_equal(
        result["output"]["extracted_filters"]["fulfillment"].string_value(),
        "pickup",
    )


def test_query_rewrite_rejects_unknown_input_field() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rewrite-bad-field-1","capability":"query_rewrite","input":{"text":"eggs near me","tone":"brief"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rewrite-bad-field-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_query_rewrite_rejects_text_and_query_together() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rewrite-bad-dual-1","capability":"query_rewrite","input":{"text":"eggs near me","query":"eggs"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rewrite-bad-dual-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("exactly one") >= 0
    )


def test_semantic_rank_returns_ranked_ids_and_reasons() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-1","capability":"semantic_rank","input":{"query":"eggs near me with weekend pickup","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_8k1p","title":"Free range eggs","farm":"Santa Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), True)
    assert_equal(
        result["output"]["ranked_ids"][0].string_value(),
        "lst_7ak2",
    )
    assert_equal(
        result["output"]["ranked_ids"][1].string_value(),
        "lst_8k1p",
    )
    assert_equal(
        result["output"]["reasons"]["lst_7ak2"][1].string_value(),
        "pickup match",
    )
    assert_equal(
        result["output"]["scored_candidates"][0]["heuristic_score"].int_value(),
        102,
    )
    assert_true(
        not _has_key(result["output"]["scored_candidates"][0], "score")
    )
    assert_true(not _has_key(result["meta"], "latency_ms"))


def test_semantic_rank_scope_listing_ids_remains_effective() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-scope-1","capability":"semantic_rank","context":{"scope":{"listing_ids":["lst_8k1p"]}},"input":{"query":"eggs","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_8k1p","title":"Free range eggs","farm":"Santa Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), True)
    assert_equal(
        result["output"]["ranked_ids"][0].string_value(),
        "lst_8k1p",
    )
    assert_equal(
        result["output"]["scored_candidates"][0]["scope_match"].bool_value(),
        True,
    )
    assert_true(
        _has_key(result["output"]["scored_candidates"][0], "heuristic_score")
    )


def test_semantic_rank_rejects_unknown_top_level_field() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-bad-top-1","capability":"semantic_rank","input":{"query":"eggs near me","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2}],"tone":"brief"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rank-bad-top-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_semantic_rank_rejects_unknown_candidate_field() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-bad-candidate-1","capability":"semantic_rank","input":{"query":"eggs near me","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(
        result["request_id"].string_value(), "rank-bad-candidate-1"
    )
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_explain_result_returns_deterministic_summary_and_provenance() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"explain-1","capability":"explain_result","context":{"consumer":"radroots-cli","return_provenance":true},"input":{"query":"eggs near me with weekend pickup","candidate":{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2}}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), True)
    assert_equal(
        result["output"]["explanation_kind"].string_value(),
        "deterministic",
    )
    assert_true(
        result["output"]["summary"].string_value().find("pickup match") >= 0
    )
    assert_equal(
        result["meta"]["provenance"]["kind"].string_value(),
        "deterministic",
    )
    assert_equal(
        result["meta"]["provenance"]["source_refs"][1]["source_kind"].string_value(),
        "candidate",
    )
    assert_true(not _has_key(result["meta"], "latency_ms"))


def test_explain_result_accepts_result_alias() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"explain-result-1","capability":"explain_result","input":{"query":"eggs near me with weekend pickup","result":{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2}}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), True)
    assert_equal(
        result["output"]["result_id"].string_value(),
        "lst_7ak2",
    )
    assert_equal(
        result["output"]["explanation_kind"].string_value(),
        "deterministic",
    )


def test_explain_result_rejects_unknown_top_level_field() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"explain-bad-top-1","capability":"explain_result","input":{"query":"eggs near me","candidate":{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},"tone":"brief"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(
        result["request_id"].string_value(), "explain-bad-top-1"
    )
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_explain_result_rejects_unknown_candidate_field() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"explain-bad-candidate-1","capability":"explain_result","input":{"query":"eggs near me","candidate":{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(
        result["request_id"].string_value(), "explain-bad-candidate-1"
    )
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_semantic_rank_invalid_input_returns_invalid_request() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-bad-1","trace_id":"trace-rank-bad-1","capability":"semantic_rank","input":{"query":"eggs near me with weekend pickup","candidates":[]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rank-bad-1")
    assert_equal(result["trace_id"].string_value(), "trace-rank-bad-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("must not be empty") >= 0
    )


def test_assisted_request_returns_backend_unavailable() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rewrite-assisted-1","trace_id":"trace-rewrite-assisted-1","capability":"query_rewrite","context":{"execution_mode_preference":"assisted"},"input":{"text":"eggs near me"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["request_id"].string_value(), "rewrite-assisted-1")
    assert_equal(
        result["trace_id"].string_value(), "trace-rewrite-assisted-1"
    )
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(
        result["error"]["code"].string_value(), "backend_unavailable"
    )
    assert_true(
        result["error"]["message"].string_value().find("assisted_execution")
        >= 0
    )


def test_invalid_request_preserves_request_and_trace_correlation() raises:
    var result = _dispatch(
        '{"version":2,"request_id":"bad-version-1","trace_id":"trace-bad-version-1","capability":"sys.status","input":{}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["request_id"].string_value(), "bad-version-1")
    assert_equal(result["trace_id"].string_value(), "trace-bad-version-1")
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unsupported") >= 0
    )


def test_internal_error_is_bounded_on_wire() raises:
    var result = loads(
        handle_request_line_with_control_builders[
            _failing_status_output, build_capabilities_output
        ](
            '{"version":1,"request_id":"status-internal-1","trace_id":"trace-status-internal-1","capability":"sys.status","input":{}}'
        )
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(
        result["request_id"].string_value(), "status-internal-1"
    )
    assert_equal(
        result["trace_id"].string_value(), "trace-status-internal-1"
    )
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(
        result["error"]["code"].string_value(), "internal_error"
    )
    assert_equal(
        result["error"]["message"].string_value(),
        _EXPECTED_INTERNAL_ERROR_MESSAGE,
    )
    assert_true(
        result["error"]["message"].string_value().find("simulated test-only")
        < 0
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
