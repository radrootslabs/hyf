from hyf_runtime.errors import raise_runtime_contract_error


comptime _INTERACTIVE_USER_PROFILE = "interactive_user"
comptime _SERVICE_HOST_PROFILE = "service_host"
comptime _REPO_LOCAL_PROFILE = "repo_local"


def interactive_user_profile() -> String:
    return _INTERACTIVE_USER_PROFILE


def service_host_profile() -> String:
    return _SERVICE_HOST_PROFILE


def repo_local_profile() -> String:
    return _REPO_LOCAL_PROFILE


def validate_runtime_profile(profile: String) raises:
    if (
        profile != _INTERACTIVE_USER_PROFILE
        and profile != _SERVICE_HOST_PROFILE
        and profile != _REPO_LOCAL_PROFILE
    ):
        raise_runtime_contract_error(
            "profile must be '"
            + _INTERACTIVE_USER_PROFILE
            + "', '"
            + _SERVICE_HOST_PROFILE
            + "', or '"
            + _REPO_LOCAL_PROFILE
            + "'"
        )
