from mojson import dumps
from mojson.deserialize import deserialize

from hyf_stdio.envelope import (
    WireErrorResponse,
    WireRequest,
    WireSuccessResponse,
)


def decode_request(line: String) raises -> WireRequest:
    if line == "":
        raise Error("request line must not be empty")
    return deserialize[WireRequest](line)


def encode_success(response: WireSuccessResponse) raises -> String:
    return dumps(response.to_json_value())


def encode_error(response: WireErrorResponse) raises -> String:
    return dumps(response.to_json_value())
