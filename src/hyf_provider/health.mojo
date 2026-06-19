from hyf_assist.contract import max_local_query_rewrite_route
from hyf_provider.client import get_max_local_health
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


def max_local_health_failure_from_reason(
    reason: String,
) -> MaxLocalHealthFailure:
    if reason == "invalid_url":
        return _health_failure("transport", "invalid_url")
    if reason == "timeout":
        return _health_failure("transport", "timeout")
    if reason == "connection_failed":
        return _health_failure("transport", "connection_failed")
    if reason == "non_2xx":
        return _health_failure("http_status", "non_2xx")
    return _health_failure("transport", "connection_failed")


def resolve_max_local_provider_status(
    config: MaxLocalProviderConfig,
) -> MaxLocalProviderStatus:
    var transport = get_max_local_health(config)
    if transport.response:
        return _provider_status(config, True, "ready", "ready")

    if transport.failure:
        var failure = max_local_health_failure_from_reason(
            transport.failure.value().reason
        )
        return _provider_status(
            config,
            False,
            "unavailable",
            String(failure.reason),
        )

    return _provider_status(
        config,
        False,
        "unavailable",
        "connection_failed",
    )
