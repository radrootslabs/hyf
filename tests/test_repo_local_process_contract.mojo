from std.testing import TestSuite, assert_equal, assert_true
from std.tempfile import TemporaryDirectory

from mojson import Value
from fixture_assertions import load_scenario_request_json
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
    run_stdio_entrypoint,
)


def _assert_under_repo_local_root(repo_local_root: String, path: String) raises:
    assert_true(path.startswith(repo_local_root + "/"))


def _assert_runtime_status_path_under_repo_local_root(
    runtime_status: Value, key: String, repo_local_root: String
) raises:
    _assert_under_repo_local_root(
        repo_local_root,
        runtime_status["paths"][key].string_value(),
    )


def test_src_main_consumes_repo_local_env_without_outer_wrapper() raises:
    with TemporaryDirectory() as repo_local_root:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, repo_local_root):
                var response = run_stdio_entrypoint(
                    "src/main.mojo",
                    load_scenario_request_json("scenarios/status_ok.json"),
                )

                var runtime_status = response["output"]["runtime"].clone()
                assert_equal(
                    runtime_status["paths_profile"].string_value(), "repo_local"
                )
                assert_equal(
                    runtime_status["repo_local_base_root"].string_value(),
                    repo_local_root,
                )

                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "config_dir", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "config_path", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "data_dir", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "cache_dir", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "logs_dir", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "diagnostics_dir", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "run_dir", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "secrets_dir", repo_local_root
                )
                _assert_runtime_status_path_under_repo_local_root(
                    runtime_status, "identity_path", repo_local_root
                )
                _assert_under_repo_local_root(
                    repo_local_root,
                    runtime_status["config"]["artifact_path"].string_value(),
                )
                assert_equal(
                    runtime_status["config"]["artifact_path_source"].string_value(),
                    "canonical_runtime_path",
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
