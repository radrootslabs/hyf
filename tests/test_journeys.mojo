from std.testing import TestSuite, assert_equal, assert_true, assert_raises
from std.collections import List

from hyf_application.authority_sim import (
    apply_expected_version,
    new_authority_simulation,
)
from hyf_application.farm_clarification import apply_farm_clarification
from hyf_application.farm_operation import execute_farm_update_interpret
from json import loads as _loads


def test_farm_review_confirmation_journey_keeps_mutation_outside_hyf() raises:
    var input = _loads(
        '{"source":{"source_id":"s1","revision":"r1","text":"About 80 lb tomatoes. Basil sold out.",'
        '"source_time":"2026-09-21T09:00:00-07:00","timezone":"America/Vancouver",'
        '"actor_id":"farm-1","farm_id":"farm-1"}}'
    )
    var interpretation = execute_farm_update_interpret(input)
    assert_true(interpretation["review"]["required"].bool_value())
    assert_true(interpretation["original_source_preserved"].bool_value())
    assert_equal(interpretation["execution"]["status"].string_value(), "complete")

    var refined = apply_farm_clarification(
        "80", "quantity.unreserved", "s1", "r2", "60 lb unreserved", "60"
    )
    assert_equal(refined.value.value(), "60")

    var simulation = new_authority_simulation()
    assert_true(simulation.requires_confirmation)
    apply_expected_version(simulation, "s1", "r1", "r1")
    assert_equal(simulation.accepted_changes, 1)
    with assert_raises():
        apply_expected_version(simulation, "s1", "r1", "r1")
    assert_equal(simulation.duplicate_rejections, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_application.buyer_operation import (
    execute_buyer_request_interpret,
    execute_buyer_request_match,
)


def test_buyer_interpretation_match_journey_is_not_a_reservation() raises:
    var source = _loads(
        '{"source":{"source_id":"b1","revision":"r1","text":"Need 25 kg of tomatoes.",'
        '"source_time":"2026-09-21T09:05:00-07:00","timezone":"America/Vancouver",'
        '"actor_id":"buyer-1","farm_id":"buyer-1"}}'
    )
    var interpreted = execute_buyer_request_interpret(source)
    assert_true(interpreted["review"]["required"].bool_value())
    var match_input = _loads(
        '{"need":{"need_id":"n1"},"snapshots":[{"lot_id":"lot-1","revision":"l1"}]}'
    )
    var matched = execute_buyer_request_match(match_input)
    assert_equal(matched["limitations"]["scope"].string_value(), "supplied_only")
    assert_equal(matched["limitations"]["supported_mode"].string_value(), "single_supplier_compatible_lots")
    assert_true(matched["limitations"]["truncated"].bool_value() == False)


def test_duplicate_and_stale_authority_responses() raises:
    var simulation = new_authority_simulation()
    apply_expected_version(simulation, "s2", "r2", "r2")
    assert_equal(simulation.accepted_changes, 1)
    with assert_raises():
        apply_expected_version(simulation, "s2", "r2", "r2")
    assert_equal(simulation.duplicate_rejections, 1)
    with assert_raises():
        apply_expected_version(simulation, "s3", "r1", "r2")
    assert_equal(simulation.stale_rejections, 1)
    # A match is not a lock on stock: the authority still revalidates.
    assert_true(simulation.requires_confirmation)
