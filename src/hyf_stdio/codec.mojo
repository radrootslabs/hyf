from std.collections import Optional

from mojson import Value, dumps, loads

from hyf_stdio.envelope import (
    WireErrorResponse,
    WireRequest,
    WireSuccessResponse,
)


@fieldwise_init
struct RequestCorrelation(Copyable, Movable):
    var request_id: String
    var trace_id: Optional[String]


def _extract_optional_string(value: Value, key: String) -> Optional[String]:
    if not value.is_object():
        return None

    for candidate in value.object_keys():
        if candidate == key:
            try:
                var field_value = value[key]
                if field_value.is_string():
                    return String(field_value.string_value())
            except e:
                pass
            return None
    return None


def decode_request(line: String) raises -> WireRequest:
    if line == "":
        raise Error("request line must not be empty")

    var json = loads(line)
    return WireRequest.from_json(json)


def extract_request_correlation(line: String) -> RequestCorrelation:
    var request_id = String()
    var trace_id: Optional[String] = None

    if line == "":
        return RequestCorrelation(request_id=request_id, trace_id=trace_id^)

    try:
        var json = loads(line)
        var extracted_request_id = _extract_optional_string(json, "request_id")
        if extracted_request_id:
            request_id = extracted_request_id.value()

        trace_id = _extract_optional_string(json, "trace_id")
    except e:
        pass

    return RequestCorrelation(request_id=request_id, trace_id=trace_id^)


def encode_success(response: WireSuccessResponse) raises -> String:
    return dumps(response.to_json_value())


def encode_error(response: WireErrorResponse) raises -> String:
    return dumps(response.to_json_value())
