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
struct HyfAssistBridgeRuntimeConfig(Defaultable, Copyable, Movable):
    var bridge_enabled: Bool
    var transport: String
    var endpoint: String

    def __init__(out self):
        self.bridge_enabled = False
        self.transport = "stdio"
        self.endpoint = ""


@fieldwise_init
struct HyfRuntimeConfig(Defaultable, Copyable, Movable):
    var service: HyfServiceRuntimeConfig
    var runtime: HyfExecutionRuntimeConfig
    var assist: HyfAssistBridgeRuntimeConfig

    def __init__(out self):
        self.service = HyfServiceRuntimeConfig()
        self.runtime = HyfExecutionRuntimeConfig()
        self.assist = HyfAssistBridgeRuntimeConfig()


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


def assist_bridge_configured(config: HyfLoadedRuntimeConfig) -> Bool:
    return (
        config.effective.assist.bridge_enabled
        and not String(config.effective.assist.endpoint).strip() == ""
    )


def load_runtime_config(path: String) -> HyfLoadedRuntimeConfig:
    var defaults = default_runtime_config()
    if String(path).strip() == "" or not exists(path):
        return default_loaded_runtime_config()

    try:
        var config = from_toml[HyfRuntimeConfig](Path(path).read_text())
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

    if config.assist.transport != "stdio":
        raise Error("assist.transport must be 'stdio'")

    if (
        config.assist.bridge_enabled
        and String(config.assist.endpoint).strip() == ""
    ):
        raise Error(
            "assist.endpoint must be configured when assist.bridge_enabled is true"
        )
