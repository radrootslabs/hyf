from std.os import getenv

from hyf_runtime.config import (
    HyfLoadedRuntimeConfig,
    assisted_execution_enabled,
    provider_disabled,
    typesafe_provider_configured,
)


@fieldwise_init
struct JevComposition(Copyable, Movable):
    var usable: Bool
    var base_url: String
    var model: String
    var request_timeout_ms: Int
    var reason: String


def typesafe_api_key_present() -> Bool:
    return getenv("TYPESAFE_API_KEY", "") != ""


def compose_jev(config: HyfLoadedRuntimeConfig) raises -> JevComposition:
    var typesafe = config.effective.assisted.typesafe.copy()
    if provider_disabled(config):
        return JevComposition(
            usable=False, base_url="", model="", request_timeout_ms=0,
            reason="provider_disabled",
        )
    if not assisted_execution_enabled(config):
        return JevComposition(
            usable=False, base_url="", model="", request_timeout_ms=0,
            reason="disabled_by_runtime_config",
        )
    if not typesafe_provider_configured(config):
        return JevComposition(
            usable=False, base_url="", model="", request_timeout_ms=0,
            reason="provider_unconfigured",
        )
    if not typesafe_api_key_present():
        return JevComposition(
            usable=False,
            base_url=String(typesafe.base_url),
            model=String(typesafe.model),
            request_timeout_ms=typesafe.request_timeout_ms,
            reason="missing_credentials",
        )
    return JevComposition(
        usable=True,
        base_url=String(typesafe.base_url),
        model=String(typesafe.model),
        request_timeout_ms=typesafe.request_timeout_ms,
        reason="ready",
    )
