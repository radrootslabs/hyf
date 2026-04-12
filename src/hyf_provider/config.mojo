from envo import getenv_or


@fieldwise_init
struct MaxLocalProviderConfig(Defaultable, Copyable, Movable):
    var base_url: String
    var health_url: String
    var model: String
    var route: String
    var request_timeout_ms: Int

    def __init__(out self):
        self.base_url = "http://127.0.0.1:8000/v1"
        self.health_url = "http://127.0.0.1:8000/health"
        self.model = "max-local-query-rewrite"
        self.route = "provider_runtime.query_rewrite.max_local"
        self.request_timeout_ms = 15_000


def default_max_local_provider_config() -> MaxLocalProviderConfig:
    return MaxLocalProviderConfig()


def load_max_local_provider_config() raises -> MaxLocalProviderConfig:
    var config = default_max_local_provider_config()
    config.base_url = getenv_or("HYF_MAX_LOCAL_BASE_URL", config.base_url)
    config.health_url = getenv_or(
        "HYF_MAX_LOCAL_HEALTH_URL", config.health_url
    )
    config.model = getenv_or("HYF_MAX_LOCAL_MODEL", config.model)
    config.route = getenv_or("HYF_MAX_LOCAL_ROUTE", config.route)

    var timeout_value = getenv_or(
        "HYF_MAX_LOCAL_REQUEST_TIMEOUT_MS", String(config.request_timeout_ms)
    )
    var parsed_timeout = atol(timeout_value)
    if parsed_timeout > 0:
        config.request_timeout_ms = parsed_timeout

    return config^
