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
