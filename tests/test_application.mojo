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
