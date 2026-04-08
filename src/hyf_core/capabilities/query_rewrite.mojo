from std.collections import List

from mojson import Value, loads

from hyf_core.capabilities.query_analysis import (
    QueryAnalysis,
    analyze_query,
    build_deterministic_meta,
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
from hyf_core.provenance import ProvenanceSourceRef
from hyf_core.request_context import RequestContext


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


def execute_query_rewrite(
    input: Value, context: RequestContext
) raises -> CapabilityResult:
    try:
        var analysis = analyze_query(input, context, "query_rewrite")

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
