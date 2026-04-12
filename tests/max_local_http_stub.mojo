from std.collections import List
from std.sys import argv

from flare.http import Request, Response, Status
from flare.http.server import _handle_connection
from flare.net import SocketAddr
from flare.tcp import TcpListener
from mojson import Value, dumps, loads


def _arg_value(flag: String) raises -> String:
    var args = argv()
    var index = 0
    while index < len(args):
        if args[index] == flag:
            index += 1
            if index >= len(args):
                raise Error("missing value for " + flag)
            return args[index]
        index += 1
    raise Error("missing required flag " + flag)


def _to_body(text: String) -> List[UInt8]:
    var body = List[UInt8](capacity=len(text))
    for byte in text.as_bytes():
        body.append(byte)
    return body^


def _query_rewrite_result_json() raises -> String:
    var analysis = loads("{}")
    analysis.set("original_text", Value("local apples pickup weekend"))
    analysis.set("normalized_text", Value("local apples pickup weekend"))
    analysis.set("rewritten_text", Value("apples pickup weekend"))

    var query_terms = loads("[]")
    query_terms.append(Value("apples"))
    query_terms.append(Value("pickup"))
    query_terms.append(Value("weekend"))
    analysis.set("query_terms", query_terms)

    var normalization_signals = loads("[]")
    normalization_signals.append(Value("lowercase"))
    analysis.set("normalization_signals", normalization_signals)

    var ranking_hints = loads("[]")
    ranking_hints.append(Value("local_intent"))
    analysis.set("ranking_hints", ranking_hints)

    var filters = loads("{}")
    filters.set("local_intent", Value(True))
    filters.set("fulfillment", Value("pickup"))
    filters.set("time_window", Value("weekend"))
    analysis.set("extracted_filters", filters)

    return dumps(analysis)


def _health_response() -> Response:
    return Response(
        status=Status.OK,
        reason="OK",
        body=_to_body('{"status":"ok"}'),
    )


def _query_rewrite_response() raises -> Response:
    var root = loads("{}")
    var choices = loads("[]")
    var choice = loads("{}")
    var message = loads("{}")
    message.set("content", Value(_query_rewrite_result_json()))
    choice.set("message", message)
    choices.append(choice)
    root.set("choices", choices)

    return Response(
        status=Status.OK, reason="OK", body=_to_body(dumps(root))
    )


def _health_router(request: Request) raises -> Response:
    if request.method == "GET" and request.url == "/health":
        return _health_response()
    return Response(
        status=Status.NOT_FOUND,
        reason="Not Found",
        body=_to_body("not found"),
    )


def _query_rewrite_router(request: Request) raises -> Response:
    if (
        request.method == "POST"
        and request.url == "/v1/chat/completions"
    ):
        return _query_rewrite_response()
    return Response(
        status=Status.NOT_FOUND,
        reason="Not Found",
        body=_to_body("not found"),
    )


def main() raises:
    var port = UInt16(atol(_arg_value("--port")))
    var mode = _arg_value("--mode")

    var listener = TcpListener.bind(SocketAddr.localhost(port))
    print("ready")

    var stream = listener.accept()
    if mode == "health_ok":
        _handle_connection(stream^, _health_router, 8192, 1024 * 1024)
    elif mode == "query_rewrite_ok":
        _handle_connection(
            stream^, _query_rewrite_router, 8192, 1024 * 1024
        )
    else:
        raise Error("unsupported mode " + mode)
    listener.close()
