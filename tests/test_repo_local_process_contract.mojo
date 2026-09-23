from std.testing import TestSuite, assert_equal, assert_true
from std.collections import List
from safe_tempdir import SafeTempDir

from json import Value
from fixture_assertions import load_scenario_request_json
from parent_lifecycle import (
    IO_DEADLINE_EXPIRED,
    IO_FAULT_EINTR_UNBOUNDED,
    POLLIN,
    close_fd,
    make_pipe,
    now_ms,
    read_fd,
    write_fd_chunk,
    write_raw,
)
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
    drain_ready,
    run_stdio_binary_with_deadline,
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
    assert_true(message.find("cleanup_error=") >= 0)


def test_run_stdio_entrypoint_rejects_unread_request() raises:
    # PC03: an incomplete request write is a cause-specific failure even though
    # the child emits valid JSON and exits zero, and the failure still exposes
    # the owned child's cleanup truth.
    var request = String("")
    for _ in range(150000):
        request += "r"
    var message = ""
    try:
        _ = run_stdio_entrypoint_with_deadline(
            "tests/stdio_no_read_entrypoint.mojo", request, "", "", 10000
        )
    except e:
        message = String(e)
    assert_true(message.find("write_") >= 0)
    assert_true(message.find("cleanup_error=") >= 0)


def test_run_stdio_entrypoint_rejects_late_success() raises:
    # PC03: the ordinary compile/run helper keeps its declared total budget, so
    # a late exit is rejected inside it and the bounded cleanup grace is not
    # extra successful work. The phase-isolated proof of the late-exit child is
    # test_run_stdio_binary_rejects_late_exit_after_wait_phase below; this lane
    # only characterizes the one-shot compile/run helper's own budget.
    var start = now_ms()
    var message = ""
    try:
        _ = run_stdio_entrypoint_with_deadline(
            "tests/stdio_late_exit_entrypoint.mojo", "{}", "", "", 1200
        )
    except e:
        message = String(e)
    var elapsed = now_ms() - start
    assert_true(message.find("stdio-entrypoint") >= 0)
    assert_true(
        message.find("timeout") >= 0
        or message.find("read_deadline_expired") >= 0
    )
    assert_true(message.find("cleanup_error=") >= 0)
    assert_true(message.find("child_failed") < 0)
    assert_true(elapsed >= 1150)
    assert_true(elapsed <= 3700)


comptime LATE_EXIT_SH_SCRIPT = String(
    "printf '{\"ok\":true}\\n'; exec 1>&- 2>&-; exec sleep 3"
)


def test_run_stdio_binary_rejects_late_exit_after_wait_phase() raises:
    # RA03 phase isolation: an already-launched control child (compilation is
    # entirely outside this assertion) must reach valid output, closed output
    # and the wait phase *before* its late exit is rejected. A generic
    # compile/startup/read timeout cannot satisfy these phase assertions.
    var start = now_ms()
    var message = ""
    try:
        _ = run_stdio_binary_with_deadline(
            "/bin/sh", "{}", "-c", LATE_EXIT_SH_SCRIPT, 1200
        )
    except e:
        message = String(e)
    var elapsed = now_ms() - start
    assert_true(message.find("stdio-entrypoint") >= 0)
    assert_true(message.find("phase=wait") >= 0)
    assert_true(message.find("request_sent=true") >= 0)
    assert_true(message.find("stdout_eof=true") >= 0)
    assert_true(message.find("stderr_eof=true") >= 0)
    assert_true(message.find("output_valid=true") >= 0)
    assert_true(message.find("output_bytes=") >= 0)
    assert_true(message.find("reason=timeout") >= 0)
    assert_true(message.find("cleanup_error=") >= 0)
    assert_true(message.find("child_failed") < 0)
    # Work time stays inside the declared budget; only the bounded cleanup
    # allowance is added afterwards.
    assert_true(elapsed >= 1150)
    assert_true(elapsed <= 1200 + 2500)


def test_run_stdio_binary_reports_success_within_budget() raises:
    # RA03 positive control for the same launch seam: a child that emits valid
    # output and exits inside the budget is accepted.
    var response = run_stdio_binary_with_deadline(
        "/bin/sh", "{}", "-c", "printf '{\"ok\":true}\\n'", 5000
    )
    assert_true(response["ok"].bool_value())


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
        var d = drain_ready(pipe.read_fd, out, 65536, POLLIN, 2000)
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
    var d = drain_ready(-1, out, 16, POLLIN, 2000)
    assert_true(d.eof)
    assert_equal(d.reason, "read_error")


def test_diagnostics_retry_is_bounded_by_deadline() raises:
    # RA03: an EINTR-style retry inside the stdio drain path must return to the
    # deadline owner instead of retrying without bound. The retry count is a
    # bounded test seam; no host signal state is involved.
    var pipe = make_pipe()
    var buf = InlineArray[Byte, 8](fill=0)
    var start = now_ms()
    var rc = read_fd(
        pipe.read_fd, buf.unsafe_ptr(), 8, 60, IO_FAULT_EINTR_UNBOUNDED
    )
    var elapsed = now_ms() - start
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)
    assert_equal(rc, IO_DEADLINE_EXPIRED)
    assert_true(elapsed >= 50)


def test_diagnostics_write_retry_is_bounded_by_deadline() raises:
    # RA03: the same bound holds for the stdio request-write retry loop.
    var pipe = make_pipe()
    var payload = String('{"ok":true}')
    var start = now_ms()
    var cw = write_fd_chunk(
        pipe.write_fd, payload, 0, 60, IO_FAULT_EINTR_UNBOUNDED
    )
    var elapsed = now_ms() - start
    close_fd(pipe.read_fd)
    close_fd(pipe.write_fd)
    assert_equal(cw.reason, "write_deadline_expired")
    assert_true(elapsed >= 50)


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
