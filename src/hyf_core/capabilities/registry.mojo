from std.collections import List, Optional

from json import Value

from hyf_core.capabilities.explain_result import execute_explain_result
from hyf_core.capabilities.query_rewrite import execute_query_rewrite
from hyf_core.capabilities.semantic_rank import execute_semantic_rank
from hyf_core.errors import (
    CapabilityResult,
    capability_not_implemented_error,
    failed_capability,
    invalid_input_error,
    successful_capability,
)
from hyf_core.request_context import RequestContext
from hyf_application.farm_operation import execute_farm_update_interpret


@fieldwise_init
struct BusinessCapabilityDescriptor(Copyable, Movable):
    var id: String
    var deterministic_enabled: Bool
    var implemented: Bool
    var callable: Bool
    var deterministic_backend: String
    var assisted_available: Bool
    var disabled_reason: String


def canonical_business_capabilities() -> List[BusinessCapabilityDescriptor]:
    var capabilities = List[BusinessCapabilityDescriptor]()
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="query_rewrite",
            deterministic_enabled=True,
            implemented=True,
            callable=True,
            deterministic_backend="heuristic",
            assisted_available=False,
            disabled_reason="",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="filter_extraction",
            deterministic_enabled=False,
            implemented=False,
            callable=False,
            deterministic_backend="",
            assisted_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="semantic_rank",
            deterministic_enabled=True,
            implemented=True,
            callable=True,
            deterministic_backend="heuristic",
            assisted_available=False,
            disabled_reason="",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="summarize_listing",
            deterministic_enabled=False,
            implemented=False,
            callable=False,
            deterministic_backend="",
            assisted_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="summarize_farm",
            deterministic_enabled=False,
            implemented=False,
            callable=False,
            deterministic_backend="",
            assisted_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="workflow_plan",
            deterministic_enabled=False,
            implemented=False,
            callable=False,
            deterministic_backend="",
            assisted_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="explain_result",
            deterministic_enabled=True,
            implemented=True,
            callable=True,
            deterministic_backend="heuristic",
            assisted_available=False,
            disabled_reason="",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="dedupe_cluster",
            deterministic_enabled=False,
            implemented=False,
            callable=False,
            deterministic_backend="",
            assisted_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    return capabilities^


def bootstrap_capability_count() -> Int:
    return len(canonical_business_capabilities())


def implemented_deterministic_capability_count() -> Int:
    var implemented = 0
    for capability in canonical_business_capabilities():
        if capability.deterministic_enabled and capability.implemented:
            implemented += 1
    return implemented


def deterministic_enabled_capabilities() -> List[String]:
    var enabled = List[String]()
    for capability in canonical_business_capabilities():
        if capability.deterministic_enabled:
            enabled.append(String(capability.id))
    return enabled^


def all_deterministic_capabilities_implemented() -> Bool:
    return implemented_deterministic_capability_count() == len(
        deterministic_enabled_capabilities()
    )


def deferred_capabilities() -> List[String]:
    var disabled = List[String]()
    for capability in canonical_business_capabilities():
        if not capability.deterministic_enabled:
            disabled.append(String(capability.id))
    return disabled^


def canonical_business_capability(
    capability_id: String,
) -> Optional[BusinessCapabilityDescriptor]:
    for capability in canonical_business_capabilities():
        if capability.id == capability_id:
            return Optional[BusinessCapabilityDescriptor](capability.copy())
    return Optional[BusinessCapabilityDescriptor](None)


def _dispatch_heuristic_registered_business_capability(
    capability_id: String, input: Value, context: RequestContext
) raises -> CapabilityResult:
    if capability_id == "query_rewrite":
        return execute_query_rewrite(input, context)
    if capability_id == "semantic_rank":
        return execute_semantic_rank(input, context)
    if capability_id == "explain_result":
        return execute_explain_result(input, context)
    return failed_capability(capability_not_implemented_error(capability_id))

def is_gated_operation(capability_id: String) -> Bool:
    for descriptor in gated_operation_descriptors():
        if descriptor.id == capability_id:
            return True
    return False


def execute_gated_operation(
    capability_id: String, input: Value
) raises -> CapabilityResult:
    try:
        if capability_id == "farm_update.interpret":
            return successful_capability(execute_farm_update_interpret(input))
        return failed_capability(capability_not_implemented_error(capability_id))
    except e:
        return failed_capability(invalid_input_error(String(e)))


def execute_registered_business_capability(
    capability_id: String, input: Value, context: RequestContext
) raises -> CapabilityResult:
    var capability = canonical_business_capability(capability_id)
    if not capability:
        return failed_capability(capability_not_implemented_error(capability_id))

    var descriptor = capability.value().copy()
    if (
        not descriptor.deterministic_enabled
        or not descriptor.implemented
        or not descriptor.callable
    ):
        return failed_capability(capability_not_implemented_error(capability_id))

    if descriptor.deterministic_backend == "heuristic":
        return _dispatch_heuristic_registered_business_capability(
            capability_id, input, context
        )

    return failed_capability(capability_not_implemented_error(capability_id))


@fieldwise_init
struct CapabilityExposure(Copyable, Movable):
    var capability_id: String
    var implementation_supported: Bool
    var provider_configured: Bool
    var assistance_permitted: Bool
    var provider_ready: Bool
    var exposed: Bool


def capability_assisted_supported(capability_id: String) -> Bool:
    return capability_id == "query_rewrite"


def capability_exposure(
    capability_id: String,
    provider_configured: Bool,
    assistance_permitted: Bool,
    provider_ready: Bool,
) -> CapabilityExposure:
    var supported = capability_assisted_supported(capability_id)
    return CapabilityExposure(
        capability_id=String(capability_id),
        implementation_supported=supported,
        provider_configured=provider_configured,
        assistance_permitted=assistance_permitted,
        provider_ready=provider_ready,
        exposed=(
            supported
            and provider_configured
            and assistance_permitted
            and provider_ready
        ),
    )


@fieldwise_init
struct GatedOperationDescriptor(Copyable, Movable):
    var id: String
    var requires_assistance: Bool
    var exposed: Bool


def gated_operation_descriptors() -> List[GatedOperationDescriptor]:
    var descriptors = List[GatedOperationDescriptor]()
    descriptors.append(
        GatedOperationDescriptor(
            id="farm_update.interpret", requires_assistance=False, exposed=False
        )
    )
    descriptors.append(
        GatedOperationDescriptor(
            id="buyer_request.interpret", requires_assistance=False, exposed=False
        )
    )
    descriptors.append(
        GatedOperationDescriptor(
            id="buyer_request.match", requires_assistance=False, exposed=False
        )
    )
    return descriptors^


def gated_operation_is_exposed(operation: String, exposure_enabled: Bool) -> Bool:
    for descriptor in gated_operation_descriptors():
        if descriptor.id == operation:
            return exposure_enabled
    return False
