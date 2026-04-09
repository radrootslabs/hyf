from std.collections import Optional
from std.io.io import _fdopen
from std.sys import stdin

from mojson import Value

from hyf_runtime.diagnostics import (
    append_internal_diagnostic as append_internal_diagnostic_to_dir,
    effective_diagnostics_dir_for_runtime_paths,
)
from hyf_runtime.startup import (
    RuntimeStartupContext,
    resolve_startup_context_from_process,
)
from hyf_core.backends.selector import (
    execute_capability as execute_backend_capability,
)
from hyf_core.capabilities.registry import (
    canonical_business_capability,
)
from hyf_core.errors import (
    CapabilityFailure,
    CapabilityResult,
    CapabilitySuccess,
)
from hyf_core.metadata import hyf_protocol_version
from hyf_stdio.codec import (
    decode_request,
    encode_error,
    encode_success,
    extract_request_correlation,
)
from hyf_stdio.control.capabilities import build_capabilities_output
from hyf_stdio.control.status import build_status_output
from hyf_stdio.envelope import (
    WireErrorResponse,
    WireRequest,
    WireSuccessResponse,
)
from hyf_stdio.errors import (
    WireError,
    capability_disabled_error,
    capability_unavailable_error,
    internal_error,
    invalid_request_error,
    unsupported_capability_error,
)
from hyf_stdio.meta import serialize_core_response_meta


def _read_request_line() raises -> String:
    with _fdopen["r"](stdin) as input_file:
        return input_file.readline()


def _unsupported_response(request: WireRequest) -> WireErrorResponse:
    return WireErrorResponse(
        version=hyf_protocol_version(),
        request_id=String(request.request_id),
        trace_id=request.trace_id,
        error=unsupported_capability_error(String(request.capability)),
    )


def _disabled_response(request: WireRequest) -> WireErrorResponse:
    return WireErrorResponse(
        version=hyf_protocol_version(),
        request_id=String(request.request_id),
        trace_id=request.trace_id,
        error=capability_disabled_error(String(request.capability)),
    )


def _unavailable_response(request: WireRequest) -> WireErrorResponse:
    return WireErrorResponse(
        version=hyf_protocol_version(),
        request_id=String(request.request_id),
        trace_id=request.trace_id,
        error=capability_unavailable_error(String(request.capability)),
    )


def _write_error(response: WireErrorResponse) raises:
    print(encode_error(response))


def _write_success(response: WireSuccessResponse) raises:
    print(encode_success(response))


def _diagnostic_value(value: String) -> String:
    return value.replace("\n", "\\n").replace("\r", "\\r")


def _diagnostic_trace_id(trace_id: Optional[String]) -> String:
    if trace_id:
        return _diagnostic_value(String(trace_id.value()))
    return ""


def _emit_internal_diagnostic(
    request_id: String,
    trace_id: Optional[String],
    capability: String,
    detail: String,
    diagnostics_dir: String,
):
    append_internal_diagnostic_to_dir(
        'hyf_internal_error request_id="'
        + _diagnostic_value(request_id)
        + '" trace_id="'
        + _diagnostic_trace_id(trace_id)
        + '" capability="'
        + _diagnostic_value(capability)
        + '" detail="'
        + _diagnostic_value(detail)
        + '"\n',
        diagnostics_dir,
    )


def _wire_error_from_core_failure(
    request_id: String,
    trace_id: Optional[String],
    failure: CapabilityFailure,
) -> WireErrorResponse:
    var code = String(failure.error.code)
    if code == "invalid_input":
        code = "invalid_request"
    return WireErrorResponse(
        version=hyf_protocol_version(),
        request_id=request_id,
        trace_id=trace_id,
        error=WireError(code=code, message=String(failure.error.message)),
    )


def _wire_success_from_core_success(
    request_id: String,
    trace_id: Optional[String],
    success: CapabilitySuccess,
) raises -> WireSuccessResponse:
    var meta: Optional[Value] = None
    if success.meta:
        meta = serialize_core_response_meta(success.meta.value())
    return WireSuccessResponse(
        version=hyf_protocol_version(),
        request_id=request_id,
        trace_id=trace_id,
        output=success.output.clone(),
        meta=meta^,
    )


def _dispatch_capability_result(
    request_id: String,
    trace_id: Optional[String],
    result: CapabilityResult,
) raises -> String:
    if result.failure:
        return encode_error(
            _wire_error_from_core_failure(
                request_id, trace_id, result.failure.value()
            )
        )
    return encode_success(
        _wire_success_from_core_success(
            request_id, trace_id, result.success.value()
        )
    )


def _dispatch_business_capability(
    request: WireRequest, request_id: String
) raises -> String:
    var result = execute_backend_capability(
        request.capability, request.input.clone(), request.context.copy()
    )
    return _dispatch_capability_result(request_id, request.trace_id, result)


def _route_business_capability(
    request: WireRequest, request_id: String
) raises -> String:
    var capability = canonical_business_capability(request.capability)
    if not capability:
        return encode_error(_unsupported_response(request))

    var descriptor = capability.value().copy()
    if not descriptor.deterministic_enabled:
        return encode_error(_disabled_response(request))

    if descriptor.implemented and descriptor.callable:
        return _dispatch_business_capability(request, request_id)

    return encode_error(_unavailable_response(request))


@parameter
def handle_request_with_control_builders[
    status_builder: def() raises -> Value,
    capabilities_builder: def() raises -> Value,
](request: WireRequest) raises -> String:
    return handle_request_with_runtime_context_and_control_builders[
        status_builder, capabilities_builder
    ](request, resolve_startup_context_from_process())


@parameter
def handle_request_with_runtime_context_and_control_builders[
    status_builder: def() raises -> Value,
    capabilities_builder: def() raises -> Value,
](
    request: WireRequest,
    runtime_context: RuntimeStartupContext,
) raises -> String:
    var request_id = String(request.request_id)
    var trace_id = request.trace_id
    var diagnostics_dir = effective_diagnostics_dir_for_runtime_paths(
        runtime_context.paths
    )
    try:
        if request.capability == "sys.status":
            return encode_success(
                WireSuccessResponse(
                    version=hyf_protocol_version(),
                    request_id=request_id,
                    trace_id=trace_id,
                    output=status_builder(),
                    meta=None,
                )
            )
        elif request.capability == "sys.capabilities":
            return encode_success(
                WireSuccessResponse(
                    version=hyf_protocol_version(),
                    request_id=request_id,
                    trace_id=trace_id,
                    output=capabilities_builder(),
                    meta=None,
                )
            )
        return _route_business_capability(request.copy(), request_id)
    except e:
        _emit_internal_diagnostic(
            request_id,
            trace_id,
            String(request.capability),
            String(e),
            diagnostics_dir,
        )
        return encode_error(
            WireErrorResponse(
                version=hyf_protocol_version(),
                request_id=request_id,
                trace_id=trace_id,
                error=internal_error(),
            )
        )


def handle_request(request: WireRequest) raises -> String:
    return handle_request_with_control_builders[
        build_status_output, build_capabilities_output
    ](request)


def handle_request_with_runtime_context(
    request: WireRequest, runtime_context: RuntimeStartupContext
) raises -> String:
    return handle_request_with_runtime_context_and_control_builders[
        build_status_output, build_capabilities_output
    ](request, runtime_context)


@parameter
def handle_request_line_with_control_builders[
    status_builder: def() raises -> Value,
    capabilities_builder: def() raises -> Value,
](line: String) raises -> String:
    try:
        var request = decode_request(line)
        return handle_request_with_control_builders[
            status_builder, capabilities_builder
        ](request^)
    except e:
        var correlation = extract_request_correlation(line)
        return encode_error(
            WireErrorResponse(
                version=hyf_protocol_version(),
                request_id=correlation.request_id,
                trace_id=correlation.trace_id,
                error=invalid_request_error(String(e)),
            )
        )


@parameter
def handle_request_line_with_runtime_context_and_control_builders[
    status_builder: def() raises -> Value,
    capabilities_builder: def() raises -> Value,
](line: String, runtime_context: RuntimeStartupContext) raises -> String:
    try:
        var request = decode_request(line)
        return handle_request_with_runtime_context_and_control_builders[
            status_builder, capabilities_builder
        ](request^, runtime_context)
    except e:
        var correlation = extract_request_correlation(line)
        return encode_error(
            WireErrorResponse(
                version=hyf_protocol_version(),
                request_id=correlation.request_id,
                trace_id=correlation.trace_id,
                error=invalid_request_error(String(e)),
            )
        )


def handle_request_line(line: String) raises -> String:
    return handle_request_line_with_control_builders[
        build_status_output, build_capabilities_output
    ](line)


def handle_request_line_with_runtime_context(
    line: String, runtime_context: RuntimeStartupContext
) raises -> String:
    return handle_request_line_with_runtime_context_and_control_builders[
        build_status_output, build_capabilities_output
    ](line, runtime_context)


def run_stdio_server() raises:
    run_stdio_server_with_runtime_context(
        resolve_startup_context_from_process()
    )


def run_stdio_server_with_runtime_context(
    runtime_context: RuntimeStartupContext,
) raises:
    if stdin.isatty():
        return

    try:
        var line = _read_request_line()

        print(handle_request_line_with_runtime_context(line, runtime_context))
    except e:
        if String(e) == "EOF":
            return
        raise e^
