from std.testing import TestSuite, assert_true, assert_equal, assert_raises

from hyf_application.orchestration import (
    application_layer_owns_business_state,
    application_layer_uses_transport_types,
    operation_is_supported,
    supported_operations,
)


def test_application_layer_is_transport_independent() raises:
    assert_equal(len(supported_operations()), 3)
    assert_true(operation_is_supported("farm_update.interpret"))
    assert_true(operation_is_supported("buyer_request.match"))
    assert_true(not operation_is_supported("query_rewrite"))
    assert_true(not application_layer_uses_transport_types())
    assert_true(not application_layer_owns_business_state())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_application.context import (
    context_is_trusted_host_supplied,
    interpretation_source,
    source_text_is_data_not_instruction,
)


def test_interpretation_source_context_validation() raises:
    var source = interpretation_source(
        "farm-source-1", "r1", "Got about 80 lb of Roma tomatoes.",
        "2026-09-21T09:00:00-07:00", "America/Vancouver", "farm-1", "farm-1",
    )
    assert_equal(source.revision, "r1")
    assert_true(context_is_trusted_host_supplied())
    assert_true(source_text_is_data_not_instruction())
    with assert_raises():
        _ = interpretation_source("", "r1", "x", "t", "z", "a", "f")
    with assert_raises():
        _ = interpretation_source("s", "r1", "x", "t", "", "a", "f")


from hyf_application.farm_status import (
    interpret_product_statuses,
    status_is_confirmed_inventory,
    status_is_forecast,
)


def test_product_specific_supply_status_per_crop() raises:
    var products = List[String]()
    products.append("roma tomatoes")
    products.append("basil")
    var statuses = interpret_product_statuses(products, "offered")
    assert_equal(len(statuses), 2)
    assert_equal(statuses[0].product_phrase, "roma tomatoes")
    assert_equal(statuses[1].product_phrase, "basil")
    assert_true(not status_is_confirmed_inventory(statuses[0].status))
    var forecast = interpret_product_statuses(products, "forecast")
    assert_true(status_is_forecast(forecast[0].status))
    var unknown = interpret_product_statuses(products, "probably")
    assert_equal(unknown[0].status, "unclear")


from hyf_application.farm_quantity import (
    ProductQuantityAssociation,
    associate_quantity,
    reported_quantity_is_unreserved_stock,
)


def test_quantity_association_per_product_without_swap() raises:
    var tomatoes = associate_quantity("roma tomatoes", 80, 0, "lb", "approximate")
    var basil = associate_quantity("basil", 0, 0, "bunch", "exact")
    assert_equal(tomatoes.product_phrase, "roma tomatoes")
    assert_equal(tomatoes.quantity_value, 80)
    assert_equal(tomatoes.qualifier, "approximate")
    assert_equal(basil.product_phrase, "basil")
    assert_true(tomatoes.quantity_value != basil.quantity_value)
    assert_true(not reported_quantity_is_unreserved_stock())
    with assert_raises():
        _ = associate_quantity("", 1, 0, "kg", "exact")


from hyf_application.farm_changes import (
    interpret_update_change,
    interpret_update_operation,
    operation_is_proposal,
)


def test_supply_update_operation_semantics() raises:
    assert_equal(interpret_update_operation("another"), "addition")
    assert_equal(interpret_update_operation("left"), "remaining")
    assert_equal(interpret_update_operation("total"), "replacement")
    assert_equal(interpret_update_operation("sold out"), "withdrawal")
    assert_equal(interpret_update_operation("actually"), "correction")
    assert_equal(interpret_update_operation("maybe"), "unresolved")
    var addition = interpret_update_change("another", "listing", Optional[String]("b1"))
    assert_equal(addition.operation, "addition")
    var ambiguous = interpret_update_change("sold out", "listing", None)
    assert_equal(ambiguous.operation, "unresolved")
    assert_true(operation_is_proposal())


from hyf_application.farm_targets import resolve_change_target


def test_authorized_change_target_resolution() raises:
    var authorized = List[String]()
    authorized.append("b1")
    var resolved = resolve_change_target("withdrawal", Optional[String]("b1"), authorized)
    assert_equal(resolved.operation, "withdrawal")
    assert_equal(resolved.target_id.value(), "b1")
    var unauthorized = resolve_change_target("withdrawal", Optional[String]("b9"), authorized)
    assert_equal(unauthorized.operation, "unresolved")
    assert_true(unauthorized.unresolved)
    var ambiguous = resolve_change_target("withdrawal", None, authorized)
    assert_equal(ambiguous.operation, "unresolved")


from hyf_application.farm_fulfillment import interpret_fulfillment
from hyf_core.domain.supply_change import ProposedSupplyChange
from hyf_core.domain.time import date_only


def test_farm_fulfillment_and_timing_claims() raises:
    var monday = date_only(2026, 9, 21)
    var delivery = interpret_fulfillment("delivery", "Friday", monday, "America/Vancouver")
    assert_equal(delivery.resolved_date, "2026-9-25")
    assert_equal(delivery.ambiguity, "none")
    assert_true(not delivery.area_verified)
    var no_zone = interpret_fulfillment("delivery", "Friday", monday, "")
    assert_equal(no_zone.ambiguity, "missing_zone")
    var none = interpret_fulfillment("pickup", "", monday, "America/Vancouver")
    assert_equal(none.window_expression, "")


from hyf_application.farm_review_output import (
    ambiguous_withdrawal_blocks_apply,
    assemble_farm_output,
    missing_optional_price_blocks_draft,
)
from hyf_core.domain.execution import execution_meta
from hyf_core.domain.review import review_required


def test_farm_review_output_is_proposal_only() raises:
    var products = List[String]()
    products.append("roma tomatoes")
    var statuses = interpret_product_statuses(products, "offered")
    var changes = List[ProposedSupplyChange]()
    var review = review_required("withdrawal.target", "ambiguous_target")
    var execution = execution_meta("complete", 0, None, None, None)
    var output = assemble_farm_output(statuses, changes, review, execution)
    assert_equal(len(output.claims), 1)
    assert_true(output.review.required)
    assert_true(output.original_source_preserved)
    assert_equal(output.hyf_business_writes, 0)
    assert_true(not missing_optional_price_blocks_draft())
    assert_true(ambiguous_withdrawal_blocks_apply())


from hyf_application.farm_clarification import (
    apply_farm_clarification,
    clarification_overwrites_original,
    farm_clarification_is_stale,
)


def test_farm_clarification_is_revisioned_new_evidence() raises:
    var refined = apply_farm_clarification(
        "80", "quantity.unreserved", "farm-source-1", "r2",
        "60 lb unreserved", "60",
    )
    assert_equal(refined.value.value(), "60")
    assert_equal(refined.method, "clarification")
    assert_true(not clarification_overwrites_original())
    assert_true(
        not farm_clarification_is_stale(
            "quantity.unreserved", "farm-source-1", "r2", "60 lb", "r2"
        )
    )
    assert_true(
        farm_clarification_is_stale(
            "quantity.unreserved", "farm-source-1", "r2", "60 lb", "r3"
        )
    )
