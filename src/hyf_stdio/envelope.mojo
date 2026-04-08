from mojson import Value, loads
from mojson.deserialize import Deserializable, get_string

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
        if key != "request_id" and key != "capability" and key != "input":
            raise Error(
                "request envelope contains unexpected field '" + key + "'"
            )


@fieldwise_init
struct WireRequest(Deserializable, Copyable, Movable):
    var request_id: String
    var capability: String
    var input: Value

    @staticmethod
    def from_json(json: Value) raises -> Self:
        _require_object(json, "request envelope")
        _require_request_keys(json)

        var request_id = get_string(json, "request_id")
        _require_non_empty(request_id, "request_id")

        var capability = get_string(json, "capability")
        _require_non_empty(capability, "capability")

        return Self(
            request_id=request_id,
            capability=capability,
            input=json["input"].clone(),
        )


@fieldwise_init
struct WireSuccessResponse(Copyable, Movable):
    var request_id: String
    var output: Value

    def to_json_value(self) raises -> Value:
        var value = loads("{}")
        value.set("request_id", Value(String(self.request_id)))
        value.set("ok", Value(True))
        value.set("output", self.output.clone())
        return value^


@fieldwise_init
struct WireErrorResponse(Copyable, Movable):
    var request_id: String
    var error: WireError

    def to_json_value(self) raises -> Value:
        var value = loads("{}")
        value.set("request_id", Value(String(self.request_id)))
        value.set("ok", Value(False))
        value.set("error", self.error.to_json_value())
        return value^
