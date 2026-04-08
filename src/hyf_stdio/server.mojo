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
from hyf_core.errors import CapabilityFailure, CapabilitySuccess
from hyf_stdio.codec import decode_request, encode_error, encode_success
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
        request_id=String(request.request_id),
        error=unsupported_capability_error(String(request.capability)),
    )


def _disabled_response(request: WireRequest) -> WireErrorResponse:
    return WireErrorResponse(
        request_id=String(request.request_id),
        error=capability_disabled_error(String(request.capability)),
    )


def _unavailable_response(request: WireRequest) -> WireErrorResponse:
    return WireErrorResponse(
        request_id=String(request.request_id),
        error=capability_unavailable_error(String(request.capability)),
    )


def _write_error(response: WireErrorResponse) raises:
    print(encode_error(response))


def _write_success(response: WireSuccessResponse) raises:
    print(encode_success(response))


def _wire_error_from_core_failure(
    request_id: String, failure: CapabilityFailure
) -> WireErrorResponse:
    var code = String(failure.error.code)
    if code == "invalid_input":
        code = "invalid_request"
    return WireErrorResponse(
        request_id=request_id,
        error=WireError(code=code, message=String(failure.error.message)),
    )


def _wire_success_from_core_success(
    request_id: String, success: CapabilitySuccess
) raises -> WireSuccessResponse:
    var meta: Optional[Value] = None
    if success.meta:
        meta = serialize_core_response_meta(success.meta.value())
    return WireSuccessResponse(
        request_id=request_id,
        output=success.output.clone(),
        meta=meta^,
    )


def _write_query_rewrite(request: WireRequest, request_id: String) raises:
    var result = execute_query_rewrite(
        request.input.clone(), request.context.copy()
    )
    if result.failure:
        _write_error(_wire_error_from_core_failure(request_id, result.failure.value()))
        return
    _write_success(
        _wire_success_from_core_success(request_id, result.success.value())
    )


def _write_semantic_rank(request: WireRequest, request_id: String) raises:
    var result = execute_semantic_rank(
        request.input.clone(), request.context.copy()
    )
    if result.failure:
        _write_error(_wire_error_from_core_failure(request_id, result.failure.value()))
        return
    _write_success(
        _wire_success_from_core_success(request_id, result.success.value())
    )


def _write_explain_result(request: WireRequest, request_id: String) raises:
    var result = execute_explain_result(
        request.input.clone(), request.context.copy()
    )
    if result.failure:
        _write_error(_wire_error_from_core_failure(request_id, result.failure.value()))
        return
    _write_success(
        _wire_success_from_core_success(request_id, result.success.value())
    )


def run_stdio_server() raises:
    if stdin.isatty():
        return

    try:
        var line = _read_request_line()

        try:
            var request = decode_request(line)
            var request_id = String(request.request_id)

            try:
                if request.capability == "sys.status":
                    _write_success(
                        WireSuccessResponse(
                            request_id=request_id,
                            output=build_status_output(),
                            meta=None,
                        )
                    )
                elif request.capability == "sys.capabilities":
                    _write_success(
                        WireSuccessResponse(
                            request_id=request_id,
                            output=build_capabilities_output(),
                            meta=None,
                        )
                    )
                elif request.capability == "query_rewrite":
                    _write_query_rewrite(request^, request_id)
                elif request.capability == "semantic_rank":
                    _write_semantic_rank(request^, request_id)
                elif request.capability == "explain_result":
                    _write_explain_result(request^, request_id)
                elif is_deferred_capability(request.capability):
                    _write_error(_disabled_response(request))
                elif is_known_business_capability(request.capability):
                    _write_error(_unavailable_response(request))
                else:
                    _write_error(_unsupported_response(request))
            except e:
                _write_error(
                    WireErrorResponse(
                        request_id=request_id,
                        error=internal_error(String(e)),
                    )
                )
        except e:
            _write_error(
                WireErrorResponse(
                    request_id="",
                    error=invalid_request_error(String(e)),
                )
            )
    except e:
        if String(e) == "EOF":
            return
        raise e^
