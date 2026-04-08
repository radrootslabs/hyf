from std.collections import List


@fieldwise_init
struct BusinessCapabilityDescriptor(Copyable, Movable):
    var id: String
    var deterministic_enabled: Bool
    var implemented: Bool
    var callable: Bool
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


def is_known_business_capability(capability_id: String) -> Bool:
    for capability in canonical_business_capabilities():
        if capability.id == capability_id:
            return True
    return False


def is_deferred_capability(capability_id: String) -> Bool:
    for capability in canonical_business_capabilities():
        if capability.id == capability_id:
            return not capability.deterministic_enabled
    return False
