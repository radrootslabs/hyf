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
