from hyf_runtime.errors import raise_runtime_contract_error
from hyf_runtime.namespace import join_runtime_path
from hyf_runtime.platform import (
    interactive_user_base_root,
    service_host_cache_root,
    service_host_config_root,
    service_host_data_root,
    service_host_logs_root,
    service_host_run_root,
    service_host_secrets_root,
)
from hyf_runtime.profile import (
    interactive_user_profile,
    repo_local_profile,
    service_host_profile,
    validate_runtime_profile,
)


@fieldwise_init
struct RuntimeRootSet(Copyable, Movable):
    var config_root: String
    var data_root: String
    var cache_root: String
    var logs_root: String
    var run_root: String
    var secrets_root: String


def runtime_roots_from_base_root(base_root: String) raises -> RuntimeRootSet:
    if String(base_root).strip() == "":
        raise_runtime_contract_error("base root must not be empty")

    return RuntimeRootSet(
        config_root=join_runtime_path(base_root, "config"),
        data_root=join_runtime_path(base_root, "data"),
        cache_root=join_runtime_path(base_root, "cache"),
        logs_root=join_runtime_path(base_root, "logs"),
        run_root=join_runtime_path(base_root, "run"),
        secrets_root=join_runtime_path(base_root, "secrets"),
    )


def interactive_user_runtime_roots(user_home: String) raises -> RuntimeRootSet:
    return runtime_roots_from_base_root(interactive_user_base_root(user_home))


def service_host_runtime_roots() -> RuntimeRootSet:
    return RuntimeRootSet(
        config_root=service_host_config_root(),
        data_root=service_host_data_root(),
        cache_root=service_host_cache_root(),
        logs_root=service_host_logs_root(),
        run_root=service_host_run_root(),
        secrets_root=service_host_secrets_root(),
    )


def runtime_roots_for_unix_profile(
    profile: String,
    user_home: String,
    repo_local_base_root: String,
) raises -> RuntimeRootSet:
    validate_runtime_profile(profile)

    if profile == interactive_user_profile():
        return interactive_user_runtime_roots(user_home)

    if profile == service_host_profile():
        return service_host_runtime_roots()

    if String(repo_local_base_root).strip() == "":
        raise_runtime_contract_error("repo_local profile requires a base root")
    return runtime_roots_from_base_root(repo_local_base_root)
