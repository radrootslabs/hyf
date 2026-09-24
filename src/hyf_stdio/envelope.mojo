from std.collections import Dict, Optional

from json import Value, loads
from json.deserialize import Deserializable, get_string

from hyf_core.metadata import hyf_protocol_version
from hyf_core.operation_context import (
    OperationContext,
    context_selects_v2_any,
    is_corrected_operation,
    operation_context_selects_v2,
    parse_operation_context,
)
from hyf_core.request_context import (
    RequestContext,
    default_request_context,
    parse_request_context,
)
from hyf_stdio.errors import WireError


def _require_object(value: Value, context: String) raises:
    if not value.is_object():
        raise Error(context + " must be a JSON object")


def _require_non_empty(value: String, field_name: String) raises:
    if value == "":
        raise Error(
            "request envelope field '" + field_name + "' must not be empty"
        )


def _require_request_keys(value: Value) raises:
    for key in value.object_keys():
        if (
            key != "version"
            and key != "request_id"
            and key != "trace_id"
            and key != "capability"
            and key != "context"
            and key != "input"
        ):
            raise Error(
                "request envelope contains unexpected field '" + key + "'"
            )


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _first_duplicate_root_key(value: Value) raises -> Optional[String]:
    # ADR-0026 D46 CR04: decoded-key identity across every raw object entry, so
    # escaped equivalents (`\u0063ontext`) and repeated values are both found
    # rather than only the first `value[key]` lookup.
    var seen = Dict[String, Bool]()
    for item in value.object_items():
        var key = String(item[0])
        if key in seen:
            return Optional[String](key)
        seen[key] = True
    return None


def envelope_targets_corrected_v2(json: Value) raises -> Bool:
    """True when an envelope contains a corrected-op capability value or a
    duplicate-aware v2 context selector.

    Scans every raw root entry, so a duplicated `capability` or `context` key
    cannot hide a corrected-operation value or a v2 selector behind an earlier
    legacy entry.
    """
    for item in json.object_items():
        if item[0] == "capability" and item[1].is_string():
            if is_corrected_operation(String(item[1].string_value())):
                return True
        elif item[0] == "context":
            if context_selects_v2_any(item[1]):
                return True
    return False


def _require_protocol_version(json: Value) raises -> Int:
    if not _has_key(json, "version"):
        raise Error("request envelope field 'version' is required")

    var version = json["version"]
    if not version.is_int():
        raise Error("request envelope field 'version' must be an integer")

    var version_value = Int(version.int_value())
    if version_value != hyf_protocol_version():
        raise Error(
            "request envelope version "
            + String(version_value)
            + " is unsupported; expected "
            + String(hyf_protocol_version())
        )
    return version_value


def _parse_optional_trace_id(json: Value) raises -> Optional[String]:
    if not _has_key(json, "trace_id"):
        return None

    var trace_id = get_string(json, "trace_id")
    _require_non_empty(trace_id, "trace_id")
    return String(trace_id)


def _require_input_value(json: Value) raises -> Value:
    if not _has_key(json, "input"):
        raise Error("request envelope field 'input' is required")

    var input = json["input"]
    if not input.is_object():
        raise Error("request envelope field 'input' must be a JSON object")
    return input.clone()


@fieldwise_init
struct WireRequest(Copyable, Deserializable, Movable):
    var version: Int
    var request_id: String
    var trace_id: Optional[String]
    var capability: String
    var context: RequestContext
    var input: Value
    # ADR-0025 D45 CB01: present only for a recognized hyf_ops_v2 request to one
    # of the three corrected operations. Legacy requests leave this None and
    # keep the unchanged legacy context.
    var operation_context: Optional[OperationContext]

    @staticmethod
    def from_json(json: Value) raises -> Self:
        _require_object(json, "request envelope")
        # ADR-0026 D46 CR04: reject ambiguous duplicate top-level keys before
        # first-wins lookup/selector dispatch for any envelope that targets a
        # corrected-operation capability or a v2 context selector. Unrelated
        # legacy capabilities keep their existing admission behavior.
        if envelope_targets_corrected_v2(json):
            var duplicate = _first_duplicate_root_key(json)
            if duplicate:
                raise Error(
                    "request envelope contains duplicate top-level field '"
                    + duplicate.value()
                    + "'"
                )
        _require_request_keys(json)
        var version = _require_protocol_version(json)

        var request_id = get_string(json, "request_id")
        _require_non_empty(request_id, "request_id")

        var trace_id = _parse_optional_trace_id(json)

        var capability = get_string(json, "capability")
        _require_non_empty(capability, "capability")

        var context_json = Value(None)
        if _has_key(json, "context"):
            context_json = json["context"].clone()

        var context = default_request_context()
        var operation_context: Optional[OperationContext] = None
        if is_corrected_operation(capability) and operation_context_selects_v2(
            context_json
        ):
            operation_context = parse_operation_context(
                context_json.clone(), capability
            )
        else:
            context = parse_request_context(context_json)
        var input = _require_input_value(json)

        return Self(
            version=version,
            request_id=request_id,
            trace_id=trace_id^,
            capability=capability,
            context=context^,
            input=input^,
            operation_context=operation_context^,
        )


@fieldwise_init
struct WireSuccessResponse(Copyable, Movable):
    var version: Int
    var request_id: String
    var trace_id: Optional[String]
    var output: Value
    var meta: Optional[Value]

    def to_json_value(self) raises -> Value:
        var value = loads("{}")
        value.set("version", Value(self.version))
        value.set("request_id", Value(String(self.request_id)))
        if self.trace_id:
            value.set("trace_id", Value(String(self.trace_id.value())))
        value.set("ok", Value(True))
        value.set("output", self.output.clone())
        if self.meta:
            value.set("meta", self.meta.value().clone())
        return value^


@fieldwise_init
struct WireErrorResponse(Copyable, Movable):
    var version: Int
    var request_id: String
    var trace_id: Optional[String]
    var error: WireError

    def to_json_value(self) raises -> Value:
        var value = loads("{}")
        value.set("version", Value(self.version))
        value.set("request_id", Value(String(self.request_id)))
        if self.trace_id:
            value.set("trace_id", Value(String(self.trace_id.value())))
        value.set("ok", Value(False))
        value.set("error", self.error.to_json_value())
        return value^
