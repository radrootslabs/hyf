from std.collections import Optional

from mojson import Value, loads
from mojson.deserialize import Deserializable, get_string

from hyf_core.metadata import hyf_protocol_version
from hyf_core.request_context import RequestContext, parse_request_context
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


@fieldwise_init
struct WireRequest(Deserializable, Copyable, Movable):
    var version: Int
    var request_id: String
    var trace_id: Optional[String]
    var capability: String
    var context: RequestContext
    var input: Value

    @staticmethod
    def from_json(json: Value) raises -> Self:
        _require_object(json, "request envelope")
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

        var context = parse_request_context(context_json)

        return Self(
            version=version,
            request_id=request_id,
            trace_id=trace_id^,
            capability=capability,
            context=context^,
            input=json["input"].clone(),
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
