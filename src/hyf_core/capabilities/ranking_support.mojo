from std.collections import List

from mojson import Value
from mojson.deserialize import get_float, get_int, get_string

from hyf_core.capabilities.query_analysis import (
    QueryAnalysis,
    collapse_whitespace,
    has_key,
    normalize_free_text,
)
from hyf_core.request_context import RequestContext


@fieldwise_init
struct SemanticCandidate(Copyable, Movable):
    var id: String
    var title: String
    var farm: String
    var delivery: String
    var distance_km: Float64
    var freshness_minutes: Int


@fieldwise_init
struct CandidateEvaluation(Copyable, Movable):
    var candidate: SemanticCandidate
    var score: Int
    var reasons: List[String]
    var matched_terms: List[String]
    var delivery_alignment: String
    var distance_band: String
    var freshness_band: String
    var scope_match: Bool


def _require_object(value: Value, context: String) raises:
    if not value.is_object():
        raise Error(context + " must be a JSON object")


def _copy_candidate(candidate: SemanticCandidate) -> SemanticCandidate:
    return SemanticCandidate(
        id=String(candidate.id),
        title=String(candidate.title),
        farm=String(candidate.farm),
        delivery=String(candidate.delivery),
        distance_km=candidate.distance_km,
        freshness_minutes=candidate.freshness_minutes,
    )


def _copy_string_list(items: List[String]) -> List[String]:
    var copied = List[String]()
    for item in items:
        copied.append(String(item))
    return copied^


def _copy_evaluation(evaluation: CandidateEvaluation) -> CandidateEvaluation:
    return CandidateEvaluation(
        candidate=_copy_candidate(evaluation.candidate),
        score=evaluation.score,
        reasons=_copy_string_list(evaluation.reasons),
        matched_terms=_copy_string_list(evaluation.matched_terms),
        delivery_alignment=String(evaluation.delivery_alignment),
        distance_band=String(evaluation.distance_band),
        freshness_band=String(evaluation.freshness_band),
        scope_match=evaluation.scope_match,
    )


def _parse_candidate(json: Value, context: String) raises -> SemanticCandidate:
    _require_object(json, context)

    var id = get_string(json, "id")
    if collapse_whitespace(id) == "":
        raise Error(context + " field 'id' must not be empty")

    var title = get_string(json, "title")
    if collapse_whitespace(title) == "":
        raise Error(context + " field 'title' must not be empty")

    var farm = get_string(json, "farm")
    if collapse_whitespace(farm) == "":
        raise Error(context + " field 'farm' must not be empty")

    var delivery = get_string(json, "delivery")
    if collapse_whitespace(delivery) == "":
        raise Error(context + " field 'delivery' must not be empty")

    var distance_km = get_float(json, "distance_km")
    if distance_km < 0.0:
        raise Error(context + " field 'distance_km' must be non-negative")

    var freshness_minutes = get_int(json, "freshness_minutes")
    if freshness_minutes < 0:
        raise Error(
            context + " field 'freshness_minutes' must be non-negative"
        )

    return SemanticCandidate(
        id=collapse_whitespace(id),
        title=collapse_whitespace(title),
        farm=collapse_whitespace(farm),
        delivery=collapse_whitespace(delivery).lower(),
        distance_km=distance_km,
        freshness_minutes=freshness_minutes,
    )


def parse_candidate_array(
    input: Value, capability_name: String
) raises -> List[SemanticCandidate]:
    _require_object(input, capability_name + " input")

    if not has_key(input, "candidates"):
        raise Error(capability_name + " input requires 'candidates'")

    var candidates_value = input["candidates"]
    if not candidates_value.is_array():
        raise Error(
            capability_name + " input field 'candidates' must be a JSON array"
        )

    var candidates = List[SemanticCandidate]()
    for item in candidates_value.array_items():
        candidates.append(
            _parse_candidate(item, capability_name + " candidate")
        )

    if len(candidates) == 0:
        raise Error(
            capability_name + " input field 'candidates' must not be empty"
        )

    return candidates^


def parse_single_candidate(
    input: Value, capability_name: String
) raises -> SemanticCandidate:
    _require_object(input, capability_name + " input")

    var field_count = 0
    if has_key(input, "candidate"):
        field_count += 1
    if has_key(input, "result"):
        field_count += 1

    if field_count == 0:
        raise Error(
            capability_name + " input requires 'candidate' or 'result'"
        )
    if field_count > 1:
        raise Error(
            capability_name
            + " input must not include both 'candidate' and 'result'"
        )

    if has_key(input, "candidate"):
        return _parse_candidate(
            input["candidate"], capability_name + " candidate"
        )

    return _parse_candidate(input["result"], capability_name + " result")


def _normalize_candidate_text(candidate: SemanticCandidate) -> String:
    var signals = List[String]()
    return normalize_free_text(
        candidate.title + " " + candidate.farm, signals
    )


def _display_term(term: String) -> String:
    return String(term)


def _delivery_alignment(
    query_delivery: String, candidate_delivery: String
) -> String:
    if query_delivery == "unspecified":
        return "not_requested"
    if query_delivery == candidate_delivery:
        return "match"
    return "mismatch"


def _distance_band(local_intent: Bool, distance_km: Float64) -> String:
    if not local_intent:
        return "not_considered"
    if distance_km <= 5.0:
        return "closer"
    return "farther"


def _freshness_band(freshness_minutes: Int) -> String:
    if freshness_minutes <= 10:
        return "fresher"
    if freshness_minutes <= 30:
        return "standard"
    return "older"


def _scope_match(candidate: SemanticCandidate, context: RequestContext) -> Bool:
    if not context.scope:
        return False

    var scope = context.scope.value().copy()
    for listing_id in scope.listing_ids:
        if listing_id == candidate.id:
            return True
    return False


def evaluate_candidate(
    candidate: SemanticCandidate,
    analysis: QueryAnalysis,
    context: RequestContext,
) -> CandidateEvaluation:
    var reasons = List[String]()
    var matched_terms = List[String]()
    var score = 0

    var normalized_candidate_text = _normalize_candidate_text(candidate)
    var scope_match = _scope_match(candidate, context)
    if scope_match:
        reasons.append("scope match")
        score += 40

    for query_term in analysis.query_terms:
        var matched = False
        for candidate_term in normalized_candidate_text.split():
            if String(candidate_term) == query_term:
                matched = True
                break
        if matched:
            matched_terms.append(String(query_term))
            score += 30

    if len(matched_terms) > 0:
        reasons.append(_display_term(matched_terms[0]) + " match")

    var delivery_alignment = _delivery_alignment(
        analysis.extracted_filters.fulfillment, candidate.delivery
    )
    if delivery_alignment == "match":
        reasons.append(candidate.delivery + " match")
        score += 35
    elif delivery_alignment == "mismatch":
        reasons.append("delivery mismatch")
        score -= 20

    var distance_band = _distance_band(
        analysis.extracted_filters.local_intent, candidate.distance_km
    )
    if distance_band == "closer":
        reasons.append("closer")
        score += 20
    elif distance_band == "farther":
        reasons.append("farther")
        score += 5

    var freshness_band = _freshness_band(candidate.freshness_minutes)
    if freshness_band == "fresher":
        reasons.append("fresher")
        score += 15
    elif freshness_band == "older":
        score -= 5

    if analysis.extracted_filters.time_window == "weekend":
        score += 2

    return CandidateEvaluation(
        candidate=_copy_candidate(candidate),
        score=score,
        reasons=reasons^,
        matched_terms=matched_terms^,
        delivery_alignment=delivery_alignment,
        distance_band=distance_band,
        freshness_band=freshness_band,
        scope_match=scope_match,
    )


def _should_precede(
    pending: CandidateEvaluation, existing: CandidateEvaluation
) -> Bool:
    if pending.score != existing.score:
        return pending.score > existing.score

    if pending.scope_match != existing.scope_match:
        return pending.scope_match

    if len(pending.matched_terms) != len(existing.matched_terms):
        return len(pending.matched_terms) > len(existing.matched_terms)

    if pending.candidate.distance_km != existing.candidate.distance_km:
        return pending.candidate.distance_km < existing.candidate.distance_km

    if (
        pending.candidate.freshness_minutes
        != existing.candidate.freshness_minutes
    ):
        return (
            pending.candidate.freshness_minutes
            < existing.candidate.freshness_minutes
        )

    return pending.candidate.id < existing.candidate.id


def rank_candidates(
    candidates: List[SemanticCandidate],
    analysis: QueryAnalysis,
    context: RequestContext,
) -> List[CandidateEvaluation]:
    var ranked = List[CandidateEvaluation]()
    for candidate in candidates:
        var pending = evaluate_candidate(candidate, analysis, context)
        var updated = List[CandidateEvaluation]()
        var inserted = False
        for existing in ranked:
            if not inserted and _should_precede(pending, existing):
                updated.append(_copy_evaluation(pending))
                inserted = True
            updated.append(_copy_evaluation(existing))
        if not inserted:
            updated.append(_copy_evaluation(pending))
        ranked = updated^
    return ranked^
