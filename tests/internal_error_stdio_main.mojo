from std.io.io import _fdopen
from std.sys import stdin

from mojson import Value, loads

from hyf_stdio.server import handle_request_line_with_control_builders


def _read_request_line() raises -> String:
    with _fdopen["r"](stdin) as input_file:
        return input_file.readline()


def _failing_status_output() raises -> Value:
    raise Error("simulated test-only status builder failure")


def _unused_capabilities_output() raises -> Value:
    return loads("{}")


def main() raises:
    if stdin.isatty():
        return

    var line = _read_request_line()
    print(
        handle_request_line_with_control_builders[
            _failing_status_output, _unused_capabilities_output
        ](line)
    )
