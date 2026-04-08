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
    CandidateEvaluation,
    SemanticRankRequest,
    parse_semantic_rank_request,
    rank_candidates,
)
from hyf_core.errors import (
    CapabilityResult,
    failed_capability,
    invalid_input_error,
    successful_capability,
)
from hyf_core.provenance import ProvenanceSourceRef
from hyf_core.request_context import RequestContext


def _build_scored_candidates(
    ranked: List[CandidateEvaluation]
) raises -> Value:
    var scored = loads("[]")
    for evaluation in ranked:
        var candidate = loads("{}")
        candidate.set("id", Value(String(evaluation.candidate.id)))
        candidate.set("heuristic_score", Value(evaluation.score))
        candidate.set("matched_terms", string_array_value(evaluation.matched_terms))
        candidate.set("reasons", string_array_value(evaluation.reasons))
        candidate.set(
            "delivery_alignment",
            Value(String(evaluation.delivery_alignment)),
        )
        candidate.set("distance_band", Value(String(evaluation.distance_band)))
        candidate.set("freshness_band", Value(String(evaluation.freshness_band)))
        candidate.set("scope_match", Value(evaluation.scope_match))
        scored.append(candidate)
    return scored^


def _build_output(
    ranked: List[CandidateEvaluation],
    ranking_hints: List[String],
    extracted_filters: Value,
) raises -> Value:
    var output = loads("{}")
    var ranked_ids = loads("[]")
    var reasons = loads("{}")

    for evaluation in ranked:
        ranked_ids.append(Value(String(evaluation.candidate.id)))
        reasons.set(
            String(evaluation.candidate.id),
            string_array_value(evaluation.reasons),
        )

    output.set("ranked_ids", ranked_ids)
    output.set("reasons", reasons)
    output.set("scored_candidates", _build_scored_candidates(ranked))
    output.set("ranking_hints", string_array_value(ranking_hints))
    output.set("extracted_filters", extracted_filters)
    return output^


def execute_semantic_rank(
    input: Value, context: RequestContext
) raises -> CapabilityResult:
    try:
        var request: SemanticRankRequest = parse_semantic_rank_request(input)
        var analysis = analyze_query_text(request.query_text, context)
        var ranked = rank_candidates(request.candidates, analysis, context)

        var signal_tags = query_signal_tags(analysis)
        signal_tags.append("candidate_set_evaluated")

        var source_refs = List[ProvenanceSourceRef]()
        source_refs.append(
            ProvenanceSourceRef(
                source_kind="candidate_set",
                source_ref="semantic_rank:candidates",
            )
        )

        return successful_capability(
            _build_output(
                ranked=ranked,
                ranking_hints=analysis.ranking_hints,
                extracted_filters=serialize_extracted_filters(
                    analysis.extracted_filters
                ),
            ),
            meta=build_deterministic_meta(
                context=context,
                capability_name="semantic_rank",
                signal_tags=signal_tags,
                extra_source_refs=source_refs^,
            ),
        )
    except e:
        return failed_capability(invalid_input_error(String(e)))
