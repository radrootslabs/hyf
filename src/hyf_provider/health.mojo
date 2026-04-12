from hyf_provider.client import make_max_local_http_client
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.result import MaxLocalProviderStatus


def resolve_max_local_provider_status(
    config: MaxLocalProviderConfig,
) -> MaxLocalProviderStatus:
    try:
        with make_max_local_http_client(config) as client:
            var response = client.get(config.health_url)
            var reachable = response.ok()
            return MaxLocalProviderStatus(
                backend_kind="max_local",
                provider="max_local",
                route=String(config.route),
                model=String(config.model),
                reachable=reachable,
                state="ready" if reachable else "unavailable",
            )
    except:
        pass

    return MaxLocalProviderStatus(
        backend_kind="max_local",
        provider="max_local",
        route=String(config.route),
        model=String(config.model),
        reachable=False,
        state="unavailable",
    )
