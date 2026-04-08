from std.io.io import _fdopen
from std.sys import stdin

from hyf_core.capabilities.registry import (
    is_deferred_capability,
    is_known_business_capability,
)
from hyf_stdio.codec import decode_request, encode_error, encode_success
from hyf_stdio.control.capabilities import build_capabilities_output
from hyf_stdio.control.status import build_status_output
from hyf_stdio.envelope import (
    WireErrorResponse,
    WireRequest,
    WireSuccessResponse,
)
from hyf_stdio.errors import (
    capability_disabled_error,
    capability_unavailable_error,
    internal_error,
    invalid_request_error,
    unsupported_capability_error,
)


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
                        )
                    )
                elif request.capability == "sys.capabilities":
                    _write_success(
                        WireSuccessResponse(
                            request_id=request_id,
                            output=build_capabilities_output(),
                        )
                    )
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
