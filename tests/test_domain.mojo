from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from hyf_core.domain.evidence import EvidenceRef
from hyf_core.domain.source import (
    actor_id,
    farm_id,
    lot_id,
    need_id,
    revision,
    source_id,
    trusted_source,
)


def test_source_identity_accepts_valid_and_rejects_empty() raises:
    assert_equal(source_id("s1").value, "s1")
    assert_equal(actor_id("a1").value, "a1")
    assert_equal(farm_id("f1").value, "f1")
    assert_equal(need_id("n1").value, "n1")
    assert_equal(lot_id("l1").value, "l1")
    assert_equal(revision("r1").value, "r1")
    with assert_raises():
        _ = source_id("")
    with assert_raises():
        _ = revision(" r1")
    with assert_raises():
        _ = actor_id("a1 ")


def test_trusted_source_preserves_revision() raises:
    var source = trusted_source("s1", "r1", "a1", "f1")
    assert_equal(source.source_id.value, "s1")
    assert_equal(source.revision.value, "r1")
    assert_equal(source.actor_id.value, "a1")
    assert_equal(source.farm_id.value, "f1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_core.domain.evidence import (
    record_field_evidence,
    selected_text,
    span_evidence,
    span_is_valid,
    validate_span_against_revision,
)


def test_evidence_span_byte_offsets_and_revision() raises:
    var text = "caf\u00e9: 80 lb"
    var evidence = span_evidence("s1", "r1", 7, 12, "span")
    assert_equal(evidence.kind, "span")
    assert_equal(selected_text(text, evidence), "80 lb")
    validate_span_against_revision(text, "r1", evidence)
    assert_true(span_is_valid(text, evidence))

    with assert_raises():
        _ = span_evidence("s1", "r1", 5, 4, "span")


def test_evidence_rejects_out_of_range_and_revision_mismatch() raises:
    var text = "short"
    with assert_raises():
        _ = span_evidence("s1", "r1", -1, 2, "span")
    var beyond = span_evidence("s1", "r1", 0, 99, "span")
    with assert_raises():
        validate_span_against_revision(text, "r1", beyond)
    var good = span_evidence("s1", "r1", 0, 3, "span")
    with assert_raises():
        validate_span_against_revision(text, "r2", good)
    var field = record_field_evidence("s1", "r1", "lot-1", "unreserved_quantity")
    assert_equal(field.kind, "record_field")
    assert_equal(field.record_id.value(), "lot-1")
