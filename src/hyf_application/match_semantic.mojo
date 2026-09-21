from hyf_core.domain.eligibility import (
    ConstraintAssessment,
    constraint_assessment,
)


def evidence_sufficient(evidence_count: Int, required: Int) -> Bool:
    return evidence_count >= required


def gated_semantic_suitability(
    score: Int, evidence_count: Int, required_evidence: Int
) raises -> ConstraintAssessment:
    if not evidence_sufficient(evidence_count, required_evidence):
        return constraint_assessment(
            "suitability", "unknown", True, "evidence_insufficient"
        )
    return constraint_assessment(
        "suitability", "pass", True, "evidence_sufficient"
    )


def unknown_evidence_is_midpoint_score() -> Bool:
    return False


from hyf_assist.evaluator import TypedAnswer, normalize_score


def culinary_use_score(
    answer: TypedAnswer,
    levels: Int,
    evidence_count: Int,
    required_evidence: Int,
) raises -> Float64:
    if not evidence_sufficient(evidence_count, required_evidence):
        raise Error("evidence_insufficient")
    return normalize_score(answer, levels)


def culinary_score_affects_feasibility() -> Bool:
    return False
