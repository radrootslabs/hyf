from std.io.io import _fdopen
from std.sys import stdin

from hyf_core.metadata import hyf_protocol_version
from hyf_runtime.diagnostics import effective_diagnostics_dir_for_runtime_paths
from hyf_runtime.startup import resolve_startup_context_from_process
from hyf_stdio.codec import decode_request, encode_error, extract_request_correlation
from hyf_stdio.envelope import WireErrorResponse
from hyf_stdio.errors import internal_error, invalid_request_error
from hyf_stdio.server import (
    _emit_internal_diagnostic,
)


def _read_request_line() raises -> String:
    with _fdopen["r"](stdin) as input_file:
        return input_file.readline()


def _simulated_internal_error_detail() -> String:
    return "simulated test-only status builder failure"


def main() raises:
    if stdin.isatty():
        return

    var line = _read_request_line()
    var startup_context = resolve_startup_context_from_process()
    try:
        var request = decode_request(line)
        var decoded = request^
        _emit_internal_diagnostic(
            String(decoded.request_id),
            decoded.trace_id,
            String(decoded.capability),
            _simulated_internal_error_detail(),
            effective_diagnostics_dir_for_runtime_paths(startup_context.paths),
        )
        print(
            encode_error(
                WireErrorResponse(
                    version=hyf_protocol_version(),
                    request_id=String(decoded.request_id),
                    trace_id=decoded.trace_id,
                    error=internal_error(),
                )
            )
        )
    except e:
        var correlation = extract_request_correlation(line)
        print(
            encode_error(
                WireErrorResponse(
                    version=hyf_protocol_version(),
                    request_id=correlation.request_id,
                    trace_id=correlation.trace_id,
                    error=invalid_request_error(String(e)),
                )
            )
        )
