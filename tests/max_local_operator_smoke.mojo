from std.sys import argv

from json import Value

from hyf_assist.contract import max_local_query_rewrite_route
from stdio_process_helper import run_stdio_entrypoint

comptime _CONFIG_EQUALS_PREFIX = "--config="
comptime _CONFIG_EQUALS_PREFIX_BYTE_LENGTH = 9


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _require_config_path() raises -> String:
    var raw_args = argv()
    var index = 1
    while index < len(raw_args):
        var arg = String(raw_args[index])
        if arg == "--config":
            if index + 1 >= len(raw_args):
                raise Error("--config requires a path")
            var value = String(String(raw_args[index + 1]).strip())
            if value == "" or value.startswith("-"):
                raise Error("--config requires a path")
            return value^
        if arg.startswith(_CONFIG_EQUALS_PREFIX):
            var value = String(
                String(arg[byte=_CONFIG_EQUALS_PREFIX_BYTE_LENGTH:]).strip()
            )
            if value == "":
                raise Error("--config requires a path")
            return value^
        raise Error("unknown smoke argument '" + arg + "'")
    raise Error("MAX-local smoke requires --config <path>")


def _smoke_request_json() -> String:
    return (
        '{"version":1,"request_id":"max-local-operator-smoke-1","trace_id":"max-local-operator-smoke-1","capability":"query_rewrite","context":{"execution_mode_preference":"assisted","return_provenance":true,"deadline_ms":15000},"input":{"query":"local'
        ' apples pickup this weekend"}}'
    )


def _assert_successful_provider_response(response: Value) raises:
    if not response["ok"].bool_value():
        raise Error("MAX-local smoke response was not ok")
    if response["meta"]["execution_mode"].string_value() != "assisted":
        raise Error("MAX-local smoke did not use assisted execution")
    if response["meta"]["backend"].string_value() != "provider_runtime":
        raise Error("MAX-local smoke did not use provider_runtime")
    if response["meta"]["provider"].string_value() != "max_local":
        raise Error("MAX-local smoke did not use max_local provider")
    if (
        response["meta"]["route"].string_value()
        != max_local_query_rewrite_route()
    ):
        raise Error("MAX-local smoke route did not match derived route")
    if response["output"]["rewritten_text"].string_value() == "":
        raise Error("MAX-local smoke returned empty rewritten_text")
    if _has_key(response["meta"], "fallback_kind"):
        raise Error("MAX-local smoke unexpectedly returned fallback metadata")
    if _has_key(response["meta"], "fallback_reason"):
        raise Error("MAX-local smoke unexpectedly returned fallback metadata")


def main() raises:
    var config_path = _require_config_path()
    var response = run_stdio_entrypoint(
        "src/main.mojo",
        _smoke_request_json(),
        "--config",
        config_path,
    )
    _assert_successful_provider_response(response)
    print("ok")
