from std.collections import Optional
from std.io.io import _fdopen
from std.sys import stdin

from mojson import Value

from hyf_core.capabilities.explain_result import execute_explain_result
from hyf_core.capabilities.registry import (
    is_deferred_capability,
    is_known_business_capability,
)
from hyf_core.capabilities.query_rewrite import execute_query_rewrite
from hyf_core.capabilities.semantic_rank import execute_semantic_rank
from hyf_core.errors import CapabilityFailure, CapabilityResult, CapabilitySuccess
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


def _dispatch_query_rewrite(request: WireRequest, request_id: String) raises -> String:
    var result = execute_query_rewrite(
        request.input.clone(), request.context.copy()
    )
    return _dispatch_capability_result(request_id, request.trace_id, result)


def _dispatch_semantic_rank(request: WireRequest, request_id: String) raises -> String:
    var result = execute_semantic_rank(
        request.input.clone(), request.context.copy()
    )
    return _dispatch_capability_result(request_id, request.trace_id, result)


def _dispatch_explain_result(request: WireRequest, request_id: String) raises -> String:
    var result = execute_explain_result(
        request.input.clone(), request.context.copy()
    )
    return _dispatch_capability_result(request_id, request.trace_id, result)


def handle_request(request: WireRequest) raises -> String:
    var request_id = String(request.request_id)
    var trace_id = request.trace_id
    try:
        if request.capability == "sys.status":
            return encode_success(
                WireSuccessResponse(
                    version=hyf_protocol_version(),
                    request_id=request_id,
                    trace_id=trace_id,
                    output=build_status_output(),
                    meta=None,
                )
            )
        elif request.capability == "sys.capabilities":
            return encode_success(
                WireSuccessResponse(
                    version=hyf_protocol_version(),
                    request_id=request_id,
                    trace_id=trace_id,
                    output=build_capabilities_output(),
                    meta=None,
                )
            )
        elif request.capability == "query_rewrite":
            return _dispatch_query_rewrite(request.copy(), request_id)
        elif request.capability == "semantic_rank":
            return _dispatch_semantic_rank(request.copy(), request_id)
        elif request.capability == "explain_result":
            return _dispatch_explain_result(request.copy(), request_id)
        elif is_deferred_capability(request.capability):
            return encode_error(_disabled_response(request))
        elif is_known_business_capability(request.capability):
            return encode_error(_unavailable_response(request))
        return encode_error(_unsupported_response(request))
    except e:
        return encode_error(
            WireErrorResponse(
                version=hyf_protocol_version(),
                request_id=request_id,
                trace_id=trace_id,
                error=internal_error(String(e)),
            )
        )


def handle_request_line(line: String) raises -> String:
    try:
        var request = decode_request(line)
        return handle_request(request^)
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


def run_stdio_server() raises:
    if stdin.isatty():
        return

    try:
        var line = _read_request_line()

        print(handle_request_line(line))
    except e:
        if String(e) == "EOF":
            return
        raise e^
