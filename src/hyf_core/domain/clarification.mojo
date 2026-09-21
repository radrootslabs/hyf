from hyf_core.domain.field import DecodedField, known_field


@fieldwise_init
struct ClarificationEvidence(Copyable, Movable):
    var target_field: String
    var source_id: String
    var revision: String
    var text: String


def clarification_evidence(
    target_field: String, source_id: String, revision: String, text: String
) raises -> ClarificationEvidence:
    if target_field.strip() == "":
        raise Error("clarification requires a target field")
    if source_id.strip() == "" or revision.strip() == "":
        raise Error("clarification requires source id and revision")
    if text.strip() == "":
        raise Error("clarification text must not be empty")
    return ClarificationEvidence(
        target_field=String(target_field),
        source_id=String(source_id),
        revision=String(revision),
        text=String(text),
    )


def clarification_is_stale(
    evidence: ClarificationEvidence, current_revision: String
) -> Bool:
    return evidence.revision != current_revision


def apply_clarification(
    original: DecodedField,
    evidence: ClarificationEvidence,
    resolved_value: String,
) raises -> DecodedField:
    var refined = known_field(resolved_value, "clarification")
    refined.qualifier = original.qualifier
    return refined^
