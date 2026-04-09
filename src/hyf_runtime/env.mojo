from std.os import getenv

from hyf_runtime.profile import interactive_user_profile


comptime _HYF_PATHS_PROFILE_ENV = "HYF_PATHS_PROFILE"
comptime _HYF_PATHS_REPO_LOCAL_ROOT_ENV = "HYF_PATHS_REPO_LOCAL_ROOT"


def hyf_paths_profile_env_name() -> String:
    return _HYF_PATHS_PROFILE_ENV


def hyf_paths_repo_local_root_env_name() -> String:
    return _HYF_PATHS_REPO_LOCAL_ROOT_ENV


def configured_paths_profile_from_env() -> String:
    var value = getenv(_HYF_PATHS_PROFILE_ENV, "")
    if value != "":
        return value
    return interactive_user_profile()


def configured_repo_local_root_from_env() -> String:
    return getenv(_HYF_PATHS_REPO_LOCAL_ROOT_ENV, "")


def configured_user_home_from_env() -> String:
    return getenv("HOME", "")
