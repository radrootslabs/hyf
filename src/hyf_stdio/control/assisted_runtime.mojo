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
from hyf_provider.config import max_local_provider_config_from_runtime
from hyf_provider.max_local import max_local_provider_status


def _base_status(
    configured: Bool,
    transport: String,
    endpoint: String,
    backend_kind: String,
    provider: String,
    route: String,
    model: String,
    reachable: Bool,
    state: String,
    reason: String,
) -> AssistedRuntimeStatus:
    return AssistedRuntimeStatus(
        id=provider_runtime_id(),
        kind="provider_runtime",
        contract_version=assisted_runtime_contract_version(),
        transport=String(transport),
        endpoint=String(endpoint),
        backend_kind=String(backend_kind),
        provider=String(provider),
        route=String(route),
        model=String(model),
        configured=configured,
        reachable=reachable,
        state=String(state),
        reason=String(reason),
        fallback_contract="deterministic_baseline_preserved",
        supported_business_capabilities=assisted_runtime_supported_business_capabilities(),
    )


def resolve_assisted_runtime_status(
    config: HyfLoadedRuntimeConfig,
) -> AssistedRuntimeStatus:
    if config.load_state == "invalid":
        return _base_status(
            configured=False,
            transport="deferred",
            endpoint="",
            backend_kind="max_local",
            provider="max_local",
            route="",
            model="",
            reachable=False,
            state="invalid_config",
            reason="invalid_config",
        )

    if not assisted_execution_enabled(config):
        return _base_status(
            configured=False,
            transport="deferred",
            endpoint="",
            backend_kind="deferred",
            provider="",
            route="",
            model="",
            reachable=False,
            state="disabled_by_runtime_config",
            reason="disabled_by_runtime_config",
        )

    if not assisted_runtime_configured(config):
        return _base_status(
            configured=False,
            transport="deferred",
            endpoint="",
            backend_kind="deferred",
            provider="",
            route="",
            model="",
            reachable=False,
            state="unconfigured",
            reason="not_checked",
        )

    try:
        var provider_config = max_local_provider_config_from_runtime(config)
        var status = max_local_provider_status(provider_config)
        return _base_status(
            configured=True,
            transport="http",
            endpoint=String(provider_config.health_url),
            backend_kind=String(status.backend_kind),
            provider=String(status.provider),
            route=String(status.route),
            model=String(status.model),
            reachable=status.reachable,
            state=String(status.state),
            reason=String(status.reason),
        )
    except e:
        return _base_status(
            configured=True,
            transport="http",
            endpoint="",
            backend_kind="max_local",
            provider="max_local",
            route="",
            model="",
            reachable=False,
            state="invalid_config",
            reason="invalid_config",
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
    return capability_id == "query_rewrite" and status.state == "ready"


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
    value.set("reason", Value(String(status.reason)))
    if status.provider != "":
        value.set("provider", Value(String(status.provider)))
    if status.route != "":
        value.set("route", Value(String(status.route)))
    if status.model != "":
        value.set("model", Value(String(status.model)))
    value.set("fallback_contract", Value(String(status.fallback_contract)))

    var capabilities = loads("[]")
    for capability in status.supported_business_capabilities:
        capabilities.append(Value(String(capability)))
    value.set("supported_business_capabilities", capabilities)
    return value^
