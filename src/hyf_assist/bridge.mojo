from mojson import Value, loads

from hyf_assist.contract import (
    AssistBridgeStatus,
    assist_bridge_contract_version,
    assist_bridge_runtime_id,
    assist_bridge_supported_business_capabilities,
)
from hyf_runtime.config import (
    HyfLoadedRuntimeConfig,
    assist_bridge_configured,
    assisted_execution_enabled,
)


def resolve_assist_bridge_status(
    config: HyfLoadedRuntimeConfig,
) -> AssistBridgeStatus:
    var configured = assist_bridge_configured(config)
    var state = "disabled_by_runtime_config"
    if assisted_execution_enabled(config):
        state = "unavailable" if configured else "unconfigured"

    return AssistBridgeStatus(
        id=assist_bridge_runtime_id(),
        kind="assist_bridge",
        contract_version=assist_bridge_contract_version(),
        transport=String(config.effective.assist.transport),
        endpoint=String(config.effective.assist.endpoint),
        backend_kind="fake",
        configured=configured,
        reachable=False,
        state=state,
        fallback_contract="deterministic_baseline_preserved",
        supported_business_capabilities=assist_bridge_supported_business_capabilities(),
    )


def assisted_execution_state_for_capability(
    bridge_status: AssistBridgeStatus, capability_id: String
) -> String:
    if capability_id != "query_rewrite":
        return "deferred"

    if bridge_status.state == "disabled_by_runtime_config":
        return "disabled_by_runtime_config"
    if bridge_status.state == "unconfigured":
        return "bridge_unconfigured"
    if bridge_status.state == "unavailable":
        return "bridge_unavailable"
    if bridge_status.reachable:
        return "enabled"
    return "bridge_unavailable"


def assisted_backend_available_for_capability(
    bridge_status: AssistBridgeStatus, capability_id: String
) -> Bool:
    if not bridge_status.reachable:
        return False
    for supported in bridge_status.supported_business_capabilities:
        if supported == capability_id:
            return True
    return False


def serialize_assist_bridge_status_value(
    bridge_status: AssistBridgeStatus,
) raises -> Value:
    var value = loads("{}")
    value.set("id", Value(String(bridge_status.id)))
    value.set("kind", Value(String(bridge_status.kind)))
    value.set("contract_version", Value(bridge_status.contract_version))
    value.set("transport", Value(String(bridge_status.transport)))
    value.set("endpoint", Value(String(bridge_status.endpoint)))
    value.set("backend_kind", Value(String(bridge_status.backend_kind)))
    value.set("configured", Value(bridge_status.configured))
    value.set("reachable", Value(bridge_status.reachable))
    value.set("state", Value(String(bridge_status.state)))
    value.set(
        "fallback_contract", Value(String(bridge_status.fallback_contract))
    )

    var capabilities = loads("[]")
    for capability in bridge_status.supported_business_capabilities:
        capabilities.append(Value(String(capability)))
    value.set("supported_business_capabilities", capabilities)
    return value^
