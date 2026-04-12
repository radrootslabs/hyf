from mojson import Value, loads

from hyf_runtime.config import assist_bridge_configured
from hyf_runtime.diagnostics import (
    diagnostics_debug_override_dir_from_env,
    effective_diagnostics_dir_for_runtime_paths,
)
from hyf_runtime.secrets import (
    default_secret_backend_name,
    identity_material_configured_for_runtime_paths,
    identity_material_created_by_startup,
    identity_material_loaded,
    protected_local_data_configured_for_runtime_paths,
    protected_local_data_dir_for_runtime_paths,
    protected_local_data_support_implemented,
    protected_local_data_status_name,
    protected_local_data_store_open,
    secret_storage_backend_implemented,
    secret_storage_status_name,
)
from hyf_runtime.startup import RuntimeStartupContext


def _runtime_paths_status_value(context: RuntimeStartupContext) raises -> Value:
    var paths = loads("{}")
    paths.set("config_dir", Value(String(context.paths.config_dir)))
    paths.set("config_path", Value(String(context.paths.config_path)))
    paths.set("data_dir", Value(String(context.paths.data_dir)))
    paths.set("cache_dir", Value(String(context.paths.cache_dir)))
    paths.set("logs_dir", Value(String(context.paths.logs_dir)))
    paths.set("diagnostics_dir", Value(String(context.paths.diagnostics_dir)))
    paths.set("run_dir", Value(String(context.paths.run_dir)))
    paths.set("secrets_dir", Value(String(context.paths.secrets_dir)))
    paths.set("identity_path", Value(String(context.paths.identity_path)))
    return paths^


def build_runtime_status_value(context: RuntimeStartupContext) raises -> Value:
    var status = loads("{}")
    status.set("id", Value("hyf_runtime"))
    status.set("namespace", Value(String(context.paths.namespace)))
    status.set("paths_profile", Value(String(context.paths_profile)))
    status.set(
        "repo_local_base_root", Value(String(context.repo_local_base_root))
    )
    status.set("paths", _runtime_paths_status_value(context))

    var config = loads("{}")
    config.set("artifact_path", Value(String(context.startup_config_path)))
    config.set(
        "artifact_path_source",
        Value(String(context.startup_config_path_source)),
    )
    config.set("artifact_present", Value(context.config.artifact_present))
    config.set("loaded", Value(context.config.loaded))
    config.set("load_state", Value(String(context.config.load_state)))
    config.set(
        "compiled_defaults_active",
        Value(context.config.compiled_defaults_active),
    )
    if context.config.load_error != "":
        config.set("load_error", Value(String(context.config.load_error)))

    var effective = loads("{}")
    effective.set(
        "service_transport",
        Value(String(context.config.effective.service.transport)),
    )
    effective.set(
        "default_execution_mode",
        Value(String(context.config.effective.runtime.default_execution_mode)),
    )
    effective.set(
        "allow_assisted",
        Value(context.config.effective.runtime.allow_assisted),
    )
    effective.set(
        "assist_bridge_enabled",
        Value(context.config.effective.assist.bridge_enabled),
    )
    effective.set(
        "assist_bridge_configured",
        Value(assist_bridge_configured(context.config)),
    )
    effective.set(
        "assist_transport",
        Value(String(context.config.effective.assist.transport)),
    )
    effective.set(
        "assist_endpoint",
        Value(String(context.config.effective.assist.endpoint)),
    )
    config.set("effective", effective)
    status.set("config", config)

    status.set("diagnostics", _diagnostics_status_value(context))
    status.set("secret_storage", _secret_storage_status_value(context))
    status.set(
        "protected_local_data", _protected_local_data_status_value(context)
    )

    return status^


def _secret_storage_status_value(
    context: RuntimeStartupContext,
) raises -> Value:
    var secret_storage = loads("{}")
    secret_storage.set("default_backend", Value(default_secret_backend_name()))
    secret_storage.set("status", Value(secret_storage_status_name()))
    secret_storage.set(
        "backend_implemented", Value(secret_storage_backend_implemented())
    )
    secret_storage.set(
        "identity_path", Value(String(context.paths.identity_path))
    )
    secret_storage.set(
        "identity_material_configured",
        Value(identity_material_configured_for_runtime_paths(context.paths)),
    )
    secret_storage.set(
        "identity_material_loaded", Value(identity_material_loaded())
    )
    secret_storage.set(
        "identity_material_created_by_startup",
        Value(identity_material_created_by_startup()),
    )
    secret_storage.set("secret_values_reported", Value(False))
    return secret_storage^


def _diagnostics_status_value(context: RuntimeStartupContext) raises -> Value:
    var diagnostics = loads("{}")
    var debug_override_dir = diagnostics_debug_override_dir_from_env()
    diagnostics.set(
        "canonical_dir", Value(String(context.paths.diagnostics_dir))
    )
    diagnostics.set(
        "effective_dir",
        Value(effective_diagnostics_dir_for_runtime_paths(context.paths)),
    )
    diagnostics.set("debug_override_active", Value(debug_override_dir != ""))
    return diagnostics^


def _protected_local_data_status_value(
    context: RuntimeStartupContext,
) raises -> Value:
    var protected_data = loads("{}")
    protected_data.set("status", Value(protected_local_data_status_name()))
    protected_data.set(
        "default_dir",
        Value(protected_local_data_dir_for_runtime_paths(context.paths)),
    )
    protected_data.set(
        "configured",
        Value(protected_local_data_configured_for_runtime_paths(context.paths)),
    )
    protected_data.set(
        "support_implemented", Value(protected_local_data_support_implemented())
    )
    protected_data.set("store_open", Value(protected_local_data_store_open()))
    return protected_data^
