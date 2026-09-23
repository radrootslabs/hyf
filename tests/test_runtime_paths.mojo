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


# ── H010 runtime TOML compatibility characterization ────────────────────────


from std.pathlib import Path
from safe_tempdir import SafeTempDir
from hyf_runtime.config import load_runtime_config


def _load_toml(
    temp_dir: String, name: String, text: String
) raises -> HyfLoadedRuntimeConfig:
    var path = temp_dir + "/" + name + ".toml"
    Path(path).write_text(text)
    return load_runtime_config(path)


def _assert_compiled_defaults(config: HyfLoadedRuntimeConfig) raises:
    assert_true(not config.effective.runtime.allow_assisted)
    assert_equal(config.effective.assisted.provider, "")
    assert_true(not config.effective.assisted.max_local.enabled)
    assert_equal(config.effective.assisted.max_local.base_url, "")
    assert_equal(config.effective.assisted.max_local.request_timeout_ms, 0)


def _assert_route_rejected(
    config: HyfLoadedRuntimeConfig, message: String
) raises:
    assert_equal(config.load_state, "invalid")
    assert_equal(config.load_error, message)


def _assert_form_ignored(config: HyfLoadedRuntimeConfig) raises:
    assert_equal(config.load_state, "loaded")
    assert_true(not config.effective.assisted.max_local.enabled)
    assert_equal(config.effective.assisted.max_local.base_url, "")
    assert_equal(config.effective.assisted.max_local.request_timeout_ms, 0)


comptime ASSISTED_HEADER = (
    '[runtime]\nallow_assisted = true\n[assisted]\nprovider = "max_local"\n'
)


def test_toml_compatibility_supported_table_forms_are_equivalent() raises:
    # H010: the two-level tables the loader applies are `[runtime]` and
    # `[assisted]`; blank lines and trailing comments are equivalent.
    with SafeTempDir() as temp_dir:
        var plain = _load_toml(temp_dir, "plain", ASSISTED_HEADER)
        var commented = _load_toml(
            temp_dir,
            "commented",
            (
                "# leading comment\n\n[runtime]\n"
                "allow_assisted = true # trailing\n\n"
                '[assisted]\nprovider = "max_local"\n'
            ),
        )
        assert_equal(plain.load_state, "loaded")
        assert_equal(commented.load_state, "loaded")
        assert_true(plain.effective.runtime.allow_assisted)
        assert_equal(plain.effective.assisted.provider, "max_local")
        assert_true(commented.effective.runtime.allow_assisted)
        assert_equal(commented.effective.assisted.provider, "max_local")


def test_toml_compatibility_ignored_forms_are_characterized() raises:
    # H010: current loader limitation, characterized not repaired. Dotted keys,
    # three-level tables and array-of-tables headers load without error but do
    # not apply their values, so `assisted.max_local.*` cannot be configured
    # from a TOML artifact today.
    with SafeTempDir() as temp_dir:
        var dotted = _load_toml(
            temp_dir,
            "dotted",
            (
                'assisted.provider = "max_local"\n'
                "assisted.max_local.enabled = true\n"
                'assisted.max_local.base_url = "http://127.0.0.1:8080"\n'
                "runtime.allow_assisted = true\n"
            ),
        )
        var deep = _load_toml(
            temp_dir,
            "deep",
            ASSISTED_HEADER
            + "[assisted.max_local]\nenabled = true\n"
            'base_url = "http://127.0.0.1:8080"\n'
            'health_url = "http://127.0.0.1:8080/health"\n'
            'model = "m"\nrequest_timeout_ms = 15000\n',
        )
        var array_header = _load_toml(
            temp_dir, "array", '[[assisted]]\nprovider = "max_local"\n'
        )
        var typesafe = _load_toml(
            temp_dir,
            "typesafe",
            ASSISTED_HEADER
            + "[assisted.typesafe]\nenabled = true\n"
            'base_url = "https://api.typesafe.ai"\n'
            'model = "jev-1.13.0"\nrequest_timeout_ms = 15000\n',
        )
        _assert_form_ignored(dotted)
        _assert_form_ignored(deep)
        _assert_form_ignored(array_header)
        _assert_form_ignored(typesafe)
        assert_true(not typesafe.effective.assisted.typesafe.enabled)
        # The array-of-tables form drops the two-level provider key as well.
        assert_true(not array_header.effective.runtime.allow_assisted)
        assert_equal(array_header.effective.assisted.provider, "")
        # The dotted form does not apply the two-level runtime/assisted keys.
        assert_true(not dotted.effective.runtime.allow_assisted)
        assert_equal(dotted.effective.assisted.provider, "")
        # The two-level keys around a three-level table still apply.
        assert_true(deep.effective.runtime.allow_assisted)
        assert_equal(deep.effective.assisted.provider, "max_local")


def test_toml_compatibility_inline_tables_are_characterized() raises:
    # H010: inline table forms are characterized. An inline table of tables is
    # accepted and ignored; an inline table carrying a string field fails the
    # TOML bridge with the current bounded error.
    with SafeTempDir() as temp_dir:
        var inline_scalar = _load_toml(
            temp_dir, "inline_scalar", "runtime = { allow_assisted = true }\n"
        )
        assert_equal(inline_scalar.load_state, "loaded")
        assert_true(not inline_scalar.effective.runtime.allow_assisted)
        var inline_tables = _load_toml(
            temp_dir,
            "inline_tables",
            'assisted = { max_local = { enabled = true, route = "/x" } }\n',
        )
        assert_equal(inline_tables.load_state, "loaded")
        assert_true(not inline_tables.effective.assisted.max_local.enabled)
        var inline_string = _load_toml(
            temp_dir,
            "inline_string",
            'assisted = { provider = "max_local" }\n',
        )
        assert_equal(inline_string.load_state, "invalid")
        assert_equal(inline_string.load_error, "Empty JSON value")


def test_toml_compatibility_rejects_removed_route_syntaxes() raises:
    # H010: every syntax of the removed `assisted.max_local.route` the guard
    # recognizes is rejected with the contractual message. The deep inline form
    # is not recognized today and loads with the key ignored: recorded as a
    # characterized gap for the config owner, not repaired here (product source
    # is outside this slice).
    var message = (
        "assisted.max_local.route has been removed; provider route is derived"
        " by HYF"
    )
    with SafeTempDir() as temp_dir:
        var table = _load_toml(
            temp_dir, "route_table", '[assisted.max_local]\nroute = "/v1"\n'
        )
        var dotted = _load_toml(
            temp_dir, "route_dotted", 'assisted.max_local.route = "/v1"\n'
        )
        var quoted = _load_toml(
            temp_dir, "route_quoted", '[assisted."max_local"]\nroute = "/v1"\n'
        )
        var inline = _load_toml(
            temp_dir, "route_inline", 'assisted.max_local = { route = "/v1" }\n'
        )
        _assert_route_rejected(table, message)
        _assert_route_rejected(dotted, message)
        _assert_route_rejected(quoted, message)
        _assert_route_rejected(inline, message)
        var deep_inline = _load_toml(
            temp_dir,
            "route_deep",
            'assisted = { max_local = { route = "/v1" } }\n',
        )
        assert_equal(deep_inline.load_state, "loaded")
        assert_equal(deep_inline.load_error, "")


def test_toml_compatibility_unknown_keys_and_defaults_are_characterized() raises:
    # H010: unknown keys anywhere are accepted without error, a missing artifact
    # leaves the compiled defaults active, and an invalid artifact falls back to
    # those same compiled defaults.
    with SafeTempDir() as temp_dir:
        var unknown_top = _load_toml(
            temp_dir, "unknown_top", "unknown = true\n"
        )
        assert_equal(unknown_top.load_state, "loaded")
        assert_equal(unknown_top.load_error, "")
        var unknown_table = _load_toml(
            temp_dir,
            "unknown_table",
            '[assisted]\nunknown = "value"\n[runtime]\nunknown_number = 3\n',
        )
        assert_equal(unknown_table.load_state, "loaded")
        assert_equal(unknown_table.load_error, "")
        var missing = load_runtime_config(temp_dir + "/absent.toml")
        assert_equal(missing.load_state, "not_found")
        assert_true(not missing.artifact_present)
        assert_true(missing.compiled_defaults_active)
        _assert_compiled_defaults(unknown_top)
        _assert_compiled_defaults(unknown_table)
        _assert_compiled_defaults(missing)
        var invalid = _load_toml(
            temp_dir, "invalid_defaults", '[service]\ntransport = "udp"\n'
        )
        assert_equal(invalid.load_state, "invalid")
        assert_true(invalid.compiled_defaults_active)
        _assert_compiled_defaults(invalid)
        assert_equal(invalid.effective.service.transport, "stdio")


def test_toml_compatibility_rejects_invalid_scalar_and_cross_field_forms() raises:
    # H010: invalid scalar values, cross-field combinations and a malformed
    # header preserve their current bounded error categories/messages.
    with SafeTempDir() as temp_dir:
        var transport = _load_toml(
            temp_dir, "transport", '[service]\ntransport = "udp"\n'
        )
        assert_equal(transport.load_state, "invalid")
        assert_equal(transport.load_error, "service.transport must be 'stdio'")
        var mode = _load_toml(
            temp_dir, "mode", '[runtime]\ndefault_execution_mode = "assisted"\n'
        )
        assert_equal(mode.load_state, "invalid")
        assert_equal(
            mode.load_error,
            (
                "runtime.default_execution_mode must be 'deterministic' in the"
                " foundation wave"
            ),
        )
        var provider = _load_toml(
            temp_dir,
            "provider",
            (
                "[runtime]\nallow_assisted = true\n[assisted]\n"
                'provider = "other"\n'
            ),
        )
        assert_equal(provider.load_state, "invalid")
        assert_equal(
            provider.load_error,
            (
                "assisted.provider must be 'max_local' or 'typesafe' when"
                " runtime.allow_assisted is true"
            ),
        )
        var whitespace = _load_toml(
            temp_dir,
            "whitespace",
            (
                "[runtime]\nallow_assisted = true\n[assisted]\n"
                'provider = " max_local"\n'
            ),
        )
        assert_equal(whitespace.load_state, "invalid")
        assert_equal(
            whitespace.load_error,
            "assisted.provider must not include leading or trailing whitespace",
        )
        var header = _load_toml(
            temp_dir, "header", '[assisted\nprovider = "max_local"\n'
        )
        assert_equal(header.load_state, "invalid")
        assert_true(header.load_error.startswith("Invalid TOML table header"))


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


from hyf_runtime.config import (
    default_loaded_runtime_config,
    operation_enabled,
    provider_disabled,
)


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


from hyf_runtime.budget import (
    budget_from_clock,
    budget_remaining_ms,
    budget_exhausted,
)


def test_shared_budget_does_not_reset_per_stage() raises:
    var value = budget_from_clock(500, 2000, 0)
    assert_equal(value.cap_ms, 500)
    assert_equal(budget_remaining_ms(value, 200_000_000), 300)
    assert_equal(budget_remaining_ms(value, 600_000_000), 0)
    assert_true(budget_exhausted(value, 600_000_000))
    var capped = budget_from_clock(5000, 2000, 0)
    assert_equal(capped.cap_ms, 2000)


def test_budget_boundaries_are_deterministic() raises:
    # H007: deterministic budget-unit controls that stay green before any
    # transport migration. The unit is one monotonic budget with no per-stage
    # reset, exact boundary behavior and non-negative remaining time.
    var no_deadline = budget_from_clock(0, 400, 0)
    assert_equal(no_deadline.cap_ms, 400)
    assert_equal(budget_remaining_ms(no_deadline, 0), 400)

    var negative_deadline = budget_from_clock(-5, 400, 0)
    assert_equal(negative_deadline.cap_ms, 400)

    var exact = budget_from_clock(250, 400, 0)
    assert_equal(budget_remaining_ms(exact, 0), 250)
    assert_equal(budget_remaining_ms(exact, 249_000_000), 1)
    assert_equal(budget_remaining_ms(exact, 250_000_000), 0)
    assert_true(not budget_exhausted(exact, 249_999_999))
    assert_true(budget_exhausted(exact, 250_000_000))

    # The same budget object across staged clock advancement must not reset: a
    # freshly constructed object would report the full cap again, which cannot
    # prove the original budget was preserved (ADR-0020 TC03).
    var staged = budget_from_clock(250, 400, 0)
    assert_equal(staged.cap_ms, 250)
    assert_equal(budget_remaining_ms(staged, 0), 250)
    assert_equal(budget_remaining_ms(staged, 200_000_000), 50)
    assert_equal(budget_remaining_ms(staged, 249_000_000), 1)
    assert_equal(budget_remaining_ms(staged, 250_000_000), 0)
    assert_equal(budget_remaining_ms(staged, 400_000_000), 0)
    assert_true(not budget_exhausted(staged, 249_999_999))
    assert_true(budget_exhausted(staged, 250_000_000))


from hyf_runtime.jev_composition import compose_jev


def test_jev_runtime_composition_reasons() raises:
    var disabled = default_loaded_runtime_config()
    assert_equal(compose_jev(disabled).reason, "disabled_by_runtime_config")
    var configured = _typesafe_config(True, "https://api.typesafe.ai")
    var composition = compose_jev(configured)
    assert_true(not composition.usable)
    assert_equal(composition.reason, "missing_credentials")
    assert_equal(composition.model, "jev-1.13.0")


def test_new_operation_configuration_matrix() raises:
    var config = default_loaded_runtime_config()
    assert_true(not operation_enabled(config, "farm_update.interpret"))
    assert_true(not operation_enabled(config, "buyer_request.interpret"))
    assert_true(not operation_enabled(config, "buyer_request.match"))
    config.effective.runtime.enable_farm_update_interpret = True
    assert_true(operation_enabled(config, "farm_update.interpret"))
    config.effective.runtime.enable_buyer_request_interpret = True
    assert_true(operation_enabled(config, "buyer_request.interpret"))
    config.effective.runtime.enable_buyer_request_match = True
    assert_true(operation_enabled(config, "buyer_request.match"))
    config.effective.runtime.disable_provider = True
    assert_true(not operation_enabled(config, "farm_update.interpret"))
    assert_true(not operation_enabled(config, "buyer_request.interpret"))
    assert_true(not operation_enabled(config, "buyer_request.match"))
