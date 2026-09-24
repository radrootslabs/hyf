import std.os
from std.os.path import exists
from std.pathlib import Path, _dir_of_current_file
from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)
from safe_tempdir import SafeTempDir

from json import Value, dumps, loads, validate

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
from fixture_validator import validate_fixture_corpus
from projection_assertions import assert_projection
from hyf_core.backends.selector import (
    execute_capability as execute_core_capability,
    resolve_backend,
)
from hyf_core.capabilities.registry import canonical_business_capabilities
from hyf_core.metadata import current_build_identity, current_package_surface
from hyf_core.request_context import (
    default_request_context,
)
from hyf_stdio.control.capabilities import build_capabilities_output
from hyf_stdio.codec import decode_request, encode_error, encode_success
from hyf_stdio.envelope import WireErrorResponse, WireSuccessResponse
from hyf_stdio.errors import WireError
from hyf_runtime.startup import (
    RuntimeStartupContext,
    RuntimeStartupInput,
    resolve_startup_context,
)
from hyf_stdio.server import (
    handle_request_line_with_runtime_context,
)
from stdio_process_helper import run_stdio_entrypoint


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
    with SafeTempDir() as temp_dir:
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
    with SafeTempDir() as temp_dir:
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
        output["provider_runtime_capabilities"][0]["id"].string_value(),
        "hyf_provider_runtime",
    )
    assert_equal(
        output["provider_runtime_capabilities"][0]["kind"].string_value(),
        "provider_runtime",
    )
    assert_equal(
        output["provider_runtime_capabilities"][0]["transport"].string_value(),
        "deferred",
    )
    assert_equal(
        output["provider_runtime_capabilities"][0]["state"].string_value(),
        "disabled_by_runtime_config",
    )
    assert_equal(
        output["provider_runtime_capabilities"][0][
            "backend_kind"
        ].string_value(),
        "deferred",
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


def test_backend_selector_routes_assisted_preference_to_deterministic_fallback() raises:
    var context = default_request_context()
    context.execution_mode_preference = "assisted"

    var selection = resolve_backend(context)
    assert_equal(selection.backend_name, "heuristic")
    assert_equal(selection.available, True)

    var result = execute_core_capability(
        "query_rewrite",
        loads('{"text":"eggs near me"}'),
        context,
    )

    assert_true(result.success)
    assert_equal(
        result.success.value().meta.value().execution_mode,
        "deterministic",
    )
    assert_equal(result.success.value().meta.value().backend, "heuristic")


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


def test_assisted_request_falls_back_deterministically_when_provider_is_unavailable() raises:
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
    with SafeTempDir() as temp_dir:
        var diagnostics_dir = Path(temp_dir) / "hyf-internal-diagnostics"
        with ScopedEnvVar(
            _HYF_DIAGNOSTICS_DIR_ENV, diagnostics_dir.__fspath__()
        ):
            var result = run_stdio_entrypoint(
                "tests/internal_error_stdio_main.mojo",
                '{"version":1,"request_id":"status-internal-1","trace_id":"trace-status-internal-1","capability":"sys.status","input":{}}',
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


def test_internal_error_diagnostics_records_detail() raises:
    with SafeTempDir() as temp_dir:
        var diagnostics_dir = Path(temp_dir) / "hyf-internal-diagnostics"

        with ScopedEnvVar(
            _HYF_DIAGNOSTICS_DIR_ENV, diagnostics_dir.__fspath__()
        ):
            _ = run_stdio_entrypoint(
                "tests/internal_error_stdio_main.mojo",
                '{"version":1,"request_id":"status-internal-diag-1","trace_id":"trace-status-internal-diag-1","capability":"sys.status","input":{}}',
            )

            assert_true(exists(diagnostics_dir))
            var entries = std.os.listdir(diagnostics_dir)
            assert_equal(len(entries), 1)
            assert_true(entries[0].startswith("hyf-internal-error-pid-"))

            var content = (diagnostics_dir / entries[0]).read_text()
            var lines = content.splitlines()
            assert_equal(len(lines), 1)
            assert_true(
                content.find('request_id="status-internal-diag-1"') >= 0
            )
            assert_true(
                content.find(
                    'detail="simulated test-only status builder failure"'
                )
                >= 0
            )


def test_semantic_fixture_manifest_declares_repo_local_family() raises:
    var manifest_path = (
        _dir_of_current_file() / "fixtures" / "hyf_v1_jev" / "manifest.json"
    )
    assert_true(exists(manifest_path))
    var manifest = loads(manifest_path.read_text())
    assert_equal(
        manifest["fixture_namespace"].string_value(),
        "radroots-hyf-v1-jev-semantic",
    )
    assert_equal(Int(manifest["schema_version"].int_value()), 1)
    assert_equal(manifest["family_kind"].string_value(), "semantic_acceptance")
    assert_equal(manifest["family_role"].string_value(), "hyf_local")
    assert_equal(manifest["transport"].string_value(), "stdio")
    assert_equal(
        manifest["request_framing"].string_value(), "newline_delimited_json"
    )
    assert_equal(
        manifest["shared_wire_authority"]["declared_path"].string_value(),
        "testing/fixtures/canonical/hyf/v1",
    )
    assert_equal(
        manifest["shared_wire_authority"][
            "local_offline_mirror"
        ].string_value(),
        "tests/fixtures/v1",
    )
    assert_equal(
        manifest["repo_local_families"]["domain"].string_value(),
        "tests/fixtures/hyf_v1_jev/domain",
    )
    assert_equal(manifest["installation_status"].string_value(), "installed")
    assert_equal(Int(manifest["declared_case_count"].int_value()), 116)
    assert_equal(Int(manifest["declared_raw_payload_count"].int_value()), 5)


def _wire_schema_path(name: String) raises -> Path:
    return _dir_of_current_file() / ".." / "schemas" / "hyf_v1_jev" / name


def _wire_schema_json(name: String) raises -> Value:
    return loads(_wire_schema_path(name).read_text())


def test_wire_operation_schemas_accept_valid_and_reject_invalid() raises:
    var manifest = _wire_schema_json("manifest.json")
    assert_equal(manifest["schema_version"].int_value(), 1)
    assert_equal(manifest["spec_id"].string_value(), "hyf_v1_jev")

    var validated = 0
    for binding in manifest["bindings"].array_items():
        if _has_key(binding, "request_schema"):
            var request_schema_name = binding["request_schema"].string_value()
            var request_valid = binding["request_valid"].string_value()
            var request_schema = _wire_schema_json(request_schema_name)
            var request_doc = loads(
                (
                    _dir_of_current_file()
                    / ".."
                    / "schemas"
                    / "hyf_v1_jev"
                    / request_valid
                ).read_text()
            )
            assert_true(
                validate(request_doc, request_schema).valid,
                "request example failed schema: " + request_valid,
            )
            validated += 1

            if _has_key(binding, "request_invalid"):
                var invalid_doc = loads(
                    (
                        _dir_of_current_file()
                        / ".."
                        / "schemas"
                        / "hyf_v1_jev"
                        / binding["request_invalid"].string_value()
                    ).read_text()
                )
                assert_true(
                    not validate(invalid_doc, request_schema).valid,
                    "invalid request example unexpectedly passed schema",
                )

        if _has_key(binding, "response_schema"):
            var response_schema = _wire_schema_json(
                binding["response_schema"].string_value()
            )
            var response_doc = loads(
                (
                    _dir_of_current_file()
                    / ".."
                    / "schemas"
                    / "hyf_v1_jev"
                    / binding["response_valid"].string_value()
                ).read_text()
            )
            assert_true(
                validate(response_doc, response_schema).valid,
                "response example failed schema",
            )
            validated += 1

            if _has_key(binding, "response_invalid"):
                var invalid_response = loads(
                    (
                        _dir_of_current_file()
                        / ".."
                        / "schemas"
                        / "hyf_v1_jev"
                        / binding["response_invalid"].string_value()
                    ).read_text()
                )
                assert_true(
                    not validate(invalid_response, response_schema).valid,
                    "invalid response example unexpectedly passed schema",
                )

    assert_true(validated >= 6)


def _assert_manifest_examples(
    manifest_name: String, expected_valid: Int
) raises:
    var manifest = _wire_schema_json(manifest_name)
    assert_equal(manifest["spec_id"].string_value(), "hyf_v1_jev")
    var valid_count = 0
    for binding in manifest["bindings"].array_items():
        var schema = _wire_schema_json(binding["schema"].string_value())
        for rel in binding["valid"].array_items():
            var doc = loads(
                (
                    _dir_of_current_file()
                    / ".."
                    / "schemas"
                    / "hyf_v1_jev"
                    / rel.string_value()
                ).read_text()
            )
            assert_true(
                validate(doc, schema).valid,
                "valid example failed schema: " + rel.string_value(),
            )
            valid_count += 1
        for rel in binding["invalid"].array_items():
            var doc = loads(
                (
                    _dir_of_current_file()
                    / ".."
                    / "schemas"
                    / "hyf_v1_jev"
                    / rel.string_value()
                ).read_text()
            )
            assert_true(
                not validate(doc, schema).valid,
                "invalid example unexpectedly passed: " + rel.string_value(),
            )
    assert_equal(valid_count, expected_valid)


def test_domain_representation_schemas_accept_valid_and_reject_invalid() raises:
    _assert_manifest_examples("domain_manifest.json", 5)


def test_temporal_evidence_schemas_accept_valid_and_reject_invalid() raises:
    _assert_manifest_examples("temporal_manifest.json", 7)


def _outcome_is_contradictory(doc: Value) raises -> Bool:
    var eligibility = doc["eligibility"].string_value()
    var mandatory_fail = False
    var mandatory_unknown = False
    for check in doc["checks"].array_items():
        var result = check["result"].string_value()
        if check["mandatory"].bool_value():
            if result == "fail":
                mandatory_fail = True
            elif result == "unknown":
                mandatory_unknown = True
    if mandatory_fail and eligibility != "ineligible":
        return True
    if not mandatory_fail and mandatory_unknown and eligibility == "eligible":
        return True
    return False


def test_outcome_composition_rejects_contradictions() raises:
    _assert_manifest_examples("outcome_manifest.json", 3)
    var manifest = _wire_schema_json("outcome_manifest.json")
    for binding in manifest["bindings"].array_items():
        var schema = _wire_schema_json(binding["schema"].string_value())
        for rel in binding["valid"].array_items():
            var doc = loads(
                (
                    _dir_of_current_file()
                    / ".."
                    / "schemas"
                    / "hyf_v1_jev"
                    / rel.string_value()
                ).read_text()
            )
            assert_true(validate(doc, schema).valid)
            assert_true(
                not _outcome_is_contradictory(doc),
                "valid outcome treated as contradictory: " + rel.string_value(),
            )
        for rel in binding["semantic_invalid"].array_items():
            var doc = loads(
                (
                    _dir_of_current_file()
                    / ".."
                    / "schemas"
                    / "hyf_v1_jev"
                    / rel.string_value()
                ).read_text()
            )
            assert_true(
                validate(doc, schema).valid,
                "semantic-invalid example must remain structurally valid",
            )
            assert_true(
                _outcome_is_contradictory(doc),
                "contradictory outcome not detected: " + rel.string_value(),
            )


def test_semantic_fixture_corpus_is_installed_and_planned() raises:
    var fixture_dir = _dir_of_current_file() / "fixtures" / "hyf_v1_jev"
    var manifest = loads((fixture_dir / "manifest.json").read_text())
    assert_equal(manifest["installation_status"].string_value(), "installed")
    assert_equal(manifest["family_kind"].string_value(), "semantic_acceptance")

    var cases = manifest["cases"].array_items()
    assert_equal(len(cases), 116)
    for entry in cases:
        assert_true(entry["mandatory"].bool_value())
        var case_path = fixture_dir / entry["path"].string_value()
        assert_true(
            exists(case_path), "missing case: " + entry["path"].string_value()
        )
        var doc = loads(case_path.read_text())
        assert_equal(
            doc["case_id"].string_value(), entry["case_id"].string_value()
        )
        assert_equal(doc["implementation_status"].string_value(), "planned")
        assert_equal(
            doc["required_from_step"].string_value(),
            entry["required_from_step"].string_value(),
        )
        assert_true(len(doc["requirements"].array_items()) > 0)
        assert_true(_has_key(doc, "provenance"))
        assert_true(len(doc["then"].array_items()) > 0)

    var raw_files = manifest["raw_files"].array_items()
    assert_equal(len(raw_files), 5)
    for raw in raw_files:
        assert_true(exists(fixture_dir / raw.string_value()))


def _write_min_fixture_corpus(base: Path, mutation: String) raises:
    var domain = base / "domain"
    std.os.makedirs(domain.__fspath__(), exist_ok=True)
    var case_text = (
        '{"fixture_format_version":1,"case_id":"T001",'
        '"requirements":["HYF-TEST-001"],"implementation_status":"planned",'
        '"required_from_step":"S009","mandatory":true,"given":{},'
        '"provider_script":[],'
        '"then":[{"operator":"equals","path":"/x","value":1}],'
        '"provenance":{"kind":"synthetic"}}'
    )
    if mutation == "unknown_operator":
        case_text = case_text.replace('"equals"', '"not_registered"')
    elif mutation == "empty_then":
        case_text = case_text.replace(
            '[{"operator":"equals","path":"/x","value":1}]', "[]"
        )
    elif mutation == "missing_provenance":
        case_text = case_text.replace(',"provenance":{"kind":"synthetic"}', "")
    elif mutation == "empty_requirements":
        case_text = case_text.replace('["HYF-TEST-001"]', "[]")
    (domain / "T001.json").write_text(case_text)

    var case_entry = (
        '{"case_id":"T001","path":"domain/T001.json",'
        '"required_from_step":"S009","mandatory":true}'
    )
    if mutation == "duplicate_case_id":
        case_entry = case_entry + "," + case_entry
    elif mutation == "dangling_path":
        case_entry = (
            '{"case_id":"T001","path":"domain/missing.json",'
            '"required_from_step":"S009","mandatory":true}'
        )
    elif mutation == "activation_step_mismatch":
        case_entry = (
            '{"case_id":"T001","path":"domain/T001.json",'
            '"required_from_step":"S999","mandatory":true}'
        )
    var manifest = (
        '{"schema_version":1,"spec_id":"hyf_v1_jev",'
        '"installation_status":"installed","cases":['
        + case_entry
        + '],"raw_files":[]}'
    )
    (base / "manifest.json").write_text(manifest)


def test_fixture_validator_accepts_corpus_and_rejects_corruptions() raises:
    var corpus_dir = _dir_of_current_file() / "fixtures" / "hyf_v1_jev"
    assert_equal(len(validate_fixture_corpus(corpus_dir.__fspath__())), 0)
    var mutations = List[String]()
    mutations.append("duplicate_case_id")
    mutations.append("dangling_path")
    mutations.append("unknown_operator")
    mutations.append("empty_then")
    mutations.append("missing_provenance")
    mutations.append("empty_requirements")
    mutations.append("activation_step_mismatch")
    for mutation in mutations:
        with SafeTempDir() as temp_dir:
            var base = Path(temp_dir)
            _write_min_fixture_corpus(base, mutation)
            assert_true(
                len(validate_fixture_corpus(base.__fspath__())) > 0,
                "validator accepted corruption: " + mutation,
            )


def test_projection_assertions_enforce_exactness_and_reject_unknown_operators() raises:
    var actual = loads(
        '{"assessment":{"eligibility":"eligible"},'
        '"plans":[{"plan_id":"p1","allocations":[{"lot_id":"lot-1",'
        '"revision":"l1","quantity":30}]}],'
        '"execution":{"hyf_business_writes":0}}'
    )
    var passing = List[Value]()
    passing.append(
        loads(
            '{"operator":"equals","path":"/assessment/eligibility","value":"eligible"}'
        )
    )
    passing.append(
        loads('{"operator":"absent","path":"/assessment/failed_checks"}')
    )
    passing.append(
        loads(
            '{"operator":"contains","path":"/plans/0/allocations","value":{"lot_id":"lot-1","revision":"l1","quantity":30}}'
        )
    )
    passing.append(
        loads(
            '{"operator":"tolerance","path":"/plans/0/allocations/0/quantity","value":30,"tolerance":0}'
        )
    )
    assert_projection(actual, passing)

    var wrong_value = List[Value]()
    wrong_value.append(
        loads(
            '{"operator":"equals","path":"/assessment/eligibility","value":"ineligible"}'
        )
    )
    with assert_raises():
        assert_projection(actual, wrong_value)

    var missing_revision = List[Value]()
    missing_revision.append(
        loads(
            '{"operator":"present","path":"/plans/0/allocations/0/expected_revision"}'
        )
    )
    with assert_raises():
        assert_projection(actual, missing_revision)

    var wrong_order = List[Value]()
    wrong_order.append(
        loads(
            '{"operator":"equals","path":"/plans/0/allocations/0","value":{"lot_id":"lot-2","revision":"l1","quantity":30}}'
        )
    )
    with assert_raises():
        assert_projection(actual, wrong_order)

    var out_of_tolerance = List[Value]()
    out_of_tolerance.append(
        loads(
            '{"operator":"tolerance","path":"/plans/0/allocations/0/quantity","value":31,"tolerance":0}'
        )
    )
    with assert_raises():
        assert_projection(actual, out_of_tolerance)

    var unknown_operator = List[Value]()
    unknown_operator.append(
        loads(
            '{"operator":"approximately","path":"/assessment/eligibility","value":"eligible"}'
        )
    )
    with assert_raises():
        assert_projection(actual, unknown_operator)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_core.capabilities.registry import (
    capability_assisted_supported,
    capability_exposure,
)


def test_capability_exposure_separates_support_permission_readiness() raises:
    assert_true(capability_assisted_supported("query_rewrite"))
    assert_true(not capability_assisted_supported("semantic_rank"))
    var supported_but_blocked = capability_exposure(
        "query_rewrite", False, True, False
    )
    assert_true(supported_but_blocked.implementation_supported)
    assert_true(not supported_but_blocked.provider_configured)
    assert_true(not supported_but_blocked.exposed)
    var fully_ready = capability_exposure("query_rewrite", True, True, True)
    assert_true(fully_ready.exposed)
    var permission_denied = capability_exposure(
        "query_rewrite", True, False, True
    )
    assert_true(not permission_denied.exposed)


from hyf_core.capabilities.registry import (
    gated_operation_descriptors,
    gated_operation_is_exposed,
)


def test_gated_operation_descriptors_are_prepared_not_exposed() raises:
    var descriptors = gated_operation_descriptors()
    assert_equal(len(descriptors), 3)
    for descriptor in descriptors:
        assert_true(not descriptor.exposed)
    assert_true(not gated_operation_is_exposed("farm_update.interpret", False))
    assert_true(gated_operation_is_exposed("buyer_request.match", True))
    assert_true(not gated_operation_is_exposed("query_rewrite", True))


# ── H009 strict JSON boundary characterization (current behavior) ────────────


def test_strict_json_boundary_characterizes_duplicate_keys() raises:
    # H009: pin the current duplicate-key behavior without declaring the final
    # policy. The shared decoder accepts a repeated key, preserves every entry
    # and resolves lookup to the first occurrence; a type-conflicting duplicate
    # is likewise not rejected.
    var value = loads('{"n":1,"m":2,"n":3}')
    assert_equal(value.object_count(), 3)
    assert_equal(value["n"].int_value(), 1)
    assert_equal(dumps(value), '{"n":1,"m":2,"n":3}')
    var conflicting = loads('{"n":1,"n":"x"}')
    assert_equal(conflicting.object_count(), 2)
    assert_equal(conflicting["n"].int_value(), 1)


def test_strict_json_boundary_characterizes_numeric_and_null_values() raises:
    # H009: current int_value() performs no type check. Exponents, floats, null
    # and out-of-range integers decode to 0, and a string/bool/array value is
    # interpreted without a type error. Pinned as current behavior, not as an
    # approved contract.
    var exponent = loads('{"n":1e2}')
    assert_equal(exponent["n"].int_value(), 0)
    var fractional = loads('{"n":1.5}')
    assert_equal(fractional["n"].int_value(), 0)
    var null_value = loads('{"n":null}')
    assert_equal(null_value["n"].int_value(), 0)
    var overflow = loads('{"n":9223372036854775808}')
    assert_equal(overflow["n"].int_value(), 0)
    var negative = loads('{"n":-1}')
    assert_equal(negative["n"].int_value(), -1)
    var plain = loads('{"n":7}')
    assert_equal(plain["n"].int_value(), 7)
    var string_value = loads('{"n":"7"}')
    assert_true(string_value["n"].int_value() != 7)
    var boolean = loads('{"n":true}')
    assert_equal(boolean["n"].int_value(), 1)
    var array = loads('{"n":[1,2]}')
    assert_true(array["n"].int_value() != 0)


def test_strict_json_boundary_accepts_invalid_utf8_in_a_string() raises:
    # H009: the shared decoder currently accepts a string value that contains
    # invalid UTF-8 bytes instead of rejecting the document.
    var bytes = List[UInt8]()
    for byte in '{"s":"'.as_bytes():
        bytes.append(UInt8(Int(byte)))
    bytes.append(255)
    bytes.append(254)
    for byte in '"}'.as_bytes():
        bytes.append(UInt8(Int(byte)))
    var raw = String(
        unsafe_from_utf8=Span(ptr=bytes.unsafe_ptr(), length=len(bytes))
    )
    var value = loads(raw)
    assert_equal(value.object_count(), 1)
    assert_true(_has_key(value, "s"))


def test_stdio_envelope_boundary_characterizes_duplicate_keys() raises:
    # H009: the stdio request envelope currently accepts duplicated envelope
    # and input keys and resolves each to its first occurrence.
    var envelope = decode_request(
        '{"version":1,"version":2,"request_id":"a","request_id":"b",'
        '"capability":"query_rewrite","input":{"query":"eggs","query":"milk"}}'
    )
    assert_equal(envelope.version, 1)
    assert_equal(envelope.request_id, "a")
    assert_equal(envelope.input["query"].string_value(), "eggs")


def test_stdio_envelope_boundary_rejects_null_and_numeric_fields() raises:
    # H009: required envelope fields carry bounded, type-checked rejections for
    # null, a non-integer number, a non-string and a missing field.
    var cases = List[String]()
    cases.append(
        '{"version":null,"request_id":"a","capability":"query_rewrite",'
        '"input":{"query":"eggs"}}'
    )
    cases.append(
        '{"version":1.5,"request_id":"a","capability":"query_rewrite",'
        '"input":{"query":"eggs"}}'
    )
    cases.append(
        '{"request_id":"a","capability":"query_rewrite","input":{"query":"eggs"}}'
    )
    cases.append(
        '{"version":1,"request_id":7,"capability":"query_rewrite",'
        '"input":{"query":"eggs"}}'
    )
    cases.append(
        '{"version":1,"request_id":"a","capability":null,'
        '"input":{"query":"eggs"}}'
    )
    var messages = List[String]()
    for index in range(len(cases)):
        var message = ""
        try:
            _ = decode_request(cases[index])
        except e:
            message = String(e)
        messages.append(message)
    assert_true(messages[0].find("must be an integer") >= 0)
    assert_true(messages[1].find("must be an integer") >= 0)
    assert_true(messages[2].find("'version' is required") >= 0)
    assert_true(messages[3].find("not a string") >= 0)
    assert_true(messages[4].find("not a string") >= 0)


# ADR-0025 D45 C004: strict hyf_ops_v2 capability context and pre-activation guard.
from hyf_core.operation_context import (
    corrected_operation_activation_enabled,
    is_corrected_operation,
    operation_context_selects_v2,
)
from hyf_runtime.config import operation_enabled as _operation_enabled


def _v2_versions_json() -> String:
    return (
        '"versions":{"schema":"hyf_ops_v2",'
        '"taxonomy":"hyf_ops_v2.taxonomy.v1",'
        '"normalization":"hyf_ops_v2.normalization.v1",'
        '"review_policy":"hyf_ops_v2.review_policy.v1",'
        '"ranking_policy":"hyf_ops_v2.ranking_policy.v1",'
        '"question_bundle":"hyf_ops_v2.question_bundle.v1",'
        '"model":"jev-1.13.0"}'
    )


def _v2_farm_references_json() -> String:
    return (
        '"references":{"taxonomy":{"version":"hyf_ops_v2.taxonomy.v1",'
        '"provenance":"host_supplied","products":['
        '{"catalogue_id":"tomato.roma","terms":["Roma tomatoes"]}]},'
        '"normalization":{"version":"hyf_ops_v2.normalization.v1",'
        '"provenance":"host_supplied","units":[{"unit":"lb","dimension":"mass"}],'
        '"conversions":[],"packs":[]}}'
    )


def _v2_farm_source_json() -> String:
    return (
        '"source":{"source_id":"s1","revision":"r1",'
        '"text":"80 lb of Roma tomatoes",'
        '"source_time":"2026-09-24T08:30:00-07:00",'
        '"timezone":"America/Vancouver","actor_id":"farm-1","farm_id":"farm-1"}'
    )


def _v2_farm_request() -> String:
    return (
        '{"version":1,"request_id":"v2-farm-1",'
        '"capability":"farm_update.interpret",'
        '"context":{"consumer":"radroots-cli",'
        '"execution_mode_preference":"deterministic","deadline_ms":2500,'
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        '"timezone":"America/Vancouver","locale":"en-CA",'
        + _v2_versions_json()
        + ',"return_provenance":true,"actor_id":"farm-1","farm_id":"farm-1"},'
        '"input":{'
        + _v2_farm_source_json()
        + ","
        + _v2_farm_references_json()
        + "}}"
    )


def _v2_farm_request_with_context(context_body: String) -> String:
    return (
        '{"version":1,"request_id":"v2-farm-variant",'
        '"capability":"farm_update.interpret","context":{'
        + context_body
        + '},"input":{'
        + _v2_farm_source_json()
        + ","
        + _v2_farm_references_json()
        + "}}"
    )


def _decode_error_message(line: String) -> String:
    try:
        _ = decode_request(line)
    except e:
        return String(e)
    return ""


def test_c004_corrected_operation_registry_and_activation_boundary() raises:
    assert_true(is_corrected_operation("farm_update.interpret"))
    assert_true(is_corrected_operation("buyer_request.interpret"))
    assert_true(is_corrected_operation("buyer_request.match"))
    assert_true(not is_corrected_operation("query_rewrite"))
    # C042-C046 own activation; C004 binds the guard but never activates.
    assert_true(not corrected_operation_activation_enabled())


def test_c004_decode_request_parses_operation_v2_context() raises:
    var request = decode_request(_v2_farm_request())
    assert_equal(request.capability, "farm_update.interpret")
    assert_true(request.operation_context)
    var context = request.operation_context.value().copy()
    assert_equal(context.consumer, "radroots-cli")
    assert_equal(context.execution_mode_preference, "deterministic")
    assert_equal(context.deadline_ms, 2500)
    assert_equal(context.evaluation_time, "2026-09-24T09:00:00-07:00")
    assert_equal(context.timezone.value(), "America/Vancouver")
    assert_equal(context.locale.value(), "en-CA")
    assert_equal(context.return_provenance, True)
    assert_equal(context.actor_id, "farm-1")
    assert_equal(context.farm_id.value(), "farm-1")
    assert_equal(context.versions.schema, "hyf_ops_v2")
    assert_equal(context.versions.taxonomy, "hyf_ops_v2.taxonomy.v1")
    assert_equal(context.versions.normalization, "hyf_ops_v2.normalization.v1")
    assert_equal(context.versions.review_policy, "hyf_ops_v2.review_policy.v1")
    assert_equal(
        context.versions.ranking_policy, "hyf_ops_v2.ranking_policy.v1"
    )
    assert_equal(
        context.versions.question_bundle, "hyf_ops_v2.question_bundle.v1"
    )
    assert_equal(context.versions.model, "jev-1.13.0")


def test_c004_operation_v2_context_defaults_are_not_host_guesses() raises:
    var request = decode_request(
        _v2_farm_request_with_context(
            '"evaluation_time":"2026-09-24T09:00:00-07:00",'
            + _v2_versions_json()
            + ',"actor_id":"farm-1","farm_id":"farm-1"'
        )
    )
    assert_true(request.operation_context)
    var context = request.operation_context.value().copy()
    assert_equal(context.consumer, "unknown")
    assert_equal(context.execution_mode_preference, "deterministic")
    assert_equal(context.deadline_ms, 2500)
    assert_equal(context.return_provenance, False)
    # Absent timezone/locale stay unknown; they are not filled from the host clock.
    assert_true(not context.timezone)
    assert_true(not context.locale)


def test_c004_operation_v2_context_is_strict() raises:
    var missing_actor = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(missing_actor).find("actor_id") >= 0)

    var duplicate_actor = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","actor_id":"farm-2","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(duplicate_actor).find("duplicate") >= 0)

    var missing_farm = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1"'
    )
    assert_true(_decode_error_message(missing_farm).find("farm_id") >= 0)

    var null_timezone = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00","timezone":null,'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(null_timezone).find("string") >= 0)

    var unknown_field = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00","planner":"strict",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(unknown_field).find("unexpected") >= 0)

    var empty_actor = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(empty_actor).find("actor_id") >= 0)


def test_c004_operation_v2_versions_are_closed_and_complete() raises:
    var incomplete = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00","versions":{'
        '"schema":"hyf_ops_v2","taxonomy":"t","normalization":"n",'
        '"review_policy":"r","ranking_policy":"k","model":"jev-1.13.0"},'
        '"actor_id":"farm-1","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(incomplete).find("question_bundle") >= 0)

    var unknown_axis = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00","versions":{'
        '"schema":"hyf_ops_v2","taxonomy":"t","normalization":"n",'
        '"review_policy":"r","ranking_policy":"k","question_bundle":"q",'
        '"model":"jev-1.13.0","extra":"x"},'
        '"actor_id":"farm-1","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(unknown_axis).find("unexpected") >= 0)


def test_c004_operation_v2_buyer_forbids_farm_identity() raises:
    var buyer_with_farm = (
        '{"version":1,"request_id":"v2-buyer-farm",'
        '"capability":"buyer_request.interpret",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"buyer-7","farm_id":"farm-1"},'
        '"input":{"source":{"source_id":"s1","revision":"r1","text":"25 lb",'
        '"source_time":"2026-09-24T08:45:00-07:00","actor_id":"buyer-7"},'
        + _v2_farm_references_json()
        + "}}"
    )
    assert_true(_decode_error_message(buyer_with_farm).find("unexpected") >= 0)

    var buyer_ok = (
        '{"version":1,"request_id":"v2-buyer-ok",'
        '"capability":"buyer_request.interpret",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"buyer-7"},'
        '"input":{"source":{"source_id":"s1","revision":"r1","text":"25 lb",'
        '"source_time":"2026-09-24T08:45:00-07:00","actor_id":"buyer-7"},'
        + _v2_farm_references_json()
        + "}}"
    )
    var request = decode_request(buyer_ok)
    assert_true(request.operation_context)
    assert_true(not request.operation_context.value().copy().farm_id)
    assert_equal(request.operation_context.value().copy().actor_id, "buyer-7")


def test_c004_selector_detection_does_not_broaden_legacy_context() raises:
    var context = loads("{}")
    context.set("versions", loads('{"schema":"hyf_ops_v2"}'))
    assert_true(operation_context_selects_v2(context))
    assert_true(not operation_context_selects_v2(loads('{"consumer":"cli"}')))
    assert_true(
        not operation_context_selects_v2(
            loads('{"versions":{"schema":"hyf_ops_v3"}}')
        )
    )
    assert_true(not operation_context_selects_v2(loads('{"versions":1}')))

    # An unrelated capability keeps the unchanged legacy admission and rejects
    # the advertised-but-unsupported `versions` field.
    var legacy_with_versions = (
        '{"version":1,"request_id":"legacy-versions",'
        '"capability":"query_rewrite","context":{'
        + _v2_versions_json()
        + '},"input":{"query":"eggs"}}'
    )
    assert_true(
        _decode_error_message(legacy_with_versions).find("unexpected") >= 0
    )

    # The unchanged legacy envelope still parses its original context.
    var legacy_request = decode_request(
        '{"version":1,"request_id":"legacy-ok","capability":"query_rewrite",'
        '"context":{"consumer":"radroots-cli","deadline_ms":2500},'
        '"input":{"query":"eggs"}}'
    )
    assert_true(not legacy_request.operation_context)
    assert_equal(legacy_request.context.consumer, "radroots-cli")


def test_c004_operation_v2_guard_blocks_shortcut_even_when_enabled() raises:
    with SafeTempDir() as temp_dir:
        var runtime_context = resolve_startup_context(
            RuntimeStartupInput(
                env_paths_profile="repo_local",
                env_repo_local_base_root=temp_dir,
                user_home="/home/unused",
                argv=List[String](),
            )
        )
        runtime_context.config.effective.runtime.enable_farm_update_interpret = (
            True
        )
        assert_true(
            _operation_enabled(runtime_context.config, "farm_update.interpret")
        )
        var response = loads(
            handle_request_line_with_runtime_context(
                _v2_farm_request(), runtime_context
            )
        )
        assert_equal(response["ok"].bool_value(), False)
        assert_equal(
            response["error"]["code"].string_value(), "capability_unavailable"
        )
        # Never the placeholder shortcut output, and zero provider calls.
        assert_true(not _has_key(response, "output"))


def test_c004_legacy_gated_operation_still_executes_when_enabled() raises:
    with SafeTempDir() as temp_dir:
        var runtime_context = resolve_startup_context(
            RuntimeStartupInput(
                env_paths_profile="repo_local",
                env_repo_local_base_root=temp_dir,
                user_home="/home/unused",
                argv=List[String](),
            )
        )
        runtime_context.config.effective.runtime.enable_farm_update_interpret = (
            True
        )
        var legacy = (
            '{"version":1,"request_id":"legacy-farm-1",'
            '"capability":"farm_update.interpret","input":{'
            + _v2_farm_source_json()
            + "}}"
        )
        var response = loads(
            handle_request_line_with_runtime_context(legacy, runtime_context)
        )
        assert_equal(response["ok"].bool_value(), True)
        assert_true(_has_key(response["output"], "claims"))


def test_c004_v2_schema_assets_and_manifest_integrity() raises:
    var schema_dir = _dir_of_current_file() / ".." / "schemas" / "hyf_ops_v2"
    var manifest = loads((schema_dir / "manifest.json").read_text())
    assert_equal(manifest["selector"]["value"].string_value(), "hyf_ops_v2")
    assert_equal(Int(manifest["envelope_version"].int_value()), 1)
    assert_equal(
        manifest["activation"]["guard_error_code"].string_value(),
        "capability_unavailable",
    )
    assert_equal(
        manifest["activation"]["state"].string_value(), "pre_activation"
    )

    var versions = loads((schema_dir / "version_manifest.json").read_text())[
        "versions"
    ]
    var axes = List[String]()
    axes.append("schema")
    axes.append("taxonomy")
    axes.append("normalization")
    axes.append("review_policy")
    axes.append("ranking_policy")
    axes.append("question_bundle")
    axes.append("model")
    for axis in axes:
        assert_true(_has_key(versions, axis))
        assert_true(versions[axis].string_value() != "")
    assert_equal(versions["schema"].string_value(), "hyf_ops_v2")

    var operations = manifest["operations"]
    for operation in operations.object_keys():
        var entry = operations[operation]
        var request_schema = loads(
            (schema_dir / entry["request_schema"].string_value()).read_text()
        )
        var response_schema = loads(
            (schema_dir / entry["response_schema"].string_value()).read_text()
        )
        assert_equal(
            request_schema["properties"]["capability"]["const"].string_value(),
            operation,
        )
        var context_def = request_schema["$defs"][
            "farm_context" if operation
            == "farm_update.interpret" else "buyer_context"
        ]
        var context_required = List[String]()
        for value in context_def["required"].array_items():
            context_required.append(value.string_value())
        assert_true("actor_id" in context_required)
        assert_true("versions" in context_required)
        assert_true("evaluation_time" in context_required)
        var context_properties = context_def["properties"]
        if operation == "farm_update.interpret":
            assert_true(_has_key(context_properties, "farm_id"))
        else:
            assert_true(not _has_key(context_properties, "farm_id"))
        var response_required = List[String]()
        for required in response_schema["required"].array_items():
            response_required.append(required.string_value())
        assert_equal(len(response_required), 3)
        assert_true("version" in response_required)
        assert_true("request_id" in response_required)
        assert_true("ok" in response_required)

    var corpus = loads((schema_dir / "examples" / "corpus.json").read_text())
    var entries = corpus["entries"].array_items()
    assert_true(len(entries) >= 30)
    for entry in entries:
        assert_true(exists(schema_dir / entry["file"].string_value()))


def test_c004_operation_v2_escaped_duplicate_key_is_rejected() raises:
    # \u0061 is 'a'; the parser decodes key escapes, so the second key is a
    # duplicate actor_id and must be rejected by decoded-key identity.
    var escaped = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","\\u0061ctor_id":"farm-2","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(escaped).find("duplicate") >= 0)


def test_c004_operation_v2_whitespace_only_identity_is_rejected() raises:
    var blank_actor = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"   ","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(blank_actor).find("blank") >= 0)

    var blank_version = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00","versions":{'
        '"schema":"hyf_ops_v2","taxonomy":"   ","normalization":"n",'
        '"review_policy":"r","ranking_policy":"k","question_bundle":"q",'
        '"model":"m"},"actor_id":"farm-1","farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(blank_version).find("blank") >= 0)


# ADR-0026 D46 CR04: unambiguous duplicate admission, safe correlation and an
# executed zero-dispatch sentinel for all three corrected operations.
from hyf_stdio.dispatch_sentinel import hyf_dispatch_sentinel_env_name


def _v2_farm_request_minimal(request_id: String) -> String:
    return (
        '{"version":1,"request_id":"'
        + request_id
        + '","capability":"farm_update.interpret",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"},"input":{}}'
    )


def _v2_buyer_request_minimal(capability: String, request_id: String) -> String:
    return (
        '{"version":1,"request_id":"'
        + request_id
        + '","capability":"'
        + capability
        + '","context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"buyer-7"},"input":{}}'
    )


def _temp_runtime_context(temp_dir: String) raises -> RuntimeStartupContext:
    return resolve_startup_context(
        RuntimeStartupInput(
            env_paths_profile="repo_local",
            env_repo_local_base_root=temp_dir,
            user_home="/home/unused",
            argv=List[String](),
        )
    )


def test_c004_cr04_duplicate_capability_cannot_hide_corrected_operation() raises:
    # Corrected capability first, legacy capability second.
    var v2_first = (
        '{"version":1,"request_id":"dup-cap-a",'
        '"capability":"farm_update.interpret","capability":"query_rewrite",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"},"input":{}}'
    )
    assert_true(_decode_error_message(v2_first).find("duplicate") >= 0)

    # Legacy capability first, corrected capability second: the corrected value
    # must still make the envelope v2-targeting and therefore ambiguous.
    var v2_second = (
        '{"version":1,"request_id":"dup-cap-b",'
        '"capability":"query_rewrite","capability":"buyer_request.match",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"buyer-7"},"input":{}}'
    )
    assert_true(_decode_error_message(v2_second).find("duplicate") >= 0)


def test_c004_cr04_duplicate_context_cannot_hide_v2_selector() raises:
    # Legacy context first, v2 context second.
    var legacy_first = (
        '{"version":1,"request_id":"dup-ctx-a",'
        '"capability":"farm_update.interpret",'
        '"context":{"consumer":"cli"},'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"},"input":{}}'
    )
    assert_true(_decode_error_message(legacy_first).find("duplicate") >= 0)

    # v2 context first, legacy context second.
    var v2_first = (
        '{"version":1,"request_id":"dup-ctx-b",'
        '"capability":"buyer_request.interpret",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"buyer-7"},"context":{"consumer":"cli"},"input":{}}'
    )
    assert_true(_decode_error_message(v2_first).find("duplicate") >= 0)


def test_c004_cr04_duplicate_correlation_and_equal_values_are_rejected() raises:
    var duplicate_request_id = (
        '{"version":1,"request_id":"dup-rid-a","request_id":"dup-rid-b",'
        '"capability":"farm_update.interpret",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"},"input":{}}'
    )
    assert_true(
        _decode_error_message(duplicate_request_id).find("duplicate") >= 0
    )

    # Equal values are still ambiguous duplicates.
    var equal_values = (
        '{"version":1,"request_id":"dup-eq-a","request_id":"dup-eq-a",'
        '"capability":"buyer_request.match",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"buyer-7"},"input":{}}'
    )
    assert_true(_decode_error_message(equal_values).find("duplicate") >= 0)

    # Escaped equivalent of `capability` is a decoded-key duplicate.
    var escaped_capability = (
        '{"version":1,"request_id":"dup-esc",'
        '"capability":"farm_update.interpret","\\u0063apability":"query_rewrite",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"},"input":{}}'
    )
    assert_true(
        _decode_error_message(escaped_capability).find("duplicate") >= 0
    )


def test_c004_cr04_unrelated_legacy_duplicate_keeps_existing_admission() raises:
    # An unrelated legacy capability is not v2-targeting, so the new duplicate
    # gate deliberately does not apply and the existing legacy admission is
    # unchanged (first-wins envelope parse proceeds).
    var legacy_duplicate = (
        '{"version":1,"request_id":"legacy-dup",'
        '"capability":"query_rewrite","capability":"query_rewrite",'
        '"input":{"query":"eggs"}}'
    )
    var request = decode_request(legacy_duplicate)
    assert_true(not request.operation_context)
    assert_equal(request.capability, "query_rewrite")


def test_c004_cr04_ambiguous_duplicate_correlation_is_untrusted() raises:
    with SafeTempDir() as temp_dir:
        var runtime_context = _temp_runtime_context(temp_dir)
        var line = (
            '{"version":1,"request_id":"dup-cor-a","request_id":"dup-cor-b",'
            '"trace_id":"dup-trace-a","trace_id":"dup-trace-b",'
            '"capability":"farm_update.interpret",'
            '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
            + _v2_versions_json()
            + ',"actor_id":"farm-1","farm_id":"farm-1"},"input":{}}'
        )
        var response = loads(
            handle_request_line_with_runtime_context(line, runtime_context)
        )
        assert_equal(response["ok"].bool_value(), False)
        assert_equal(
            response["error"]["code"].string_value(), "invalid_request"
        )
        # Ambiguous duplicates are never first/last-wins correlation.
        assert_equal(response["request_id"].string_value(), "")
        assert_true(not _has_key(response, "trace_id"))

        # A single unambiguous correlation is still preserved on the same error.
        var unambiguous = (
            '{"version":1,"request_id":"dup-cor-ok","trace_id":"trace-ok",'
            '"capability":"farm_update.interpret",'
            '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
            + _v2_versions_json()
            + ',"actor_id":"farm-1"},"input":{}}'
        )
        var preserved = loads(
            handle_request_line_with_runtime_context(
                unambiguous, runtime_context
            )
        )
        assert_equal(preserved["ok"].bool_value(), False)
        assert_equal(preserved["request_id"].string_value(), "dup-cor-ok")
        assert_equal(preserved["trace_id"].string_value(), "trace-ok")


def test_c004_cr04_context_admission_is_bounded_and_linear() raises:
    # A large repeated allowed key is one decoded-key duplicate and is rejected
    # by the linear seen-key scan rather than an all-pairs comparison.
    var repeated = List[String]()
    for _ in range(256):
        repeated.append('"actor_id":"farm-1"')
    var many_duplicates = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ","
        + ",".join(repeated)
        + ',"farm_id":"farm-1"'
    )
    assert_true(_decode_error_message(many_duplicates).find("duplicate") >= 0)

    # An unknown key is still rejected by the fixed allowed-key set.
    var unknown_and_dup = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00","planner":"strict",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","actor_id":"farm-2","farm_id":"farm-1"'
    )
    var message = _decode_error_message(unknown_and_dup)
    assert_true(
        message.find("duplicate") >= 0 or message.find("unexpected") >= 0
    )


def test_c004_cr04_zero_dispatch_sentinel_executed_controls() raises:
    with SafeTempDir() as temp_dir:
        var sentinel_path = temp_dir + "/hyf-dispatch-sentinel.log"
        var runtime_context = _temp_runtime_context(temp_dir)
        runtime_context.config.effective.runtime.enable_farm_update_interpret = (
            True
        )
        runtime_context.config.effective.runtime.enable_buyer_request_interpret = (
            True
        )
        runtime_context.config.effective.runtime.enable_buyer_request_match = (
            True
        )
        with ScopedEnvVar(hyf_dispatch_sentinel_env_name(), sentinel_path):
            # Negative controls: every recognized v2 request for all three
            # corrected operations returns capability_unavailable and performs
            # zero dispatch, including with the legacy flags enabled.
            var v2_requests = List[String]()
            v2_requests.append(_v2_farm_request_minimal("sentry-farm"))
            v2_requests.append(
                _v2_buyer_request_minimal(
                    "buyer_request.interpret", "sentry-interpret"
                )
            )
            v2_requests.append(
                _v2_buyer_request_minimal("buyer_request.match", "sentry-match")
            )
            for line in v2_requests:
                assert_true(
                    _operation_enabled(
                        runtime_context.config,
                        loads(line)["capability"].string_value(),
                    )
                )
                var response = loads(
                    handle_request_line_with_runtime_context(
                        line, runtime_context
                    )
                )
                assert_equal(response["ok"].bool_value(), False)
                assert_equal(
                    response["error"]["code"].string_value(),
                    "capability_unavailable",
                )
            assert_true(
                not exists(sentinel_path),
            )

            # Positive control: an actual legacy dispatch does record a line,
            # proving the sentinel observes dispatch rather than nothing.
            var legacy = (
                '{"version":1,"request_id":"legacy-sentry",'
                '"capability":"farm_update.interpret","input":{'
                + _v2_farm_source_json()
                + "}}"
            )
            var legacy_response = loads(
                handle_request_line_with_runtime_context(
                    legacy, runtime_context
                )
            )
            assert_equal(legacy_response["ok"].bool_value(), True)
            assert_true(exists(sentinel_path))
            var recorded = Path(sentinel_path).read_text()
            assert_true(recorded.find("dispatch farm_update.interpret") >= 0)


def test_c004_cr04_large_unknown_key_context_is_bounded() raises:
    # ADR-0026 D46 CR04 asks for large unknown-key contexts and field-count
    # edge cases: a 128-key unknown context must be rejected by the fixed
    # allowed-key set without an unbounded scan.
    var unknown = List[String]()
    for index in range(128):
        unknown.append('"unknown_' + String(index) + '":"x"')
    var large_unknown = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1",'
        + ",".join(unknown)
    )
    assert_true(_decode_error_message(large_unknown).find("unexpected") >= 0)

    # A duplicated unknown key is rejected by the bounded seen-key scan.
    var duplicate_unknown = _v2_farm_request_with_context(
        '"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1",'
        + '"unknown_x":"a","unknown_x":"b"'
    )
    var message = _decode_error_message(duplicate_unknown)
    assert_true(
        message.find("duplicate") >= 0 or message.find("unexpected") >= 0
    )


def test_c004_cr04_duplicate_version_input_and_trace_fields() raises:
    # CR04 requires every duplicate correlation/envelope field to fail, not only
    # capability/context: version, input, trace_id and request_id.
    var base = (
        '{"version":1,"trace_id":"t1","request_id":"dup-fields",'
        '"capability":"farm_update.interpret",'
        '"context":{"evaluation_time":"2026-09-24T09:00:00-07:00",'
        + _v2_versions_json()
        + ',"actor_id":"farm-1","farm_id":"farm-1"},"input":{}}'
    )
    var duplicate_trace = base.replace(
        '"trace_id":"t1"', '"trace_id":"t1","trace_id":"t2"'
    )
    assert_true(_decode_error_message(duplicate_trace).find("duplicate") >= 0)

    var duplicate_version = base.replace(
        '"version":1', '"version":1,"version":1'
    )
    assert_true(_decode_error_message(duplicate_version).find("duplicate") >= 0)

    var duplicate_input = base.replace('"input":{}', '"input":{},"input":{}')
    assert_true(_decode_error_message(duplicate_input).find("duplicate") >= 0)

    var duplicate_request_id = base.replace(
        '"request_id":"dup-fields"',
        '"request_id":"dup-fields","request_id":"dup-fields-2"',
    )
    assert_true(
        _decode_error_message(duplicate_request_id).find("duplicate") >= 0
    )
