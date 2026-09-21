from std.collections import Optional


@fieldwise_init
struct EvidenceRef(Copyable, Movable):
    var source_id: String
    var revision: String
    var kind: String
    var start: Int
    var end: Int
    var record_id: Optional[String]
    var field: Optional[String]
    var method: String


def span_evidence(
    source_id: String, revision: String, start: Int, end: Int, method: String
) raises -> EvidenceRef:
    if source_id.strip() == "":
        raise Error("evidence source_id must not be empty")
    if revision.strip() == "":
        raise Error("evidence revision must not be empty")
    if method.strip() == "":
        raise Error("evidence method must not be empty")
    if start < 0:
        raise Error("evidence span start must be non-negative")
    if end < start:
        raise Error("evidence span end must not precede start")
    return EvidenceRef(
        source_id=String(source_id),
        revision=String(revision),
        kind="span",
        start=start,
        end=end,
        record_id=None,
        field=None,
        method=String(method),
    )


def record_field_evidence(
    source_id: String, revision: String, record_id: String, field: String
) raises -> EvidenceRef:
    if source_id.strip() == "" or revision.strip() == "":
        raise Error("evidence source_id and revision must not be empty")
    if record_id.strip() == "" or field.strip() == "":
        raise Error("record_field evidence requires record_id and field")
    return EvidenceRef(
        source_id=String(source_id),
        revision=String(revision),
        kind="record_field",
        start=0,
        end=0,
        record_id=Optional[String](String(record_id)),
        field=Optional[String](String(field)),
        method="trusted_record",
    )


def span_is_valid(text: String, evidence: EvidenceRef) raises -> Bool:
    if evidence.kind != "span":
        raise Error("span_is_valid requires span evidence")
    return evidence.end <= text.byte_length()


def validate_span_against_revision(
    text: String, source_revision: String, evidence: EvidenceRef
) raises:
    if evidence.kind != "span":
        raise Error("span evidence required")
    if evidence.revision != source_revision:
        raise Error("evidence revision does not match source revision")
    if not span_is_valid(text, evidence):
        raise Error("evidence span exceeds source byte length")


def selected_text(text: String, evidence: EvidenceRef) raises -> String:
    if evidence.kind != "span":
        raise Error("selected_text requires span evidence")
    return String(text[byte = evidence.start : evidence.end])
