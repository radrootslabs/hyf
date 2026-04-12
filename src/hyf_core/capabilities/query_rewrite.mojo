from std.collections import List, Optional

from mojson import Value, loads

from hyf_assist.bridge import (
    execute_query_rewrite_via_assist_bridge,
    resolve_assist_bridge_status,
)
from hyf_assist.contract import AssistQueryRewriteResult
from hyf_core.capabilities.query_analysis import (
    QueryAnalysis,
    QueryRewriteRequest,
    analyze_query_text,
    build_deterministic_meta,
    parse_query_rewrite_request,
    query_signal_tags,
    serialize_extracted_filters,
    string_array_value,
)
from hyf_core.errors import (
    CapabilityResult,
    failed_capability,
    invalid_input_error,
    successful_capability,
)
from hyf_core.provenance import (
    CoreResponseMeta,
    ExecutionProvenance,
    ProvenanceFallback,
    ProvenanceSourceRef,
)
from hyf_core.request_context import RequestContext, assisted_execution_requested
from hyf_runtime.config import HyfLoadedRuntimeConfig


def _build_output(analysis: QueryAnalysis) raises -> Value:
    var output = loads("{}")
    output.set("original_text", Value(String(analysis.original_text)))
    output.set("normalized_text", Value(String(analysis.normalized_text)))
    output.set("rewritten_text", Value(String(analysis.rewritten_text)))
    output.set("query_terms", string_array_value(analysis.query_terms))
    output.set(
        "normalization_signals",
        string_array_value(analysis.normalization_signals),
    )
    output.set("ranking_hints", string_array_value(analysis.ranking_hints))
    output.set(
        "extracted_filters",
        serialize_extracted_filters(analysis.extracted_filters),
    )
    return output^


def _base_source_refs(
    context: RequestContext, capability_name: String
) -> List[ProvenanceSourceRef]:
    var source_refs = List[ProvenanceSourceRef]()
    source_refs.append(
        ProvenanceSourceRef(
            source_kind="local_input",
            source_ref=capability_name + ":input",
        )
    )
    if context.scope:
        source_refs.append(
            ProvenanceSourceRef(
                source_kind="request_scope",
                source_ref="request_context.scope",
            )
        )
    return source_refs^


def _build_assisted_meta(
    context: RequestContext, result: AssistQueryRewriteResult
) -> CoreResponseMeta:
    var provenance: Optional[ExecutionProvenance] = None
    if context.return_provenance:
        provenance = ExecutionProvenance(
            kind="assisted",
            signal_tags=query_signal_tags(result.analysis),
            source_refs=_base_source_refs(context, "query_rewrite"),
            fallback=None,
            evidence_set_id=None,
        )

    return CoreResponseMeta(
        execution_mode="assisted",
        backend="assist_bridge",
        provider=Optional[String](String(result.provider)),
        route=Optional[String](String(result.route)),
        model=Optional[String](String(result.model)),
        latency_ms=Optional[Int](result.latency_ms),
        schema_version=Optional[Int](result.schema_version),
        prompt_version=None,
        provenance=provenance^,
    )


def _build_deterministic_fallback_meta(
    context: RequestContext, analysis: QueryAnalysis, reason: String
) -> CoreResponseMeta:
    var provenance: Optional[ExecutionProvenance] = None
    if context.return_provenance:
        provenance = ExecutionProvenance(
            kind="deterministic",
            signal_tags=query_signal_tags(analysis),
            source_refs=_base_source_refs(context, "query_rewrite"),
            fallback=ProvenanceFallback(
                fallback_kind="assist_bridge", reason=String(reason)
            ),
            evidence_set_id=None,
        )

    return CoreResponseMeta(
        execution_mode="deterministic",
        backend="heuristic",
        provider=None,
        route=None,
        model=None,
        latency_ms=None,
        schema_version=Optional[Int](1),
        prompt_version=None,
        provenance=provenance^,
    )


def execute_query_rewrite(
    input: Value, context: RequestContext
) raises -> CapabilityResult:
    try:
        var request: QueryRewriteRequest = parse_query_rewrite_request(input)
        var analysis = analyze_query_text(request.text, context)

        var source_refs = List[ProvenanceSourceRef]()
        return successful_capability(
            _build_output(analysis),
            meta=build_deterministic_meta(
                context=context,
                capability_name="query_rewrite",
                signal_tags=query_signal_tags(analysis),
                extra_source_refs=source_refs^,
            ),
        )
    except e:
        return failed_capability(invalid_input_error(String(e)))


def execute_query_rewrite_with_runtime_config(
    input: Value,
    context: RequestContext,
    runtime_config: HyfLoadedRuntimeConfig,
) raises -> CapabilityResult:
    try:
        var request: QueryRewriteRequest = parse_query_rewrite_request(input)
        if assisted_execution_requested(context):
            var bridge_status = resolve_assist_bridge_status(runtime_config)
            if bridge_status.reachable:
                try:
                    var assisted_result = execute_query_rewrite_via_assist_bridge(
                        bridge_status, request.text, context
                    )
                    return successful_capability(
                        _build_output(assisted_result.analysis),
                        meta=_build_assisted_meta(context, assisted_result),
                    )
                except e:
                    var fallback_analysis = analyze_query_text(
                        request.text, context
                    )
                    return successful_capability(
                        _build_output(fallback_analysis),
                        meta=_build_deterministic_fallback_meta(
                            context,
                            fallback_analysis,
                            "bridge_execution_failed",
                        ),
                    )

            var fallback_analysis = analyze_query_text(request.text, context)
            return successful_capability(
                _build_output(fallback_analysis),
                meta=_build_deterministic_fallback_meta(
                    context, fallback_analysis, bridge_status.state
                ),
            )

        return execute_query_rewrite(input, context)
    except e:
        return failed_capability(invalid_input_error(String(e)))
