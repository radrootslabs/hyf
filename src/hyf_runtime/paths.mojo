from hyf_runtime.namespace import (
    hyf_runtime_namespace,
    join_runtime_path,
    validate_runtime_namespace,
)
from hyf_runtime.roots import (
    RuntimeRootSet,
    runtime_roots_for_unix_profile,
)


@fieldwise_init
struct RuntimePaths(Copyable, Movable):
    var namespace: String
    var config_dir: String
    var config_path: String
    var data_dir: String
    var cache_dir: String
    var logs_dir: String
    var diagnostics_dir: String
    var run_dir: String
    var secrets_dir: String
    var identity_path: String


def runtime_paths_for_namespace(
    roots: RuntimeRootSet, namespace: String
) raises -> RuntimePaths:
    validate_runtime_namespace(namespace)

    var config_dir = join_runtime_path(roots.config_root, namespace)
    var data_dir = join_runtime_path(roots.data_root, namespace)
    var cache_dir = join_runtime_path(roots.cache_root, namespace)
    var logs_dir = join_runtime_path(roots.logs_root, namespace)
    var run_dir = join_runtime_path(roots.run_root, namespace)
    var secrets_dir = join_runtime_path(roots.secrets_root, namespace)

    return RuntimePaths(
        namespace=String(namespace),
        config_dir=String(config_dir),
        config_path=join_runtime_path(config_dir, "config.toml"),
        data_dir=String(data_dir),
        cache_dir=String(cache_dir),
        logs_dir=String(logs_dir),
        diagnostics_dir=join_runtime_path(logs_dir, "diagnostics"),
        run_dir=String(run_dir),
        secrets_dir=String(secrets_dir),
        identity_path=join_runtime_path(secrets_dir, "identity.secret.json"),
    )


def hyf_runtime_paths_for_roots(roots: RuntimeRootSet) raises -> RuntimePaths:
    return runtime_paths_for_namespace(roots, hyf_runtime_namespace())


def hyf_runtime_paths_for_unix_profile(
    profile: String,
    user_home: String,
    repo_local_base_root: String,
) raises -> RuntimePaths:
    return hyf_runtime_paths_for_roots(
        runtime_roots_for_unix_profile(profile, user_home, repo_local_base_root)
    )
