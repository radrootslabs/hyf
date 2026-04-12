from std.collections import List
from std.sys import argv

from hyf_runtime.env import (
    configured_paths_profile_from_env,
    configured_repo_local_root_from_env,
    configured_user_home_from_env,
)
from hyf_runtime.config import HyfLoadedRuntimeConfig, load_runtime_config
from hyf_runtime.errors import raise_runtime_contract_error
from hyf_runtime.paths import RuntimePaths, hyf_runtime_paths_for_unix_profile
from hyf_runtime.profile import repo_local_profile


@fieldwise_init
struct RuntimeStartupContext(Copyable, Movable):
    var paths_profile: String
    var repo_local_base_root: String
    var user_home: String
    var startup_config_path: String
    var startup_config_path_source: String
    var config: HyfLoadedRuntimeConfig
    var paths: RuntimePaths


@fieldwise_init
struct RuntimeStartupInput(Copyable, Movable):
    var env_paths_profile: String
    var env_repo_local_base_root: String
    var user_home: String
    var argv: List[String]


@fieldwise_init
struct _StartupOverrides(Copyable, Movable):
    var paths_profile: String
    var repo_local_base_root: String
    var startup_config_path: String


def _require_flag_value(
    args: List[String], value_index: Int, flag_name: String
) raises -> String:
    if value_index >= len(args):
        raise_runtime_contract_error(flag_name + " requires a value")
    var value = String(String(args[value_index]).strip())
    if value == "":
        raise_runtime_contract_error(flag_name + " requires a non-empty value")
    if value.startswith("-"):
        raise_runtime_contract_error(
            flag_name + " value must not be another flag"
        )
    return value^


def _parse_startup_overrides(args: List[String]) raises -> _StartupOverrides:
    var overrides = _StartupOverrides(
        paths_profile="", repo_local_base_root="", startup_config_path=""
    )
    var index = 0
    while index < len(args):
        var arg = String(args[index])

        if arg == "--paths-profile":
            overrides.paths_profile = _require_flag_value(
                args, index + 1, "--paths-profile"
            )
            index += 2
            continue

        if arg.startswith("--paths-profile="):
            overrides.paths_profile = String(
                arg[byte = len("--paths-profile=") :]
            )
            if overrides.paths_profile == "":
                raise_runtime_contract_error("--paths-profile requires a value")
            index += 1
            continue

        if arg == "--repo-local-root":
            overrides.repo_local_base_root = _require_flag_value(
                args, index + 1, "--repo-local-root"
            )
            index += 2
            continue

        if arg.startswith("--repo-local-root="):
            overrides.repo_local_base_root = String(
                arg[byte = len("--repo-local-root=") :]
            )
            if overrides.repo_local_base_root == "":
                raise_runtime_contract_error(
                    "--repo-local-root requires a value"
                )
            index += 1
            continue

        if arg == "--config":
            overrides.startup_config_path = _require_flag_value(
                args, index + 1, "--config"
            )
            index += 2
            continue

        if arg.startswith("--config="):
            overrides.startup_config_path = String(
                arg[byte = len("--config=") :]
            )
            if overrides.startup_config_path == "":
                raise_runtime_contract_error("--config requires a value")
            index += 1
            continue

        raise_runtime_contract_error("unknown startup argument '" + arg + "'")

    return overrides^


def resolve_startup_context(
    input: RuntimeStartupInput,
) raises -> RuntimeStartupContext:
    var profile = String(input.env_paths_profile)
    if profile == "":
        raise_runtime_contract_error("env paths profile must not be empty")

    var repo_local_base_root = String(input.env_repo_local_base_root)
    var overrides = _parse_startup_overrides(input.argv)
    if overrides.paths_profile != "":
        profile = String(overrides.paths_profile)
    if overrides.repo_local_base_root != "":
        repo_local_base_root = String(overrides.repo_local_base_root)

    var paths = hyf_runtime_paths_for_unix_profile(
        profile, input.user_home, repo_local_base_root
    )
    var startup_config_path = String(paths.config_path)
    var startup_config_path_source = String("canonical_runtime_path")
    if overrides.startup_config_path != "":
        startup_config_path = String(overrides.startup_config_path)
        startup_config_path_source = String("startup_flag")
    if profile != repo_local_profile():
        repo_local_base_root = String("")
    var config = load_runtime_config(startup_config_path)

    return RuntimeStartupContext(
        paths_profile=profile,
        repo_local_base_root=repo_local_base_root,
        user_home=String(input.user_home),
        startup_config_path=startup_config_path,
        startup_config_path_source=startup_config_path_source,
        config=config^,
        paths=paths^,
    )


def process_startup_args() -> List[String]:
    var raw_args = argv()
    var args = List[String]()
    for index in range(1, len(raw_args)):
        args.append(String(raw_args[index]))
    return args^


def resolve_startup_context_from_process() raises -> RuntimeStartupContext:
    return resolve_startup_context(
        RuntimeStartupInput(
            env_paths_profile=configured_paths_profile_from_env(),
            env_repo_local_base_root=configured_repo_local_root_from_env(),
            user_home=configured_user_home_from_env(),
            argv=process_startup_args(),
        )
    )
