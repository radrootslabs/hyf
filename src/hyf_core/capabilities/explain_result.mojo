from std.collections import List

from mojson import Value, loads

from hyf_core.capabilities.query_analysis import (
    analyze_query_text,
    build_deterministic_meta,
    query_signal_tags,
    serialize_extracted_filters,
    string_array_value,
)
from hyf_core.capabilities.ranking_support import (
    ExplainResultRequest,
    evaluate_candidate,
    parse_explain_result_request,
)
from hyf_core.errors import (
    CapabilityResult,
    backend_unavailable_error,
    failed_capability,
    invalid_input_error,
    successful_capability,
)
from hyf_core.provenance import ProvenanceSourceRef
from hyf_core.request_context import (
    RequestContext,
    assisted_execution_requested,
)


def _join_reason_summary(reasons: List[String]) -> String:
    if len(reasons) == 0:
        return "no strong ranking signals were detected"

    if len(reasons) == 1:
        return String(reasons[0])

    var summary = String()
    for index in range(len(reasons)):
        if index > 0:
            if index == len(reasons) - 1:
                summary += " and "
            else:
                summary += ", "
        summary += String(reasons[index])
    return summary^


def _build_output(
    result_id: String,
    score: Int,
    reasons: List[String],
    matched_terms: List[String],
    ranking_hints: List[String],
    extracted_filters: Value,
    delivery_alignment: String,
    distance_band: String,
    freshness_band: String,
    scope_match: Bool,
) raises -> Value:
    var output = loads("{}")
    output.set("result_id", Value(String(result_id)))
    output.set(
        "explanation_kind",
        Value("deterministic"),
    )
    output.set(
        "summary",
        Value(
            "Result "
            + result_id
            + " was ranked using deterministic heuristic signals: "
            + _join_reason_summary(reasons)
            + "."
        ),
    )
    output.set("score", Value(score))
    output.set("reasons", string_array_value(reasons))
    output.set("matched_terms", string_array_value(matched_terms))
    output.set("ranking_hints", string_array_value(ranking_hints))
    output.set("extracted_filters", extracted_filters)

    var assessment = loads("{}")
    assessment.set("delivery_alignment", Value(String(delivery_alignment)))
    assessment.set("distance_band", Value(String(distance_band)))
    assessment.set("freshness_band", Value(String(freshness_band)))
    assessment.set("scope_match", Value(scope_match))
    output.set("signal_assessment", assessment)
    return output^


def execute_explain_result(
    input: Value, context: RequestContext
) raises -> CapabilityResult:
    if assisted_execution_requested(context):
        return failed_capability(
            backend_unavailable_error("assisted_execution")
        )

    try:
        var request: ExplainResultRequest = parse_explain_result_request(input)
        var analysis = analyze_query_text(request.query_text, context)
        var evaluation = evaluate_candidate(
            request.candidate, analysis, context
        )

        var signal_tags = query_signal_tags(analysis)
        for reason in evaluation.reasons:
            signal_tags.append("reason:" + String(reason))

        var source_refs = List[ProvenanceSourceRef]()
        source_refs.append(
            ProvenanceSourceRef(
                source_kind="candidate",
                source_ref="explain_result:candidate",
            )
        )

        return successful_capability(
            _build_output(
                result_id=evaluation.candidate.id,
                score=evaluation.score,
                reasons=evaluation.reasons,
                matched_terms=evaluation.matched_terms,
                ranking_hints=analysis.ranking_hints,
                extracted_filters=serialize_extracted_filters(
                    analysis.extracted_filters
                ),
                delivery_alignment=evaluation.delivery_alignment,
                distance_band=evaluation.distance_band,
                freshness_band=evaluation.freshness_band,
                scope_match=evaluation.scope_match,
            ),
            meta=build_deterministic_meta(
                context=context,
                capability_name="explain_result",
                signal_tags=signal_tags,
                extra_source_refs=source_refs^,
            ),
        )
    except e:
        return failed_capability(invalid_input_error(String(e)))
