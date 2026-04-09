from hyf_runtime.errors import raise_runtime_contract_error
from hyf_runtime.namespace import join_runtime_path


def _require_non_empty_path(path: String, context: String) raises -> String:
    var trimmed = String(String(path).strip())
    if trimmed == "":
        raise_runtime_contract_error(context + " must not be empty")
    return trimmed^


def interactive_user_base_root(user_home: String) raises -> String:
    return join_runtime_path(
        _require_non_empty_path(user_home, "interactive_user home"), ".radroots"
    )


def service_host_config_root() -> String:
    return "/etc/radroots"


def service_host_data_root() -> String:
    return "/var/lib/radroots"


def service_host_cache_root() -> String:
    return "/var/cache/radroots"


def service_host_logs_root() -> String:
    return "/var/log/radroots"


def service_host_run_root() -> String:
    return "/run/radroots"


def service_host_secrets_root() -> String:
    return "/etc/radroots/secrets"
