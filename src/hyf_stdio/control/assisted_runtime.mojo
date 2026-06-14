from std.collections import List

from json import Value, loads

from hyf_assist.contract import (
    AssistedRuntimeStatus,
    assisted_runtime_contract_version,
    assisted_runtime_supported_business_capabilities,
    provider_runtime_id,
)
from hyf_runtime.config import (
    HyfLoadedRuntimeConfig,
    assisted_runtime_configured,
    assisted_execution_enabled,
)


def resolve_assisted_runtime_status(
    config: HyfLoadedRuntimeConfig,
) -> AssistedRuntimeStatus:
    var configured = assisted_runtime_configured(config)
    var state = "disabled_by_runtime_config"
    if assisted_execution_enabled(config):
        state = "unavailable" if configured else "unconfigured"

    return AssistedRuntimeStatus(
        id=provider_runtime_id(),
        kind="provider_runtime",
        contract_version=assisted_runtime_contract_version(),
        transport="deferred",
        endpoint="",
        backend_kind="deferred",
        provider="",
        route="",
        model="",
        configured=configured,
        reachable=False,
        state=state,
        fallback_contract="deterministic_baseline_preserved",
        supported_business_capabilities=assisted_runtime_supported_business_capabilities(),
    )


def assisted_execution_state_for_capability(
    status: AssistedRuntimeStatus, capability_id: String
) -> String:
    if capability_id != "query_rewrite":
        return "unsupported_capability"
    if status.state == "disabled_by_runtime_config":
        return "disabled_by_runtime_config"
    return status.state


def assisted_backend_available_for_capability(
    status: AssistedRuntimeStatus, capability_id: String
) -> Bool:
    return False


def serialize_assisted_runtime_status_value(
    status: AssistedRuntimeStatus,
) raises -> Value:
    var value = loads("{}")
    value.set("id", Value(String(status.id)))
    value.set("kind", Value(String(status.kind)))
    value.set("contract_version", Value(status.contract_version))
    value.set("transport", Value(String(status.transport)))
    if status.endpoint != "":
        value.set("endpoint", Value(String(status.endpoint)))
    value.set("backend_kind", Value(String(status.backend_kind)))
    value.set("configured", Value(status.configured))
    value.set("reachable", Value(status.reachable))
    value.set("state", Value(String(status.state)))
    value.set("fallback_contract", Value(String(status.fallback_contract)))

    var capabilities = loads("[]")
    for capability in status.supported_business_capabilities:
        capabilities.append(Value(String(capability)))
    value.set("supported_business_capabilities", capabilities)
    return value^
