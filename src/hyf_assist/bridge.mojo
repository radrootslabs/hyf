from mojson import Value, loads

from hyf_core.capabilities.query_analysis import (
    ExtractedFilters,
    QueryAnalysis,
    analyze_query_text,
    copy_string_list,
)
from hyf_core.request_context import RequestContext
from hyf_assist.contract import (
    AssistQueryRewriteResult,
    AssistBridgeStatus,
    assist_bridge_contract_version,
    assist_bridge_fake_endpoint_prefix,
    assist_bridge_runtime_id,
    assist_bridge_supported_business_capabilities,
)
from hyf_runtime.config import (
    HyfLoadedRuntimeConfig,
    assist_bridge_configured,
    assisted_execution_enabled,
)


def _fake_bridge_endpoint_is_reachable(endpoint: String) -> Bool:
    var trimmed = String(endpoint).strip()
    return trimmed.startswith(assist_bridge_fake_endpoint_prefix())


def resolve_assist_bridge_status(
    config: HyfLoadedRuntimeConfig,
) -> AssistBridgeStatus:
    var configured = assist_bridge_configured(config)
    var state = "disabled_by_runtime_config"
    var reachable = False
    if assisted_execution_enabled(config):
        if configured:
            reachable = _fake_bridge_endpoint_is_reachable(
                config.effective.assist.endpoint
            )
            state = "ready" if reachable else "unavailable"
        else:
            state = "unconfigured"

    return AssistBridgeStatus(
        id=assist_bridge_runtime_id(),
        kind="assist_bridge",
        contract_version=assist_bridge_contract_version(),
        transport=String(config.effective.assist.transport),
        endpoint=String(config.effective.assist.endpoint),
        backend_kind="fake",
        configured=configured,
        reachable=reachable,
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


def execute_query_rewrite_via_assist_bridge(
    bridge_status: AssistBridgeStatus,
    text: String,
    context: RequestContext,
) raises -> AssistQueryRewriteResult:
    if not bridge_status.reachable:
        raise Error(
            "assist bridge '" + String(bridge_status.id) + "' is unavailable"
        )

    var analysis = analyze_query_text(text, context)
    var normalization_signals = copy_string_list(
        analysis.normalization_signals
    )
    normalization_signals.append("assist_bridge_fake")
    var ranking_hints = copy_string_list(analysis.ranking_hints)
    ranking_hints.append("assist_bridge_route")

    return AssistQueryRewriteResult(
        analysis=QueryAnalysis(
            original_text=String(analysis.original_text),
            normalized_text=String(analysis.normalized_text),
            rewritten_text=String(analysis.rewritten_text),
            query_terms=copy_string_list(analysis.query_terms),
            normalization_signals=normalization_signals^,
            ranking_hints=ranking_hints^,
            extracted_filters=ExtractedFilters(
                local_intent=analysis.extracted_filters.local_intent,
                fulfillment=String(
                    analysis.extracted_filters.fulfillment
                ),
                time_window=String(analysis.extracted_filters.time_window),
            ),
        ),
        provider="fake",
        route="assist_bridge.query_rewrite.fake",
        model="fake_query_rewrite_v1",
        latency_ms=1,
        schema_version=1,
    )
