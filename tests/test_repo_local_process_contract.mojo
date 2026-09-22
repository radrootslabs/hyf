from std.testing import TestSuite, assert_equal, assert_true
from std.collections import List
from safe_tempdir import SafeTempDir

from json import Value
from fixture_assertions import load_scenario_request_json
from parent_lifecycle import POLLIN, close_fd, make_pipe, write_raw
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
    drain_ready,
    run_stdio_entrypoint,
    run_stdio_entrypoint_with_deadline,
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
    with SafeTempDir() as repo_local_root:
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
                    runtime_status["config"][
                        "artifact_path_source"
                    ].string_value(),
                    "canonical_runtime_path",
                )
                assert_equal(
                    runtime_status["config"]["artifact_present"].bool_value(),
                    False,
                )
                assert_equal(
                    runtime_status["config"]["load_state"].string_value(),
                    "not_found",
                )


def test_run_stdio_entrypoint_reaps_stalled_child_under_deadline() raises:
    # FX06/FX08: the parent deadline (not the child alarm) must terminate and
    # reap the owned child, and the raised error must carry the reap result.
    var message = ""
    try:
        _ = run_stdio_entrypoint_with_deadline(
            "tests/stdio_stall_entrypoint.mojo", "{}", "", "", 3000
        )
    except e:
        message = String(e)
    assert_true(message.find("stdio-entrypoint") >= 0)
    assert_true(message.find("signal=") >= 0 or message.find("exited=") >= 0)


def test_run_stdio_entrypoint_classifies_loader_failure() raises:
    var message = ""
    try:
        _ = run_stdio_entrypoint_with_deadline(
            "tests/does_not_exist_entrypoint.mojo", "{}", "", "", 30000
        )
    except e:
        message = String(e)
    assert_true(message.find("child_failed") >= 0)
    assert_true(message.find("timeout") < 0)


def test_run_stdio_entrypoint_drains_stdout_concurrently() raises:
    # LC04: a child that floods stdout before reading stdin must not deadlock
    # the parent's large request write; a correct interleaving succeeds.
    var request = String("")
    for _ in range(150000):
        request += "r"
    var response = Value(None)
    var message = ""
    var failed = False
    try:
        response = run_stdio_entrypoint_with_deadline(
            "tests/stdio_stdout_flood_entrypoint.mojo",
            request,
            "",
            "",
            30000,
        )
    except e:
        failed = True
        message = String(e)
    assert_true(not failed)
    assert_equal(message, "")
    assert_true(response["ok"].bool_value())


def test_diagnostics_overflow_is_bounded_with_cause() raises:
    # LC04: stderr diagnostics are capped and an overflow is a distinct cause.
    var pipe = make_pipe()
    var chunk = String("")
    for _ in range(4096):
        chunk += "e"
    var out = List[UInt8]()
    var overflow_reason = ""
    for _ in range(20):
        _ = write_raw(pipe.write_fd, chunk)
        var d = drain_ready(pipe.read_fd, out, 65536, POLLIN)
        if d.reason != "":
            overflow_reason = d.reason
            break
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)
    assert_equal(overflow_reason, "stream_overflow")
    assert_true(len(out) <= 65536)


def test_diagnostics_read_failure_is_distinct_from_eof() raises:
    # LC04: an unavailable descriptor is a read failure, not a clean EOF.
    var out = List[UInt8]()
    var d = drain_ready(-1, out, 16, POLLIN)
    assert_true(d.eof)
    assert_equal(d.reason, "read_error")


def test_run_stdio_entrypoint_drains_stderr_concurrently_and_bounds_it() raises:
    # LC04: a child that floods stderr before producing output must not
    # deadlock the parent, and the overflow is reported with its own cause.
    var message = ""
    try:
        _ = run_stdio_entrypoint_with_deadline(
            "tests/stdio_stderr_flood_entrypoint.mojo", "{}", "", "", 30000
        )
    except e:
        message = String(e)
    assert_true(message.find("stderr_stream_overflow") >= 0)
    assert_true(message.find("timeout") < 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
