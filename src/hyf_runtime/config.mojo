from std.os.path import exists
from std.pathlib import Path

from morph.toml import from_toml

# ADR-0010 D21 fixes the request-budget derivation, not this value: the absolute
# budget is min(positive request deadline, the configured provider
# request_timeout_ms). This named constant preserves the pre-existing 15000 ms
# default for H092's derivation; it is not a D21-selected bound, and it is not
# enlarged or weakened here.
comptime DEFAULT_PROVIDER_REQUEST_TIMEOUT_MS: Int = 15000


@fieldwise_init
struct HyfServiceRuntimeConfig(Copyable, Defaultable, Movable):
    var transport: String

    def __init__(out self):
        self.transport = "stdio"


@fieldwise_init
struct HyfExecutionRuntimeConfig(Copyable, Defaultable, Movable):
    var default_execution_mode: String
    var allow_assisted: Bool
    var enable_farm_update_interpret: Bool
    var enable_buyer_request_interpret: Bool
    var enable_buyer_request_match: Bool
    var disable_provider: Bool

    def __init__(out self):
        self.default_execution_mode = "deterministic"
        self.allow_assisted = False
        self.enable_farm_update_interpret = False
        self.enable_buyer_request_interpret = False
        self.enable_buyer_request_match = False
        self.disable_provider = False


@fieldwise_init
struct HyfMaxLocalProviderRuntimeConfig(Copyable, Defaultable, Movable):
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
struct HyfTypesafeProviderRuntimeConfig(Copyable, Defaultable, Movable):
    var enabled: Bool
    var base_url: String
    var model: String
    var request_timeout_ms: Int

    def __init__(out self):
        self.enabled = False
        self.base_url = "https://api.typesafe.ai"
        self.model = "jev-1.13.0"
        self.request_timeout_ms = DEFAULT_PROVIDER_REQUEST_TIMEOUT_MS


@fieldwise_init
struct HyfAssistedRuntimeConfig(Copyable, Defaultable, Movable):
    var provider: String
    var max_local: HyfMaxLocalProviderRuntimeConfig
    var typesafe: HyfTypesafeProviderRuntimeConfig

    def __init__(out self):
        self.provider = ""
        self.max_local = HyfMaxLocalProviderRuntimeConfig()
        self.typesafe = HyfTypesafeProviderRuntimeConfig()


@fieldwise_init
struct HyfRuntimeConfig(Copyable, Defaultable, Movable):
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
    if not config.effective.runtime.allow_assisted:
        return False
    if config.effective.assisted.provider == "max_local":
        return config.effective.assisted.max_local.enabled
    if config.effective.assisted.provider == "typesafe":
        return config.effective.assisted.typesafe.enabled
    return False


def operation_enabled(
    config: HyfLoadedRuntimeConfig, operation: String
) -> Bool:
    if config.effective.runtime.disable_provider:
        return False
    if operation == "farm_update.interpret":
        return config.effective.runtime.enable_farm_update_interpret
    if operation == "buyer_request.interpret":
        return config.effective.runtime.enable_buyer_request_interpret
    if operation == "buyer_request.match":
        return config.effective.runtime.enable_buyer_request_match
    return False


def provider_disabled(config: HyfLoadedRuntimeConfig) -> Bool:
    return config.effective.runtime.disable_provider


def typesafe_provider_configured(config: HyfLoadedRuntimeConfig) -> Bool:
    return (
        config.effective.runtime.allow_assisted
        and config.effective.assisted.provider == "typesafe"
        and config.effective.assisted.typesafe.enabled
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
            "runtime.default_execution_mode must be 'deterministic' in the"
            " foundation wave"
        )

    if config.assisted.provider != "":
        _require_no_boundary_whitespace(
            config.assisted.provider, "assisted.provider"
        )

    if config.runtime.allow_assisted:
        if (
            config.assisted.provider != "max_local"
            and config.assisted.provider != "typesafe"
        ):
            raise Error(
                "assisted.provider must be 'max_local' or 'typesafe' when"
                " runtime.allow_assisted is true"
            )

    if (
        config.assisted.provider != ""
        and config.assisted.provider != "max_local"
        and config.assisted.provider != "typesafe"
    ):
        raise Error("assisted.provider must be 'max_local' or 'typesafe'")

    if config.assisted.typesafe.enabled:
        if not config.runtime.allow_assisted:
            raise Error(
                "runtime.allow_assisted must be true when"
                " assisted.typesafe.enabled is true"
            )
        if config.assisted.provider != "typesafe":
            raise Error(
                "assisted.provider must be 'typesafe' when"
                " assisted.typesafe.enabled is true"
            )
        _validate_typesafe_provider_config(config.assisted.typesafe)

    if config.assisted.max_local.enabled:
        if not config.runtime.allow_assisted:
            raise Error(
                "runtime.allow_assisted must be true when"
                " assisted.max_local.enabled is true"
            )
        if config.assisted.provider != "max_local":
            raise Error(
                "assisted.provider must be 'max_local' when"
                " assisted.max_local.enabled is true"
            )
        _validate_max_local_provider_config(config.assisted.max_local)


def _require_non_empty(value: String, context: String) raises:
    if String(value).strip() == "":
        raise Error(context + " must not be empty")


def _require_no_boundary_whitespace(value: String, context: String) raises:
    if String(value) != String(value).strip():
        raise Error(
            context + " must not include leading or trailing whitespace"
        )


def _require_http_url(value: String, context: String) raises:
    if not (value.startswith("http://") or value.startswith("https://")):
        raise Error(context + " must use http or https")


def _strip_toml_key_quotes(value: String) -> String:
    var stripped = String(String(value).strip())
    if stripped.byte_length() < 2:
        return stripped^

    var bytes = stripped.as_bytes()
    var last_index = stripped.byte_length() - 1
    if bytes[0] == UInt8(ord('"')) and bytes[last_index] == UInt8(ord('"')):
        return String(stripped[byte=1:last_index])
    if bytes[0] == UInt8(ord("'")) and bytes[last_index] == UInt8(ord("'")):
        return String(stripped[byte=1:last_index])
    return stripped^


def _normalize_toml_key_path(key: String) -> String:
    var normalized = String("")
    for raw_part in key.split("."):
        var part = _strip_toml_key_quotes(String(String(raw_part).strip()))
        if normalized == "":
            normalized = part
        else:
            normalized += "." + part
    return normalized^


def _toml_delimiter_index_outside_quotes(
    text: String, delimiter: UInt8, start_index: Int
) -> Int:
    var bytes = text.as_bytes()
    var index = start_index
    var in_basic_string = False
    var in_literal_string = False
    var escaped = False
    while index < text.byte_length():
        var byte = bytes[index]
        if in_basic_string:
            if escaped:
                escaped = False
            elif byte == UInt8(ord("\\")):
                escaped = True
            elif byte == UInt8(ord('"')):
                in_basic_string = False
        elif in_literal_string:
            if byte == UInt8(ord("'")):
                in_literal_string = False
        else:
            if byte == UInt8(ord('"')):
                in_basic_string = True
            elif byte == UInt8(ord("'")):
                in_literal_string = True
            elif byte == delimiter:
                return index
        index += 1
    return -1


def _inline_table_contains_route_key(value: String) -> Bool:
    var table = String(String(value).strip())
    var open_index = _toml_delimiter_index_outside_quotes(
        table, UInt8(ord("{")), 0
    )
    if open_index < 0:
        return False
    var close_index = _toml_delimiter_index_outside_quotes(
        table, UInt8(ord("}")), open_index + 1
    )
    if close_index < 0 or close_index <= open_index:
        close_index = table.byte_length()

    var body = String(table[byte = open_index + 1 : close_index])
    var field_start = 0
    while field_start <= body.byte_length():
        var comma_index = _toml_delimiter_index_outside_quotes(
            body, UInt8(ord(",")), field_start
        )
        var field_end = comma_index
        if field_end < 0:
            field_end = body.byte_length()

        var field = String(String(body[byte=field_start:field_end]).strip())
        var equals_index = _toml_delimiter_index_outside_quotes(
            field, UInt8(ord("=")), 0
        )
        if equals_index < 0:
            if comma_index < 0:
                break
            field_start = comma_index + 1
            continue
        else:
            var key = String(String(field[byte=0:equals_index]).strip())
            if _normalize_toml_key_path(key) == "route":
                return True

        if comma_index < 0:
            break
        field_start = comma_index + 1
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
            var table_name = String(String(line[byte=1:close_index]).strip())
            in_max_local = (
                _normalize_toml_key_path(table_name) == "assisted.max_local"
            )
            continue
        var equals_index = line.find("=")
        if equals_index < 0:
            continue
        var key = _normalize_toml_key_path(
            String(String(line[byte=0:equals_index]).strip())
        )
        var value = String(String(line[byte = equals_index + 1 :]).strip())
        if (
            (in_max_local and key == "route")
            or key == "assisted.max_local.route"
            or (
                key == "assisted.max_local"
                and _inline_table_contains_route_key(value)
            )
        ):
            raise Error(
                "assisted.max_local.route has been removed; provider route is"
                " derived by HYF"
            )


def _validate_typesafe_provider_config(
    config: HyfTypesafeProviderRuntimeConfig,
) raises:
    _require_non_empty(config.base_url, "assisted.typesafe.base_url")
    _require_no_boundary_whitespace(
        config.base_url, "assisted.typesafe.base_url"
    )
    if not config.base_url.startswith("https://"):
        raise Error("assisted.typesafe.base_url must use https")
    _require_non_empty(config.model, "assisted.typesafe.model")
    _require_no_boundary_whitespace(config.model, "assisted.typesafe.model")
    if config.request_timeout_ms <= 0:
        raise Error(
            "assisted.typesafe.request_timeout_ms must be greater than zero"
        )


def _validate_max_local_provider_config(
    config: HyfMaxLocalProviderRuntimeConfig,
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
    _require_no_boundary_whitespace(config.model, "assisted.max_local.model")
    if config.request_timeout_ms <= 0:
        raise Error(
            "assisted.max_local.request_timeout_ms must be greater than zero"
        )
