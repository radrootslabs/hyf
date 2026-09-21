from std.testing import TestSuite, assert_equal, assert_raises, assert_true

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
