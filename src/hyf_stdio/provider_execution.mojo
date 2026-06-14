from std.collections import List, Optional

from json import Value

from hyf_core.backends.selector import (
    execute_capability as execute_backend_capability,
)
from hyf_core.capabilities.query_analysis import (
    QueryAnalysis,
    analyze_query_text,
    parse_query_rewrite_request,
    query_signal_tags,
)
from hyf_core.capabilities.query_rewrite import (
    build_query_rewrite_deterministic_fallback_meta,
    build_query_rewrite_output,
)
from hyf_core.errors import (
    CapabilityResult,
    failed_capability,
    invalid_input_error,
    successful_capability,
)
from hyf_core.provenance import (
    CoreResponseMeta,
    ExecutionProvenance,
    ProvenanceSourceRef,
)
from hyf_core.request_context import (
    RequestContext,
    assisted_execution_requested,
)
from hyf_provider.config import (
    MaxLocalProviderConfig,
    max_local_provider_config_from_runtime,
)
from hyf_provider.max_local import (
    MaxLocalQueryRewriteResult,
    execute_query_rewrite_via_max_local_provider,
    max_local_provider_status,
)
from hyf_runtime.startup import RuntimeStartupContext
from hyf_stdio.control.assisted_runtime import resolve_assisted_runtime_status


def _source_refs(
    context: RequestContext, capability_name: String
) -> List[ProvenanceSourceRef]:
    var source_refs = List[ProvenanceSourceRef]()
    source_refs.append(
        ProvenanceSourceRef(
            source_kind="local_input",
            source_ref=capability_name + ":input",
        )
    )
    if context.scope:
        source_refs.append(
            ProvenanceSourceRef(
                source_kind="request_scope",
                source_ref="request_context.scope",
            )
        )
    return source_refs^


def _provider_meta(
    context: RequestContext, result: MaxLocalQueryRewriteResult
) -> CoreResponseMeta:
    var provenance: Optional[ExecutionProvenance] = None
    if context.return_provenance:
        provenance = ExecutionProvenance(
            kind="assisted",
            signal_tags=query_signal_tags(result.analysis),
            source_refs=_source_refs(context, "query_rewrite"),
            fallback=None,
            evidence_set_id=None,
        )

    return CoreResponseMeta(
        execution_mode="assisted",
        backend="provider_runtime",
        provider=Optional[String](String(result.provider)),
        route=Optional[String](String(result.route)),
        model=Optional[String](String(result.model)),
        latency_ms=Optional[Int](result.latency_ms),
        schema_version=Optional[Int](result.schema_version),
        prompt_version=Optional[String](String(result.prompt_version)),
        provenance=provenance^,
    )


def _fallback_reason_for_runtime_state(state: String) -> String:
    if state == "disabled_by_runtime_config":
        return "disabled_by_runtime_config"
    if state == "unconfigured":
        return "provider_unconfigured"
    if state == "invalid_config":
        return "invalid_config"
    if state == "degraded":
        return "provider_degraded"
    return "provider_unavailable"


def _provider_execution_error_reason(message: String) -> String:
    var lower = message.lower()
    if lower.find("timeout") >= 0 or lower.find("timed out") >= 0:
        return "timeout"
    if lower.find("connection") >= 0:
        return "connection_failed"
    if lower.find("provider_non_2xx") >= 0 or lower.find("http") >= 0:
        return "provider_non_2xx"
    if lower.find("provider_error_payload") >= 0:
        return "provider_error_payload"
    if lower.find("provider_invalid_json") >= 0:
        return "provider_invalid_json"
    if lower.find("provider_schema_invalid") >= 0:
        return "provider_schema_invalid"
    if lower.find("provider_empty_choices") >= 0:
        return "provider_empty_choices"
    if lower.find("provider_missing_content") >= 0:
        return "provider_missing_content"
    if lower.find("provider_invalid_response") >= 0:
        return "provider_invalid_response"
    if lower.find("choices") >= 0:
        return "provider_empty_choices"
    if lower.find("content") >= 0 or lower.find("message") >= 0:
        return "provider_missing_content"
    if lower.find("json") >= 0 or lower.find("parse") >= 0:
        return "provider_invalid_json"
    if lower.find("schema") >= 0 or lower.find("required") >= 0:
        return "provider_schema_invalid"
    return "provider_error"


def _max_local_config_for_request(
    runtime_context: RuntimeStartupContext, context: RequestContext
) raises -> MaxLocalProviderConfig:
    var config = max_local_provider_config_from_runtime(
        runtime_context.config
    )
    if (
        context.deadline_ms > 0
        and config.request_timeout_ms > context.deadline_ms
    ):
        config.request_timeout_ms = context.deadline_ms
    return config^


def _query_rewrite_fallback(
    input: Value,
    context: RequestContext,
    fallback_kind: String,
    reason: String,
) raises -> CapabilityResult:
    try:
        var request = parse_query_rewrite_request(input)
        var analysis = analyze_query_text(request.text, context)
        return successful_capability(
            build_query_rewrite_output(analysis),
            meta=build_query_rewrite_deterministic_fallback_meta(
                context,
                analysis,
                fallback_kind,
                reason,
            ),
        )
    except e:
        return failed_capability(invalid_input_error(String(e)))


def _execute_query_rewrite_with_provider(
    input: Value,
    context: RequestContext,
    runtime_context: RuntimeStartupContext,
) raises -> CapabilityResult:
    var runtime_status = resolve_assisted_runtime_status(
        runtime_context.config
    )
    if runtime_status.state == "disabled_by_runtime_config":
        return _query_rewrite_fallback(
            input,
            context,
            "provider_runtime",
            _fallback_reason_for_runtime_state(runtime_status.state),
        )

    try:
        var provider_config = _max_local_config_for_request(
            runtime_context, context
        )
        var provider_status = max_local_provider_status(provider_config)
        if provider_status.state != "ready":
            return _query_rewrite_fallback(
                input,
                context,
                "provider_runtime",
                String(provider_status.reason),
            )

        var request = parse_query_rewrite_request(input)
        var result = execute_query_rewrite_via_max_local_provider(
            provider_config, request.text, context
        )
        return successful_capability(
            build_query_rewrite_output(result.analysis),
            meta=_provider_meta(context, result),
        )
    except e:
        return _query_rewrite_fallback(
            input,
            context,
            "provider_runtime",
            _provider_execution_error_reason(String(e)),
        )


def execute_runtime_aware_business_capability(
    capability_id: String,
    input: Value,
    context: RequestContext,
    runtime_context: RuntimeStartupContext,
) raises -> CapabilityResult:
    if not assisted_execution_requested(context):
        return execute_backend_capability(capability_id, input, context)

    if capability_id == "query_rewrite":
        return _execute_query_rewrite_with_provider(
            input, context, runtime_context
        )

    var deterministic_context = context.copy()
    deterministic_context.execution_mode_preference = "deterministic"
    return execute_backend_capability(
        capability_id, input, deterministic_context
    )
