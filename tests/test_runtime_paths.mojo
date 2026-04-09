from std.testing import TestSuite, assert_equal, assert_raises

from hyf_runtime.paths import (
    hyf_runtime_paths_for_unix_profile,
    runtime_paths_for_namespace,
)
from hyf_runtime.roots import runtime_roots_from_base_root


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
