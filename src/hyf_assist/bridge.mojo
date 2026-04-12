from std.collections import List, Optional
from std.ffi import CStringSlice, c_int, external_call
from std.os import Pipe, Process
from std.sys._libc import close

from mojson import Value, dumps, loads

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
    provider_runtime_id,
)
from hyf_provider.config import (
    default_max_local_provider_config,
    load_max_local_provider_config,
)
from hyf_provider.max_local import max_local_provider_status
from hyf_runtime.config import (
    HyfLoadedRuntimeConfig,
    assist_bridge_configured,
    assisted_execution_enabled,
)


def _dup2(oldfd: c_int, newfd: c_int) -> c_int:
    return external_call["dup2", c_int](oldfd, newfd)


@always_inline
def _fork() -> c_int:
    return external_call["fork", c_int]()


@always_inline
def _exit_child(code: c_int):
    _ = external_call["_exit", c_int](code)


def _read_pipe_to_string(mut pipe: Pipe) raises -> String:
    var buffer = InlineArray[Byte, 4096](fill=0)
    var output = String("")
    while True:
        var read = pipe.read_bytes(Span(buffer))
        if read == 0:
            break
        output += String(
            from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(read))
        )
    return output^


def _run_stdio_endpoint_json(endpoint: String, request_json: String) raises -> Value:
    var command = String(String(endpoint).strip())
    if command == "":
        raise Error("assist bridge endpoint must not be empty")

    var stdin_pipe = Pipe()
    var stdout_pipe = Pipe()
    var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](length=2, fill={})
    argv[0] = rebind[CStringSlice[ImmutAnyOrigin]](command.as_c_string_slice())
    var command_ptr = command.as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv.unsafe_ptr()

    var stdin_read_fd = c_int(stdin_pipe.fd_in.value().value)
    var stdin_write_fd = c_int(stdin_pipe.fd_out.value().value)
    var stdout_read_fd = c_int(stdout_pipe.fd_in.value().value)
    var stdout_write_fd = c_int(stdout_pipe.fd_out.value().value)

    var pid = _fork()
    if pid < 0:
        raise Error("failed to spawn assist bridge endpoint")

    if pid == 0:
        if _dup2(stdin_read_fd, 0) < 0:
            _exit_child(c_int(126))
        if _dup2(stdout_write_fd, 1) < 0:
            _exit_child(c_int(126))
        _ = close(stdin_read_fd)
        _ = close(stdin_write_fd)
        _ = close(stdout_read_fd)
        _ = close(stdout_write_fd)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        _exit_child(c_int(127))

    stdin_pipe.set_output_only()
    stdout_pipe.set_input_only()
    stdin_pipe.write_bytes((request_json + "\n").as_bytes())
    stdin_pipe.set_input_only()

    var output = _read_pipe_to_string(stdout_pipe)
    stdout_pipe.set_output_only()

    var process = Process(Int(pid))
    var status = process.wait()
    if not status.exit_code or status.exit_code.value() != 0:
        raise Error("assist bridge endpoint exited unexpectedly")
    if output == "":
        raise Error("assist bridge endpoint returned no stdout payload")
    return loads(output)


def _fake_bridge_endpoint_is_reachable(endpoint: String) -> Bool:
    var trimmed = String(endpoint).strip()
    return trimmed.startswith(assist_bridge_fake_endpoint_prefix())


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _string_array(value: Value, context: String) raises -> List[String]:
    if not value.is_array():
        raise Error(context + " must be an array")

    var items = List[String]()
    for item in value.array_items():
        if not item.is_string():
            raise Error(context + " items must be strings")
        items.append(item.string_value())
    return items^


def _build_status_request_json() raises -> String:
    var value = loads("{}")
    value.set("contract_version", Value(assist_bridge_contract_version()))
    value.set("request_kind", Value("status"))
    return dumps(value)


def _build_query_rewrite_request_json(
    text: String, context: RequestContext
) raises -> String:
    var value = loads("{}")
    value.set("contract_version", Value(assist_bridge_contract_version()))
    value.set("request_kind", Value("query_rewrite"))

    var input_value = loads("{}")
    input_value.set("text", Value(String(text)))
    value.set("input", input_value)

    var context_value = loads("{}")
    context_value.set("deadline_ms", Value(context.deadline_ms))
    context_value.set("evidence_limit", Value(context.evidence_limit))
    context_value.set("consistency", Value(String(context.consistency)))
    context_value.set("explain_plan", Value(context.explain_plan))

    var listing_ids = loads("[]")
    if context.scope:
        for listing_id in context.scope.value().listing_ids:
            listing_ids.append(Value(String(listing_id)))
    context_value.set("scope_listing_ids", listing_ids)

    if context.time_range:
        var time_range = loads("{}")
        time_range.set(
            "start", Value(String(context.time_range.value().start))
        )
        time_range.set("end", Value(String(context.time_range.value().end)))
        context_value.set("time_range", time_range)
    else:
        context_value.set("time_range", Value(None))

    value.set("context", context_value)
    return dumps(value)


def _resolve_real_bridge_status(endpoint: String) raises -> AssistBridgeStatus:
    var response = _run_stdio_endpoint_json(endpoint, _build_status_request_json())
    if not response.is_object():
        raise Error("assist bridge status response must be an object")
    if not _has_key(response, "ok") or not response["ok"].bool_value():
        raise Error("assist bridge status request failed")

    var supported = List[String]()
    if _has_key(response, "supported_business_capabilities"):
        supported = _string_array(
            response["supported_business_capabilities"].clone(),
            "assist bridge supported_business_capabilities",
        )

    var reachable = (
        _has_key(response, "reachable") and response["reachable"].bool_value()
    )
    var state = (
        response["state"].string_value()
        if _has_key(response, "state")
        else ("ready" if reachable else "unavailable")
    )

    return AssistBridgeStatus(
        id=(
            response["runtime_id"].string_value()
            if _has_key(response, "runtime_id")
            else assist_bridge_runtime_id()
        ),
        kind="assist_bridge",
        contract_version=(
            Int(response["contract_version"].int_value())
            if _has_key(response, "contract_version")
            else assist_bridge_contract_version()
        ),
        transport="stdio",
        endpoint=String(endpoint),
        backend_kind=(
            response["backend_kind"].string_value()
            if _has_key(response, "backend_kind")
            else "assist_bridge"
        ),
        provider=(
            response["provider"].string_value()
            if _has_key(response, "provider")
            else ""
        ),
        route=(
            response["route"].string_value()
            if _has_key(response, "route")
            else ""
        ),
        model=(
            response["model"].string_value()
            if _has_key(response, "model")
            else ""
        ),
        configured=True,
        reachable=reachable,
        state=String(state),
        fallback_contract="deterministic_baseline_preserved",
        supported_business_capabilities=supported^,
    )


def resolve_assist_bridge_status(
    config: HyfLoadedRuntimeConfig,
) -> AssistBridgeStatus:
    var provider_config = default_max_local_provider_config()
    try:
        provider_config = load_max_local_provider_config()
    except:
        pass

    var configured = assist_bridge_configured(config)
    var state = "disabled_by_runtime_config"
    var reachable = False
    var runtime_id = provider_runtime_id()
    var kind = "provider_runtime"
    var transport = "in_process"
    var endpoint = String("")
    var backend_kind = "max_local"
    var provider = ""
    var route = String(provider_config.route)
    var model = String(provider_config.model)
    var supported_capabilities = assist_bridge_supported_business_capabilities()
    if assisted_execution_enabled(config):
        if configured:
            endpoint = String(config.effective.assist.endpoint)
            if _fake_bridge_endpoint_is_reachable(endpoint):
                runtime_id = assist_bridge_runtime_id()
                kind = "assist_bridge"
                transport = String(config.effective.assist.transport)
                reachable = True
                state = "ready"
                backend_kind = "fake"
                provider = "fake"
                route = "assist_bridge.query_rewrite.fake"
                model = "fake_query_rewrite_v1"
            else:
                var resolved = max_local_provider_status(provider_config)
                reachable = resolved.reachable
                state = String(resolved.state)
                backend_kind = String(resolved.backend_kind)
                provider = String(resolved.provider)
                endpoint = ""
                supported_capabilities = assist_bridge_supported_business_capabilities()
        else:
            state = "unconfigured"

    return AssistBridgeStatus(
        id=runtime_id,
        kind=kind,
        contract_version=assist_bridge_contract_version(),
        transport=transport,
        endpoint=endpoint,
        backend_kind=String(backend_kind),
        provider=String(provider),
        route=String(route),
        model=String(model),
        configured=configured,
        reachable=reachable,
        state=state,
        fallback_contract="deterministic_baseline_preserved",
        supported_business_capabilities=supported_capabilities^,
    )


def assisted_execution_state_for_capability(
    bridge_status: AssistBridgeStatus, capability_id: String
) -> String:
    if capability_id != "query_rewrite":
        return "deferred"

    var unavailable_state = "provider_unavailable"
    var unconfigured_state = "provider_unconfigured"
    if bridge_status.kind == "assist_bridge":
        unavailable_state = "bridge_unavailable"
        unconfigured_state = "bridge_unconfigured"

    if bridge_status.state == "disabled_by_runtime_config":
        return "disabled_by_runtime_config"
    if bridge_status.state == "unconfigured":
        return unconfigured_state
    if bridge_status.state == "unavailable":
        return unavailable_state
    if bridge_status.reachable:
        return "enabled"
    return unavailable_state


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
    if bridge_status.endpoint != "":
        value.set("endpoint", Value(String(bridge_status.endpoint)))
    value.set("backend_kind", Value(String(bridge_status.backend_kind)))
    if bridge_status.provider != "":
        value.set("provider", Value(String(bridge_status.provider)))
    if bridge_status.route != "":
        value.set("route", Value(String(bridge_status.route)))
    if bridge_status.model != "":
        value.set("model", Value(String(bridge_status.model)))
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
    var endpoint = String(bridge_status.endpoint)
    if _fake_bridge_endpoint_is_reachable(endpoint):
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

    if not bridge_status.reachable:
        raise Error(
            "assist bridge '" + String(bridge_status.id) + "' is unavailable"
        )

    var response = _run_stdio_endpoint_json(
        endpoint, _build_query_rewrite_request_json(text, context)
    )
    if not response.is_object():
        raise Error("assist bridge query_rewrite response must be an object")
    if not _has_key(response, "ok") or not response["ok"].bool_value():
        raise Error("assist bridge query_rewrite request failed")
    if not _has_key(response, "analysis"):
        raise Error("assist bridge query_rewrite response missing analysis")

    var analysis_value = response["analysis"].clone()
    return AssistQueryRewriteResult(
        analysis=QueryAnalysis(
            original_text=analysis_value["original_text"].string_value(),
            normalized_text=analysis_value["normalized_text"].string_value(),
            rewritten_text=analysis_value["rewritten_text"].string_value(),
            query_terms=_string_array(
                analysis_value["query_terms"].clone(),
                "assist bridge query_terms",
            ),
            normalization_signals=_string_array(
                analysis_value["normalization_signals"].clone(),
                "assist bridge normalization_signals",
            ),
            ranking_hints=_string_array(
                analysis_value["ranking_hints"].clone(),
                "assist bridge ranking_hints",
            ),
            extracted_filters=ExtractedFilters(
                local_intent=analysis_value["extracted_filters"][
                    "local_intent"
                ].bool_value(),
                fulfillment=analysis_value["extracted_filters"][
                    "fulfillment"
                ].string_value(),
                time_window=analysis_value["extracted_filters"][
                    "time_window"
                ].string_value(),
            ),
        ),
        provider=response["provider"].string_value(),
        route=response["route"].string_value(),
        model=response["model"].string_value(),
        latency_ms=Int(response["latency_ms"].int_value()),
        schema_version=Int(response["schema_version"].int_value()),
    )
