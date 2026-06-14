from hyf_provider.client import make_max_local_http_client
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.result import MaxLocalProviderStatus


def _provider_status(
    config: MaxLocalProviderConfig,
    reachable: Bool,
    state: String,
    reason: String,
) -> MaxLocalProviderStatus:
    return MaxLocalProviderStatus(
        backend_kind="max_local",
        provider="max_local",
        route=String(config.route),
        model=String(config.model),
        reachable=reachable,
        state=String(state),
        reason=String(reason),
    )


def _classify_health_error(message: String) -> String:
    var lower = message.lower()
    if lower.find("timeout") >= 0 or lower.find("timed out") >= 0:
        return "timeout"
    if lower.find("url") >= 0 or lower.find("scheme") >= 0:
        return "invalid_url"
    return "connection_failed"


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
        return _provider_status(
            config,
            False,
            "unavailable",
            _classify_health_error(String(e)),
        )
