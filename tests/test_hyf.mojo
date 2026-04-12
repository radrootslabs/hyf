import std.os
from std.os.path import exists
from std.pathlib import Path, _dir_of_current_file
from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)
from std.tempfile import TemporaryDirectory

from mojson import Value, loads

from fixture_assertions import (
    assert_matches_scenario_response,
    load_scenario_request_json,
    status_request_with_invalid_version_json,
)

from fixture_loader import (
    fixture_manifest_path,
    load_fixture_json_file,
    load_fixture_manifest,
    load_fixture_scenario,
    load_fixture_scenario_expected,
    load_fixture_scenario_request,
    load_fixture_top_level_field_from_path,
)
from hyf_core.backends.selector import (
    execute_capability as execute_core_capability,
    resolve_backend,
)
from hyf_core.capabilities.registry import canonical_business_capabilities
from hyf_core.metadata import current_build_identity, current_package_surface
from hyf_core.request_context import default_request_context
from hyf_stdio.control.capabilities import build_capabilities_output
from hyf_stdio.codec import decode_request, encode_error, encode_success
from hyf_stdio.envelope import WireErrorResponse, WireSuccessResponse
from hyf_stdio.errors import WireError
from hyf_runtime.startup import RuntimeStartupInput, resolve_startup_context
from hyf_stdio.server import (
    handle_request_line_with_runtime_context,
    handle_request_line_with_control_builders,
)


comptime _EXPECTED_INTERNAL_ERROR_MESSAGE = (
    "internal hyf daemon error; inspect local diagnostics"
)
comptime _HYF_DIAGNOSTICS_DIR_ENV = "HYF_DIAGNOSTICS_DIR"


struct ScopedEnvVar:
    var name: String
    var value: String
    var previous: String
    var had_previous: Bool

    def __init__(out self, name: String, value: String):
        self.name = String(name)
        self.value = String(value)
        self.previous = std.os.getenv(name)
        self.had_previous = self.previous != ""

    def __enter__(mut self) raises:
        _ = std.os.setenv(self.name, self.value, overwrite=True)

    def __exit__(mut self):
        if self.had_previous:
            _ = std.os.setenv(self.name, self.previous, overwrite=True)
        else:
            _ = std.os.unsetenv(self.name)


def _dispatch(line: String) raises -> Value:
    var result = Value(None)
    with TemporaryDirectory() as temp_dir:
        var runtime_context = resolve_startup_context(
            RuntimeStartupInput(
                env_paths_profile="repo_local",
                env_repo_local_base_root=temp_dir,
                user_home="/home/unused",
                argv=List[String](),
            )
        )
        result = loads(
            handle_request_line_with_runtime_context(line, runtime_context)
        )
    return result^


def _capability_output_entry_by_id(
    output: Value, capability_id: String
) raises -> Value:
    for entry in output["business_capabilities"].array_items():
        if entry["id"].string_value() == capability_id:
            return entry.clone()
    raise Error("missing business capability entry '" + capability_id + "'")


def _sample_request_json_for_callable_capability(
    capability_id: String,
) raises -> String:
    if capability_id == "query_rewrite":
        return load_scenario_request_json(
            "scenarios/query_rewrite_local_pickup_weekend.json"
        )
    if capability_id == "semantic_rank":
        return load_scenario_request_json(
            "scenarios/semantic_rank_local_pickup_weekend.json"
        )
    if capability_id == "explain_result":
        return load_scenario_request_json(
            "scenarios/explain_result_local_pickup_weekend.json"
        )
    raise Error(
        "missing sample request for callable capability '" + capability_id + "'"
    )


def _failing_status_output() raises -> Value:
    raise Error("simulated test-only status builder failure")


def _test_manifest_path() raises -> Path:
    return _dir_of_current_file() / ".." / "pixi.toml"


def _parse_manifest_quoted_value(value: String) raises -> String:
    var trimmed = value.strip()
    if (
        trimmed.byte_length() < 2
        or not trimmed.startswith('"')
        or not trimmed.endswith('"')
    ):
        raise Error("manifest assignment value must be quoted")
    return String(trimmed[byte = 1 : trimmed.byte_length() - 1])


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
            String(line[byte = equals_index + 1 :])
        )

    raise Error("missing workspace manifest key '" + target_key + "'")


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _array_string_values(value: Value) raises -> List[String]:
    var items = List[String]()
    for item in value.array_items():
        items.append(item.string_value())
    return items^


def test_decode_request_parses_context_and_input() raises:
    var request = decode_request(
        '{"version":1,"request_id":"req-1","trace_id":"trace-1","capability":"query_rewrite","context":{"consumer":"radroots-cli","execution_mode_preference":"deterministic","deadline_ms":2500,"time_range":{"start":"2026-04-12","end":"2026-04-13"},"evidence_limit":5,"consistency":"default","return_provenance":true,"explain_plan":true},"input":{"query":"eggs'
        ' near me"}}'
    )

    assert_equal(request.version, 1)
    assert_equal(request.request_id, "req-1")
    assert_equal(request.trace_id.value(), "trace-1")
    assert_equal(request.capability, "query_rewrite")
    assert_equal(request.context.consumer, "radroots-cli")
    assert_equal(request.context.execution_mode_preference, "deterministic")
    assert_equal(request.context.deadline_ms, 2500)
    assert_equal(request.context.time_range.value().start, "2026-04-12")
    assert_equal(request.context.time_range.value().end, "2026-04-13")
    assert_equal(request.context.evidence_limit, 5)
    assert_equal(request.context.consistency, "default")
    assert_equal(request.context.return_provenance, True)
    assert_equal(request.context.explain_plan, True)
    assert_equal(request.input["query"].string_value(), "eggs near me")


def test_decode_request_rejects_unexpected_field() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-1","capability":"query_rewrite","input":{"query":"eggs"},"unexpected":true}'
        )


def test_decode_request_requires_input_object() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-no-input-1","capability":"query_rewrite"}'
        )

    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-bad-input-1","capability":"query_rewrite","input":"eggs"}'
        )


def test_decode_request_rejects_unknown_context_field() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-ctx-1","capability":"query_rewrite","context":{"planner":"strict"},"input":{"query":"eggs"}}'
        )


def test_decode_request_rejects_invalid_activated_context_field() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-ctx-2","capability":"query_rewrite","context":{"deadline_ms":0},"input":{"query":"eggs"}}'
        )


def test_decode_request_rejects_unsupported_scope_field() raises:
    with assert_raises():
        _ = decode_request(
            '{"version":1,"request_id":"req-scope-1","capability":"semantic_rank","context":{"scope":{"farm_ids":["farm-1"]}},"input":{"query":"eggs","candidates":[{"id":"lst_1","title":"Eggs","farm":"One'
            ' Farm","delivery":"pickup","distance_km":1.0,"freshness_minutes":5}]}}'
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
    assert_equal(build_identity.package_version, manifest_package_version)


def test_repo_local_fixture_manifest_declares_expected_scenarios() raises:
    assert_true(exists(fixture_manifest_path()))

    var manifest = load_fixture_manifest()
    assert_equal(
        manifest["fixture_namespace"].string_value(),
        "radroots-canonical-hyf-v1",
    )
    assert_equal(Int(manifest["schema_version"].int_value()), 1)
    assert_equal(manifest["family_kind"].string_value(), "wire_compatibility")
    assert_equal(manifest["transport"].string_value(), "stdio")
    assert_equal(
        manifest["request_framing"].string_value(),
        "newline_delimited_json",
    )
    assert_equal(
        manifest["family_role"].string_value(),
        "dependency_surface",
    )
    assert_equal(
        manifest["canonical_authority_path"].string_value(),
        "testing/fixtures/canonical/hyf/v1",
    )
    assert_equal(
        manifest["shared_scenario_sync_policy"].string_value(),
        "same_logical_workstream",
    )

    var scenario_files = _array_string_values(manifest["scenario_files"])
    assert_equal(len(scenario_files), 8)
    assert_equal(scenario_files[0], "scenarios/status_ok.json")
    assert_equal(
        scenario_files[7], "scenarios/query_rewrite_unexpected_field.json"
    )


def test_repo_local_fixture_loader_reads_all_mirrored_scenarios() raises:
    var manifest = load_fixture_manifest()
    assert_equal(
        manifest["fixture_namespace"].string_value(),
        "radroots-canonical-hyf-v1",
    )

    var status_scenario = load_fixture_scenario("scenarios/status_ok.json")
    assert_equal(status_scenario["fixture_id"].string_value(), "status_ok")
    assert_equal(
        status_scenario["request"]["capability"].string_value(),
        "sys.status",
    )
    assert_true(_has_key(status_scenario, "expected"))

    var rewrite_scenario = load_fixture_scenario(
        "scenarios/query_rewrite_local_pickup_weekend.json"
    )
    assert_equal(
        rewrite_scenario["fixture_id"].string_value(),
        "query_rewrite_local_pickup_weekend",
    )
    assert_equal(
        rewrite_scenario["request"]["capability"].string_value(),
        "query_rewrite",
    )
    assert_equal(
        rewrite_scenario["request"]["input"]["query"].string_value(),
        "apples near me with weekend pickup",
    )


def test_fixture_loader_reads_top_level_request_and_expected_structurally() raises:
    with TemporaryDirectory() as temp_dir:
        var scenario_path = Path(temp_dir) / "scenario.json"
        scenario_path.write_text(
            "{"
            + '"fixture_id":"shadowed-top-level-fields",'
            + '"description":"this description mentions request and expected'
            ' before the real fields",'
            + '"request":{"version":1,"request_id":"shadow-1","capability":"sys.status","input":{}},'
            + '"expected":{"ok":true,"equals":{"output.kind":"status"}}'
            + "}"
        )

        var scenario = load_fixture_json_file(scenario_path)
        var request = load_fixture_scenario_request("scenarios/status_ok.json")
        var expected = load_fixture_scenario_expected(
            "scenarios/status_ok.json"
        )
        var temp_request = load_fixture_top_level_field_from_path(
            scenario_path, "request"
        )
        var temp_expected = load_fixture_top_level_field_from_path(
            scenario_path, "expected"
        )

        assert_equal(
            scenario["fixture_id"].string_value(),
            "shadowed-top-level-fields",
        )
        assert_equal(
            temp_request["request_id"].string_value(),
            "shadow-1",
        )
        assert_equal(
            temp_request["capability"].string_value(),
            "sys.status",
        )
        assert_true(temp_expected["ok"].bool_value())
        assert_equal(
            temp_expected["equals"]["output.kind"].string_value(),
            "status",
        )
        assert_equal(request["capability"].string_value(), "sys.status")
        assert_true(expected["ok"].bool_value())


def test_status_reports_registered_deterministic_ready() raises:
    var result = _dispatch(
        load_scenario_request_json("scenarios/status_ok.json")
    )
    assert_matches_scenario_response(result, "scenarios/status_ok.json")


def test_capabilities_report_implemented_and_disabled_states() raises:
    var result = _dispatch(
        load_scenario_request_json("scenarios/capabilities_ok.json")
    )
    assert_matches_scenario_response(result, "scenarios/capabilities_ok.json")


def test_capabilities_output_reflects_registry_truth_for_all_business_capabilities() raises:
    var output = build_capabilities_output()
    for capability in canonical_business_capabilities():
        var entry = _capability_output_entry_by_id(output, capability.id)
        assert_equal(entry["id"].string_value(), capability.id)
        assert_equal(entry["implemented"].bool_value(), capability.implemented)
        assert_equal(entry["callable"].bool_value(), capability.callable)
        assert_equal(entry["assisted_backend_available"].bool_value(), False)
        assert_equal(
            entry["deterministic_execution"].string_value(),
            "enabled" if capability.deterministic_enabled else "disabled",
        )
        assert_equal(
            entry["implementation_status"].string_value(),
            "implemented" if capability.implemented else (
                "not_implemented" if capability.deterministic_enabled else "disabled"
            ),
        )
        if capability.disabled_reason != "":
            assert_equal(
                entry["disabled_reason"].string_value(),
                capability.disabled_reason,
            )
        else:
            assert_true(not _has_key(entry, "disabled_reason"))

    assert_equal(
        output["assisted_backend_capabilities"][0]["id"].string_value(),
        "hyf_assistd",
    )
    assert_equal(
        output["assisted_backend_capabilities"][0]["state"].string_value(),
        "disabled_by_runtime_config",
    )
    assert_equal(
        output["assisted_backend_capabilities"][0]["backend_kind"]
        .string_value(),
        "fake",
    )


def test_disabled_capability_returns_capability_disabled() raises:
    var result = _dispatch(
        load_scenario_request_json(
            "scenarios/deferred_capability_disabled.json"
        )
    )
    assert_matches_scenario_response(
        result, "scenarios/deferred_capability_disabled.json"
    )


def test_all_callable_registry_business_capabilities_are_dispatchable() raises:
    for capability in canonical_business_capabilities():
        if not capability.callable:
            continue
        var result = _dispatch(
            _sample_request_json_for_callable_capability(capability.id)
        )
        assert_equal(Int(result["version"].int_value()), 1)
        assert_equal(result["ok"].bool_value(), True)


def test_non_callable_registry_business_capabilities_do_not_route_as_success() raises:
    for capability in canonical_business_capabilities():
        if capability.callable:
            continue
        var result = _dispatch(
            '{"version":1,"request_id":"'
            + capability.id
            + '-routing-1","capability":"'
            + capability.id
            + '","input":{}}'
        )
        assert_equal(Int(result["version"].int_value()), 1)
        assert_equal(
            result["request_id"].string_value(), capability.id + "-routing-1"
        )
        assert_equal(result["ok"].bool_value(), False)
        assert_equal(
            result["error"]["code"].string_value(),
            "capability_disabled" if not capability.deterministic_enabled else "capability_unavailable",
        )


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
        load_scenario_request_json(
            "scenarios/query_rewrite_local_pickup_weekend.json"
        )
    )
    assert_matches_scenario_response(
        result, "scenarios/query_rewrite_local_pickup_weekend.json"
    )


def test_query_rewrite_accepts_query_alias_with_same_behavior() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rewrite-query-1","capability":"query_rewrite","input":{"query":"eggs'
        ' near me with weekend pickup"}}'
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
        load_scenario_request_json(
            "scenarios/query_rewrite_unexpected_field.json"
        )
    )
    assert_matches_scenario_response(
        result, "scenarios/query_rewrite_unexpected_field.json"
    )


def test_query_rewrite_rejects_text_and_query_together() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rewrite-bad-dual-1","capability":"query_rewrite","input":{"text":"eggs'
        ' near me","query":"eggs"}}'
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
        load_scenario_request_json(
            "scenarios/semantic_rank_local_pickup_weekend.json"
        )
    )
    assert_matches_scenario_response(
        result, "scenarios/semantic_rank_local_pickup_weekend.json"
    )


def test_semantic_rank_scope_listing_ids_remains_effective() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-scope-1","capability":"semantic_rank","context":{"scope":{"listing_ids":["lst_8k1p"]}},"input":{"query":"eggs","candidates":[{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_8k1p","title":"Free'
        ' range eggs","farm":"Santa'
        ' Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
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
        '{"version":1,"request_id":"rank-bad-top-1","capability":"semantic_rank","input":{"query":"eggs'
        ' near me","candidates":[{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2}],"tone":"brief"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rank-bad-top-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field") >= 0
    )


def test_semantic_rank_rejects_unknown_candidate_field() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-bad-candidate-1","capability":"semantic_rank","input":{"query":"eggs'
        ' near me","candidates":[{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rank-bad-candidate-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field") >= 0
    )


def test_semantic_rank_rejects_duplicate_candidate_ids() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-dup-1","capability":"semantic_rank","input":{"query":"eggs'
        ' near me","candidates":[{"id":"lst_dup","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_dup","title":"Free'
        ' range eggs","farm":"Santa'
        ' Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rank-dup-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("duplicate candidate id")
        >= 0
    )


def test_semantic_rank_rejects_invalid_delivery_value() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-bad-delivery-1","capability":"semantic_rank","input":{"query":"eggs'
        ' near me","candidates":[{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"ship","distance_km":3.2,"freshness_minutes":2}]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rank-bad-delivery-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("must be one of") >= 0
    )


def test_explain_result_returns_deterministic_summary_and_provenance() raises:
    var result = _dispatch(
        load_scenario_request_json(
            "scenarios/explain_result_local_pickup_weekend.json"
        )
    )
    assert_matches_scenario_response(
        result, "scenarios/explain_result_local_pickup_weekend.json"
    )


def test_explain_result_accepts_result_alias() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"explain-result-1","capability":"explain_result","input":{"query":"eggs'
        " near me with weekend"
        ' pickup","result":{"id":"lst_7ak2","title":"Pasture eggs","farm":"La'
        " Huerta del"
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2}}}'
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
        '{"version":1,"request_id":"explain-bad-top-1","capability":"explain_result","input":{"query":"eggs'
        ' near me","candidate":{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},"tone":"brief"}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "explain-bad-top-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field") >= 0
    )


def test_explain_result_rejects_unknown_candidate_field() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"explain-bad-candidate-1","capability":"explain_result","input":{"query":"eggs'
        ' near me","candidate":{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "explain-bad-candidate-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unexpected field") >= 0
    )


def test_explain_result_rejects_invalid_delivery_value() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"explain-bad-delivery-1","capability":"explain_result","input":{"query":"eggs'
        ' near me","candidate":{"id":"lst_7ak2","title":"Pasture'
        ' eggs","farm":"La Huerta del'
        ' Sur","delivery":"ship","distance_km":3.2,"freshness_minutes":2}}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "explain-bad-delivery-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("must be one of") >= 0
    )


def test_semantic_rank_invalid_input_returns_invalid_request() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"rank-bad-1","trace_id":"trace-rank-bad-1","capability":"semantic_rank","input":{"query":"eggs'
        ' near me with weekend pickup","candidates":[]}}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "rank-bad-1")
    assert_equal(result["trace_id"].string_value(), "trace-rank-bad-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("must not be empty") >= 0
    )


def test_missing_input_returns_invalid_request() raises:
    var result = _dispatch(
        '{"version":1,"request_id":"missing-input-1","trace_id":"trace-missing-input-1","capability":"query_rewrite"}'
    )

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["request_id"].string_value(), "missing-input-1")
    assert_equal(result["trace_id"].string_value(), "trace-missing-input-1")
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"]
        .string_value()
        .find("field 'input' is required")
        >= 0
    )


def test_assisted_request_returns_backend_unavailable() raises:
    var result = _dispatch(
        load_scenario_request_json(
            "scenarios/assisted_backend_unavailable.json"
        )
    )
    assert_matches_scenario_response(
        result, "scenarios/assisted_backend_unavailable.json"
    )


def test_invalid_request_preserves_request_and_trace_correlation() raises:
    var result = _dispatch(status_request_with_invalid_version_json())

    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["request_id"].string_value(), "status-fixture-1")
    assert_equal(result["trace_id"].string_value(), "trace-status-fixture-1")
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["error"]["code"].string_value(), "invalid_request")
    assert_true(
        result["error"]["message"].string_value().find("unsupported") >= 0
    )


def test_internal_error_is_bounded_on_wire() raises:
    with TemporaryDirectory() as temp_dir:
        var diagnostics_dir = Path(temp_dir) / "hyf-internal-diagnostics"
        with ScopedEnvVar(
            _HYF_DIAGNOSTICS_DIR_ENV, diagnostics_dir.__fspath__()
        ):
            var result = loads(
                handle_request_line_with_control_builders[
                    _failing_status_output, build_capabilities_output
                ](
                    '{"version":1,"request_id":"status-internal-1","trace_id":"trace-status-internal-1","capability":"sys.status","input":{}}'
                )
            )

            _assert_internal_error_is_bounded(result)


def _assert_internal_error_is_bounded(result: Value) raises:
    assert_equal(Int(result["version"].int_value()), 1)
    assert_equal(result["request_id"].string_value(), "status-internal-1")
    assert_equal(result["trace_id"].string_value(), "trace-status-internal-1")
    assert_equal(result["ok"].bool_value(), False)
    assert_equal(result["error"]["code"].string_value(), "internal_error")
    assert_equal(
        result["error"]["message"].string_value(),
        _EXPECTED_INTERNAL_ERROR_MESSAGE,
    )
    assert_true(
        result["error"]["message"].string_value().find("simulated test-only")
        < 0
    )


def test_internal_error_diagnostics_append_per_process() raises:
    with TemporaryDirectory() as temp_dir:
        var diagnostics_dir = Path(temp_dir) / "hyf-internal-diagnostics"

        with ScopedEnvVar(
            _HYF_DIAGNOSTICS_DIR_ENV, diagnostics_dir.__fspath__()
        ):
            _ = loads(
                handle_request_line_with_control_builders[
                    _failing_status_output, build_capabilities_output
                ](
                    '{"version":1,"request_id":"status-internal-diag-1","trace_id":"trace-status-internal-diag-1","capability":"sys.status","input":{}}'
                )
            )
            _ = loads(
                handle_request_line_with_control_builders[
                    _failing_status_output, build_capabilities_output
                ](
                    '{"version":1,"request_id":"status-internal-diag-2","trace_id":"trace-status-internal-diag-2","capability":"sys.status","input":{}}'
                )
            )

            assert_true(exists(diagnostics_dir))
            var entries = std.os.listdir(diagnostics_dir)
            assert_equal(len(entries), 1)
            assert_true(entries[0].startswith("hyf-internal-error-pid-"))

            var content = (diagnostics_dir / entries[0]).read_text()
            var lines = content.splitlines()
            assert_equal(len(lines), 2)
            assert_true(
                content.find('request_id="status-internal-diag-1"') >= 0
            )
            assert_true(
                content.find('request_id="status-internal-diag-2"') >= 0
            )
            assert_true(
                content.find(
                    'detail="simulated test-only status builder failure"'
                )
                >= 0
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
