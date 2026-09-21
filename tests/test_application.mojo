from std.testing import TestSuite, assert_true, assert_equal

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
