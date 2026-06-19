from std.os.path import exists
from std.pathlib import Path

from morph.toml import from_toml


@fieldwise_init
struct HyfServiceRuntimeConfig(Defaultable, Copyable, Movable):
    var transport: String

    def __init__(out self):
        self.transport = "stdio"


@fieldwise_init
struct HyfExecutionRuntimeConfig(Defaultable, Copyable, Movable):
    var default_execution_mode: String
    var allow_assisted: Bool

    def __init__(out self):
        self.default_execution_mode = "deterministic"
        self.allow_assisted = False


@fieldwise_init
struct HyfMaxLocalProviderRuntimeConfig(Defaultable, Copyable, Movable):
    var enabled: Bool
    var base_url: String
    var health_url: String
    var model: String
    var request_timeout_ms: Int

    def __init__(out self):
        self.enabled = False
        self.base_url = ""
        self.health_url = ""
        self.model = ""
        self.request_timeout_ms = 0


@fieldwise_init
struct HyfAssistedRuntimeConfig(Defaultable, Copyable, Movable):
    var provider: String
    var max_local: HyfMaxLocalProviderRuntimeConfig

    def __init__(out self):
        self.provider = ""
        self.max_local = HyfMaxLocalProviderRuntimeConfig()


@fieldwise_init
struct HyfRuntimeConfig(Defaultable, Copyable, Movable):
    var service: HyfServiceRuntimeConfig
    var runtime: HyfExecutionRuntimeConfig
    var assisted: HyfAssistedRuntimeConfig

    def __init__(out self):
        self.service = HyfServiceRuntimeConfig()
        self.runtime = HyfExecutionRuntimeConfig()
        self.assisted = HyfAssistedRuntimeConfig()


@fieldwise_init
struct HyfLoadedRuntimeConfig(Copyable, Movable):
    var artifact_present: Bool
    var loaded: Bool
    var compiled_defaults_active: Bool
    var load_state: String
    var load_error: String
    var effective: HyfRuntimeConfig


def default_runtime_config() -> HyfRuntimeConfig:
    return HyfRuntimeConfig()


def default_loaded_runtime_config() -> HyfLoadedRuntimeConfig:
    return HyfLoadedRuntimeConfig(
        artifact_present=False,
        loaded=False,
        compiled_defaults_active=True,
        load_state="not_found",
        load_error="",
        effective=default_runtime_config(),
    )


def assisted_execution_enabled(config: HyfLoadedRuntimeConfig) -> Bool:
    return config.effective.runtime.allow_assisted


def assisted_runtime_configured(config: HyfLoadedRuntimeConfig) -> Bool:
    return (
        config.effective.runtime.allow_assisted
        and config.effective.assisted.provider == "max_local"
        and config.effective.assisted.max_local.enabled
    )


def max_local_provider_configured(config: HyfLoadedRuntimeConfig) -> Bool:
    return assisted_runtime_configured(config)


def load_runtime_config(path: String) -> HyfLoadedRuntimeConfig:
    var defaults = default_runtime_config()
    if String(path).strip() == "" or not exists(path):
        return default_loaded_runtime_config()

    try:
        var config_text = Path(path).read_text()
        _reject_removed_max_local_route_config(config_text)
        var config = from_toml[HyfRuntimeConfig](config_text)
        _validate_runtime_config(config)
        return HyfLoadedRuntimeConfig(
            artifact_present=True,
            loaded=True,
            compiled_defaults_active=False,
            load_state="loaded",
            load_error="",
            effective=config^,
        )
    except e:
        return HyfLoadedRuntimeConfig(
            artifact_present=True,
            loaded=False,
            compiled_defaults_active=True,
            load_state="invalid",
            load_error=String(e),
            effective=defaults^,
        )


def _validate_runtime_config(config: HyfRuntimeConfig) raises:
    if config.service.transport != "stdio":
        raise Error("service.transport must be 'stdio'")

    if config.runtime.default_execution_mode != "deterministic":
        raise Error(
            "runtime.default_execution_mode must be 'deterministic' in the foundation wave"
        )

    if config.assisted.provider != "":
        _require_no_boundary_whitespace(
            config.assisted.provider, "assisted.provider"
        )

    if config.runtime.allow_assisted:
        if config.assisted.provider != "max_local":
            raise Error(
                "assisted.provider must be 'max_local' when runtime.allow_assisted is true"
            )

    if config.assisted.provider != "" and config.assisted.provider != "max_local":
        raise Error("assisted.provider must be 'max_local'")

    if config.assisted.max_local.enabled:
        if not config.runtime.allow_assisted:
            raise Error(
                "runtime.allow_assisted must be true when assisted.max_local.enabled is true"
            )
        if config.assisted.provider != "max_local":
            raise Error(
                "assisted.provider must be 'max_local' when assisted.max_local.enabled is true"
            )
        _validate_max_local_provider_config(config.assisted.max_local)


def _require_non_empty(value: String, context: String) raises:
    if String(value).strip() == "":
        raise Error(context + " must not be empty")


def _require_no_boundary_whitespace(value: String, context: String) raises:
    if String(value) != String(value).strip():
        raise Error(context + " must not include leading or trailing whitespace")


def _require_http_url(value: String, context: String) raises:
    if not (value.startswith("http://") or value.startswith("https://")):
        raise Error(context + " must use http or https")


def _strip_toml_key_quotes(value: String) -> String:
    var stripped = String(String(value).strip())
    if stripped.byte_length() < 2:
        return stripped^

    var bytes = stripped.as_bytes()
    var last_index = stripped.byte_length() - 1
    if (
        bytes[0] == UInt8(ord('"'))
        and bytes[last_index] == UInt8(ord('"'))
    ):
        return String(stripped[byte=1:last_index])
    if (
        bytes[0] == UInt8(ord("'"))
        and bytes[last_index] == UInt8(ord("'"))
    ):
        return String(stripped[byte=1:last_index])
    return stripped^


def _normalize_toml_key_path(key: String) -> String:
    var normalized = String("")
    for raw_part in key.split("."):
        var part = _strip_toml_key_quotes(
            String(String(raw_part).strip())
        )
        if normalized == "":
            normalized = part
        else:
            normalized += "." + part
    return normalized^


def _inline_table_contains_route_key(value: String) -> Bool:
    var table = String(String(value).strip())
    var open_index = table.find("{")
    if open_index < 0:
        return False
    var close_index = table.find("}")
    if close_index < 0 or close_index <= open_index:
        close_index = table.byte_length()

    var body = String(table[byte=open_index + 1:close_index])
    for raw_field in body.split(","):
        var field = String(String(raw_field).strip())
        var equals_index = field.find("=")
        if equals_index < 0:
            continue
        var key = String(String(field[byte=0:equals_index]).strip())
        if _normalize_toml_key_path(key) == "route":
            return True
    return False


def _reject_removed_max_local_route_config(config_text: String) raises:
    var in_max_local = False
    for raw_line in config_text.splitlines():
        var line = String(String(raw_line).strip())
        if line == "" or line.startswith("#"):
            continue
        if line.startswith("["):
            var close_index = line.find("]")
            if close_index < 0:
                in_max_local = False
                continue
            var table_name = String(
                String(line[byte=1:close_index]).strip()
            )
            in_max_local = (
                _normalize_toml_key_path(table_name)
                == "assisted.max_local"
            )
            continue
        var equals_index = line.find("=")
        if equals_index < 0:
            continue
        var key = _normalize_toml_key_path(
            String(String(line[byte=0:equals_index]).strip())
        )
        var value = String(String(line[byte=equals_index + 1:]).strip())
        if (
            (in_max_local and key == "route")
            or key == "assisted.max_local.route"
            or (
                key == "assisted.max_local"
                and _inline_table_contains_route_key(value)
            )
        ):
            raise Error(
                "assisted.max_local.route has been removed; provider route is derived by HYF"
            )


def _validate_max_local_provider_config(
    config: HyfMaxLocalProviderRuntimeConfig
) raises:
    _require_non_empty(config.base_url, "assisted.max_local.base_url")
    _require_no_boundary_whitespace(
        config.base_url, "assisted.max_local.base_url"
    )
    _require_http_url(config.base_url, "assisted.max_local.base_url")
    _require_non_empty(config.health_url, "assisted.max_local.health_url")
    _require_no_boundary_whitespace(
        config.health_url, "assisted.max_local.health_url"
    )
    _require_http_url(config.health_url, "assisted.max_local.health_url")
    _require_non_empty(config.model, "assisted.max_local.model")
    _require_no_boundary_whitespace(
        config.model, "assisted.max_local.model"
    )
    if config.request_timeout_ms <= 0:
        raise Error("assisted.max_local.request_timeout_ms must be greater than zero")
