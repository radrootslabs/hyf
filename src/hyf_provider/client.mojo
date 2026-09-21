from std.collections import Optional
from std.time import perf_counter_ns

from json import Value
from flare.http import HttpClient

from hyf_provider.config import MaxLocalProviderConfig


@fieldwise_init
struct MaxLocalTransportResponse(Copyable, Movable):
    var status: Int
    var body_text: String
    var latency_ms: Int


@fieldwise_init
struct MaxLocalTransportFailure(Copyable, Movable):
    var kind: String
    var reason: String


@fieldwise_init
struct MaxLocalTransportOutcome(Copyable, Movable):
    var response: Optional[MaxLocalTransportResponse]
    var failure: Optional[MaxLocalTransportFailure]


def _trim_trailing_slash(url: String) -> String:
    if url.endswith("/") and url.byte_length() > 1:
        return String(url[byte = 0 : url.byte_length() - 1])
    return String(url)


def _http_url(url: String) -> Bool:
    return url.startswith("http://") or url.startswith("https://")


def _elapsed_ms_since(start_ns: UInt) -> Int:
    return Int((perf_counter_ns() - start_ns) // 1_000_000)


def _transport_response_outcome(
    status: Int, body_text: String, latency_ms: Int
) -> MaxLocalTransportOutcome:
    return MaxLocalTransportOutcome(
        response=Optional[MaxLocalTransportResponse](
            MaxLocalTransportResponse(
                status=status,
                body_text=String(body_text),
                latency_ms=latency_ms,
            )
        ),
        failure=Optional[MaxLocalTransportFailure](None),
    )


def _transport_failure_outcome(
    kind: String, reason: String
) -> MaxLocalTransportOutcome:
    return MaxLocalTransportOutcome(
        response=Optional[MaxLocalTransportResponse](None),
        failure=Optional[MaxLocalTransportFailure](
            MaxLocalTransportFailure(kind=String(kind), reason=String(reason))
        ),
    )


def _transport_exception_reason(
    start_ns: UInt, request_timeout_ms: Int
) -> String:
    if _elapsed_ms_since(start_ns) >= request_timeout_ms:
        return "timeout"
    return "unknown_transport"


def make_max_local_http_client(config: MaxLocalProviderConfig) -> HttpClient:
    return HttpClient(timeout_ms=config.request_timeout_ms)


def max_local_chat_completions_url(config: MaxLocalProviderConfig) -> String:
    return _trim_trailing_slash(config.base_url) + "/chat/completions"


def get_max_local_health(
    config: MaxLocalProviderConfig,
) -> MaxLocalTransportOutcome:
    if not _http_url(config.health_url):
        return _transport_failure_outcome("transport", "invalid_url")

    var start_ns = perf_counter_ns()
    try:
        with make_max_local_http_client(config) as client:
            var response = client.get(config.health_url)
            var latency_ms = _elapsed_ms_since(start_ns)
            if not response.ok():
                return _transport_failure_outcome("http_status", "non_2xx")
            return _transport_response_outcome(
                response.status, response.text(), latency_ms
            )
    except:
        return _transport_failure_outcome(
            "transport",
            _transport_exception_reason(start_ns, config.request_timeout_ms),
        )


def post_max_local_chat_completion(
    config: MaxLocalProviderConfig, body: Value
) -> MaxLocalTransportOutcome:
    var url = max_local_chat_completions_url(config)
    if not _http_url(url):
        return _transport_failure_outcome("transport", "invalid_url")

    var start_ns = perf_counter_ns()
    try:
        with make_max_local_http_client(config) as client:
            var response = client.post(url, body)
            var latency_ms = _elapsed_ms_since(start_ns)
            if not response.ok():
                return _transport_failure_outcome(
                    "http_status", "provider_non_2xx"
                )
            return _transport_response_outcome(
                response.status, response.text(), latency_ms
            )
    except:
        return _transport_failure_outcome(
            "transport",
            _transport_exception_reason(start_ns, config.request_timeout_ms),
        )
