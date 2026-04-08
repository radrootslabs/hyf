from std.collections import List


@fieldwise_init
struct BusinessCapabilityDescriptor(Copyable, Movable):
    var id: String
    var mode_a_enabled: Bool
    var implemented: Bool
    var callable: Bool
    var mode_b_available: Bool
    var disabled_reason: String


def canonical_business_capabilities() -> List[BusinessCapabilityDescriptor]:
    var capabilities = List[BusinessCapabilityDescriptor]()
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="query_rewrite",
            mode_a_enabled=True,
            implemented=True,
            callable=True,
            mode_b_available=False,
            disabled_reason="",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="filter_extraction",
            mode_a_enabled=False,
            implemented=False,
            callable=False,
            mode_b_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="semantic_rank",
            mode_a_enabled=True,
            implemented=False,
            callable=False,
            mode_b_available=False,
            disabled_reason="",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="summarize_listing",
            mode_a_enabled=False,
            implemented=False,
            callable=False,
            mode_b_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="summarize_farm",
            mode_a_enabled=False,
            implemented=False,
            callable=False,
            mode_b_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="workflow_plan",
            mode_a_enabled=False,
            implemented=False,
            callable=False,
            mode_b_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="explain_result",
            mode_a_enabled=True,
            implemented=False,
            callable=False,
            mode_b_available=False,
            disabled_reason="",
        )
    )
    capabilities.append(
        BusinessCapabilityDescriptor(
            id="dedupe_cluster",
            mode_a_enabled=False,
            implemented=False,
            callable=False,
            mode_b_available=False,
            disabled_reason="deferred_bootstrap_capability",
        )
    )
    return capabilities^


def bootstrap_capability_count() -> Int:
    return len(canonical_business_capabilities())


def bootstrap_enabled_capabilities() -> List[String]:
    var enabled = List[String]()
    for capability in canonical_business_capabilities():
        if capability.mode_a_enabled:
            enabled.append(String(capability.id))
    return enabled^


def deferred_capabilities() -> List[String]:
    var disabled = List[String]()
    for capability in canonical_business_capabilities():
        if not capability.mode_a_enabled:
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
            return not capability.mode_a_enabled
    return False
