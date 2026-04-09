from mojson import Value, loads

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
    config.set("loaded", Value(False))
    config.set("compiled_defaults_active", Value(True))
    status.set("config", config)

    var secret_storage = loads("{}")
    secret_storage.set("default_backend", Value("local_file"))
    secret_storage.set("secret_values_reported", Value(False))
    status.set("secret_storage", secret_storage)

    return status^
