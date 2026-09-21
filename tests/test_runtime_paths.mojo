from std.collections import List
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from hyf_runtime.env import (
    hyf_paths_profile_env_name,
    hyf_paths_repo_local_root_env_name,
)
from hyf_runtime.paths import (
    hyf_runtime_paths_for_unix_profile,
    runtime_paths_for_namespace,
)
from hyf_runtime.roots import runtime_roots_from_base_root
from hyf_runtime.startup import RuntimeStartupInput, resolve_startup_context


def test_runtime_paths_repo_local_contract_vector() raises:
    var paths = hyf_runtime_paths_for_unix_profile(
        "repo_local", "/home/unused", "/tmp/radroots-local/"
    )

    assert_equal(paths.namespace, "services/hyf")
    assert_equal(paths.config_dir, "/tmp/radroots-local/config/services/hyf")
    assert_equal(
        paths.config_path,
        "/tmp/radroots-local/config/services/hyf/config.toml",
    )
    assert_equal(paths.data_dir, "/tmp/radroots-local/data/services/hyf")
    assert_equal(paths.cache_dir, "/tmp/radroots-local/cache/services/hyf")
    assert_equal(paths.logs_dir, "/tmp/radroots-local/logs/services/hyf")
    assert_equal(
        paths.diagnostics_dir,
        "/tmp/radroots-local/logs/services/hyf/diagnostics",
    )
    assert_equal(paths.run_dir, "/tmp/radroots-local/run/services/hyf")
    assert_equal(
        paths.identity_path,
        "/tmp/radroots-local/secrets/services/hyf/identity.secret.json",
    )


def test_runtime_paths_interactive_user_contract_vector() raises:
    var paths = hyf_runtime_paths_for_unix_profile(
        "interactive_user", "/Users/radroots-test", ""
    )

    assert_equal(
        paths.config_path,
        "/Users/radroots-test/.radroots/config/services/hyf/config.toml",
    )
    assert_equal(
        paths.data_dir, "/Users/radroots-test/.radroots/data/services/hyf"
    )
    assert_equal(
        paths.secrets_dir,
        "/Users/radroots-test/.radroots/secrets/services/hyf",
    )


def test_runtime_paths_service_host_contract_vector() raises:
    var paths = hyf_runtime_paths_for_unix_profile(
        "service_host", "/home/unused", ""
    )

    assert_equal(paths.config_path, "/etc/radroots/services/hyf/config.toml")
    assert_equal(paths.data_dir, "/var/lib/radroots/services/hyf")
    assert_equal(paths.cache_dir, "/var/cache/radroots/services/hyf")
    assert_equal(paths.logs_dir, "/var/log/radroots/services/hyf")
    assert_equal(paths.run_dir, "/run/radroots/services/hyf")
    assert_equal(paths.secrets_dir, "/etc/radroots/secrets/services/hyf")


def test_runtime_paths_reject_invalid_profile_namespace_and_base_root() raises:
    with assert_raises():
        _ = hyf_runtime_paths_for_unix_profile(
            "developer_laptop", "/Users/radroots-test", ""
        )

    with assert_raises():
        _ = hyf_runtime_paths_for_unix_profile(
            "repo_local", "/Users/radroots-test", ""
        )

    with assert_raises():
        _ = runtime_paths_for_namespace(
            runtime_roots_from_base_root("/tmp/radroots-local"), "hyf"
        )


def _startup_argv() -> List[String]:
    return List[String]()


def _startup_argv2(first: String, second: String) -> List[String]:
    var args = List[String]()
    args.append(first)
    args.append(second)
    return args^


def test_runtime_env_contract_names_are_frozen() raises:
    assert_equal(hyf_paths_profile_env_name(), "HYF_PATHS_PROFILE")
    assert_equal(
        hyf_paths_repo_local_root_env_name(), "HYF_PATHS_REPO_LOCAL_ROOT"
    )


def test_startup_context_defaults_from_env_and_home() raises:
    var context = resolve_startup_context(
        RuntimeStartupInput(
            env_paths_profile="interactive_user",
            env_repo_local_base_root="",
            user_home="/home/hyf-test",
            argv=_startup_argv(),
        )
    )

    assert_equal(context.paths_profile, "interactive_user")
    assert_equal(
        context.paths.config_path,
        "/home/hyf-test/.radroots/config/services/hyf/config.toml",
    )
    assert_equal(context.startup_config_path, context.paths.config_path)
    assert_equal(context.startup_config_path_source, "canonical_runtime_path")


def test_startup_context_cli_flags_override_env() raises:
    var context = resolve_startup_context(
        RuntimeStartupInput(
            env_paths_profile="service_host",
            env_repo_local_base_root="",
            user_home="/home/ignored",
            argv=_startup_argv2(
                "--paths-profile=repo_local",
                "--repo-local-root=/tmp/hyf-runtime",
            ),
        )
    )

    assert_equal(context.paths_profile, "repo_local")
    assert_equal(context.repo_local_base_root, "/tmp/hyf-runtime")
    assert_equal(
        context.paths.config_path,
        "/tmp/hyf-runtime/config/services/hyf/config.toml",
    )


def test_startup_context_clears_inactive_repo_local_root() raises:
    var context = resolve_startup_context(
        RuntimeStartupInput(
            env_paths_profile="interactive_user",
            env_repo_local_base_root="/tmp/hyf-runtime",
            user_home="/home/hyf-test",
            argv=_startup_argv2("--repo-local-root", "/tmp/hyf-override"),
        )
    )

    assert_equal(context.paths_profile, "interactive_user")
    assert_equal(context.repo_local_base_root, "")
    assert_equal(
        context.paths.config_path,
        "/home/hyf-test/.radroots/config/services/hyf/config.toml",
    )


def test_startup_context_config_flag_overrides_config_artifact_only() raises:
    var context = resolve_startup_context(
        RuntimeStartupInput(
            env_paths_profile="repo_local",
            env_repo_local_base_root="/tmp/hyf-runtime",
            user_home="/home/ignored",
            argv=_startup_argv2("--config", "/tmp/hyf-config/config.toml"),
        )
    )

    assert_equal(
        context.paths.config_path,
        "/tmp/hyf-runtime/config/services/hyf/config.toml",
    )
    assert_equal(context.startup_config_path, "/tmp/hyf-config/config.toml")
    assert_equal(context.startup_config_path_source, "startup_flag")


def test_startup_context_rejects_missing_root_unknown_flag_and_flag_as_value() raises:
    with assert_raises():
        _ = resolve_startup_context(
            RuntimeStartupInput(
                env_paths_profile="repo_local",
                env_repo_local_base_root="",
                user_home="/home/ignored",
                argv=_startup_argv(),
            )
        )

    with assert_raises():
        _ = resolve_startup_context(
            RuntimeStartupInput(
                env_paths_profile="interactive_user",
                env_repo_local_base_root="",
                user_home="/home/ignored",
                argv=_startup_argv2("--profile", "repo_local"),
            )
        )

    with assert_raises():
        _ = resolve_startup_context(
            RuntimeStartupInput(
                env_paths_profile="interactive_user",
                env_repo_local_base_root="",
                user_home="/home/ignored",
                argv=_startup_argv2("--paths-profile", "--repo-local-root"),
            )
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_runtime.config import (
    HyfAssistedRuntimeConfig,
    HyfExecutionRuntimeConfig,
    HyfLoadedRuntimeConfig,
    HyfMaxLocalProviderRuntimeConfig,
    HyfRuntimeConfig,
    HyfServiceRuntimeConfig,
    HyfTypesafeProviderRuntimeConfig,
    assisted_runtime_configured,
    typesafe_provider_configured,
)


def _typesafe_config(enabled: Bool, base_url: String) -> HyfLoadedRuntimeConfig:
    var runtime = HyfExecutionRuntimeConfig()
    runtime.default_execution_mode = "deterministic"
    runtime.allow_assisted = True
    return HyfLoadedRuntimeConfig(
        artifact_present=True,
        loaded=True,
        compiled_defaults_active=False,
        load_state="loaded",
        load_error="",
        effective=HyfRuntimeConfig(
            service=HyfServiceRuntimeConfig(transport="stdio"),
            runtime=runtime.copy(),
            assisted=HyfAssistedRuntimeConfig(
                provider="typesafe",
                max_local=HyfMaxLocalProviderRuntimeConfig(),
                typesafe=HyfTypesafeProviderRuntimeConfig(
                    enabled=enabled,
                    base_url=base_url,
                    model="jev-1.13.0",
                    request_timeout_ms=15000,
                ),
            ),
        ),
    )


def test_typesafe_profile_is_configured_and_pins_https_model() raises:
    var config = _typesafe_config(True, "https://api.typesafe.ai")
    assert_true(assisted_runtime_configured(config))
    assert_true(typesafe_provider_configured(config))
    assert_equal(config.effective.assisted.typesafe.model, "jev-1.13.0")
    var disabled = _typesafe_config(False, "https://api.typesafe.ai")
    assert_true(not assisted_runtime_configured(disabled))


from hyf_runtime.config import default_loaded_runtime_config, operation_enabled, provider_disabled


def test_operation_enablement_and_kill_switch() raises:
    var config = default_loaded_runtime_config()
    assert_true(not operation_enabled(config, "farm_update.interpret"))
    assert_true(not operation_enabled(config, "buyer_request.interpret"))
    assert_true(not operation_enabled(config, "buyer_request.match"))
    assert_true(not provider_disabled(config))
    config.effective.runtime.enable_buyer_request_match = True
    assert_true(operation_enabled(config, "buyer_request.match"))
    config.effective.runtime.disable_provider = True
    assert_true(provider_disabled(config))
    assert_true(not operation_enabled(config, "buyer_request.match"))


from hyf_runtime.budget import budget_from_clock, budget_remaining_ms, budget_exhausted


def test_shared_budget_does_not_reset_per_stage() raises:
    var value = budget_from_clock(500, 2000, 0)
    assert_equal(value.cap_ms, 500)
    assert_equal(budget_remaining_ms(value, 200_000_000), 300)
    assert_equal(budget_remaining_ms(value, 600_000_000), 0)
    assert_true(budget_exhausted(value, 600_000_000))
    var capped = budget_from_clock(5000, 2000, 0)
    assert_equal(capped.cap_ms, 2000)


from hyf_runtime.jev_composition import compose_jev


def test_jev_runtime_composition_reasons() raises:
    var disabled = default_loaded_runtime_config()
    assert_equal(compose_jev(disabled).reason, "disabled_by_runtime_config")
    var configured = _typesafe_config(True, "https://api.typesafe.ai")
    var composition = compose_jev(configured)
    assert_true(not composition.usable)
    assert_equal(composition.reason, "missing_credentials")
    assert_equal(composition.model, "jev-1.13.0")
