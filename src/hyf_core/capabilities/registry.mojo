from std.collections import List, Optional

from mojson import Value

from hyf_core.capabilities.explain_result import execute_explain_result
from hyf_core.capabilities.query_rewrite import execute_query_rewrite
from hyf_core.capabilities.query_rewrite import (
    execute_query_rewrite_with_runtime_config,
)
from hyf_core.capabilities.semantic_rank import execute_semantic_rank
from hyf_core.errors import (
    CapabilityResult,
    capability_not_implemented_error,
    failed_capability,
)
from hyf_core.request_context import RequestContext
from hyf_runtime.config import HyfLoadedRuntimeConfig


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


def execute_registered_business_capability_with_runtime_config(
    capability_id: String,
    input: Value,
    context: RequestContext,
    runtime_config: HyfLoadedRuntimeConfig,
) raises -> CapabilityResult:
    if capability_id == "query_rewrite":
        return execute_query_rewrite_with_runtime_config(
            input, context, runtime_config
        )
    return execute_registered_business_capability(
        capability_id, input, context
    )
