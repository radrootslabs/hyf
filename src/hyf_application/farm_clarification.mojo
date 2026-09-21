from hyf_core.domain.clarification import (
    ClarificationEvidence,
    apply_clarification,
    clarification_evidence,
    clarification_is_stale,
)
from hyf_core.domain.field import DecodedField, known_field


def apply_farm_clarification(
    original_value: String,
    target_field: String,
    source_id: String,
    revision: String,
    clarification_text: String,
    resolved_value: String,
) raises -> DecodedField:
    var original = known_field(original_value, "span")
    var evidence = clarification_evidence(
        target_field, source_id, revision, clarification_text
    )
    return apply_clarification(original, evidence, resolved_value)


def farm_clarification_is_stale(
    target_field: String,
    source_id: String,
    revision: String,
    text: String,
    current_revision: String,
) raises -> Bool:
    return clarification_is_stale(
        clarification_evidence(target_field, source_id, revision, text),
        current_revision,
    )


def clarification_overwrites_original() -> Bool:
    return False
