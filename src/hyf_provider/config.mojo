from hyf_runtime.config import (
    HyfLoadedRuntimeConfig,
    max_local_provider_configured,
)


@fieldwise_init
struct MaxLocalProviderConfig(Copyable, Movable):
    var base_url: String
    var health_url: String
    var model: String
    var route: String
    var request_timeout_ms: Int


def max_local_provider_config_from_runtime(
    config: HyfLoadedRuntimeConfig,
) raises -> MaxLocalProviderConfig:
    if not max_local_provider_configured(config):
        raise Error("max_local provider runtime is not configured")

    var source = config.effective.assisted.max_local.copy()
    return MaxLocalProviderConfig(
        base_url=String(source.base_url),
        health_url=String(source.health_url),
        model=String(source.model),
        route=String(source.route),
        request_timeout_ms=source.request_timeout_ms,
    )
