from hyf_assist.contract import max_local_query_rewrite_route
from hyf_provider.client import make_max_local_http_client
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.result import MaxLocalProviderStatus


@fieldwise_init
struct MaxLocalHealthFailure(Copyable, Movable):
    var kind: String
    var reason: String


def _health_failure(kind: String, reason: String) -> MaxLocalHealthFailure:
    return MaxLocalHealthFailure(kind=String(kind), reason=String(reason))


def _provider_status(
    config: MaxLocalProviderConfig,
    reachable: Bool,
    state: String,
    reason: String,
) -> MaxLocalProviderStatus:
    return MaxLocalProviderStatus(
        backend_kind="max_local",
        provider="max_local",
        route=max_local_query_rewrite_route(),
        model=String(config.model),
        reachable=reachable,
        state=String(state),
        reason=String(reason),
    )


def max_local_health_failure_from_error(
    message: String,
) -> MaxLocalHealthFailure:
    if message == "invalid_url" or message.find("invalid_url") >= 0:
        return _health_failure("transport", "invalid_url")
    if message == "timeout" or message.find("timeout") >= 0:
        return _health_failure("transport", "timeout")
    if message == "connection_failed" or message.find("connection_failed") >= 0:
        return _health_failure("transport", "connection_failed")

    var lower = message.lower()
    if lower.find("url") >= 0 or lower.find("scheme") >= 0:
        return _health_failure("transport", "invalid_url")
    if lower.find("timeout") >= 0 or lower.find("timed out") >= 0:
        return _health_failure("transport", "timeout")
    return _health_failure("transport", "connection_failed")


def resolve_max_local_provider_status(
    config: MaxLocalProviderConfig,
) -> MaxLocalProviderStatus:
    try:
        with make_max_local_http_client(config) as client:
            var response = client.get(config.health_url)
            if response.ok():
                return _provider_status(config, True, "ready", "ready")
            return _provider_status(config, False, "unavailable", "non_2xx")
    except e:
        var failure = max_local_health_failure_from_error(String(e))
        return _provider_status(
            config,
            False,
            "unavailable",
            String(failure.reason),
        )
