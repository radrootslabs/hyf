from std.io.io import _fdopen
from std.sys import stdin

from hyf_stdio.codec import decode_request, encode_error
from hyf_stdio.envelope import WireErrorResponse, WireRequest
from hyf_stdio.errors import (
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


def _write_response(response: WireErrorResponse) raises:
    print(encode_error(response))


def run_stdio_server() raises:
    if stdin.isatty():
        return

    try:
        var line = _read_request_line()

        try:
            var request = decode_request(line)
            var request_id = String(request.request_id)

            try:
                _write_response(_unsupported_response(request))
            except e:
                _write_response(
                    WireErrorResponse(
                        request_id=request_id,
                        error=internal_error(String(e)),
                    )
                )
        except e:
            _write_response(
                WireErrorResponse(
                    request_id="",
                    error=invalid_request_error(String(e)),
                )
            )
    except e:
        if String(e) == "EOF":
            return
        raise e^
