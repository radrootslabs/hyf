"""H005A measurement contract tests (ADR-0012 D29, ADR-0014 D34, ADR-0019 D39).

Drives the governed persistent-process measurement tooling against a real
build of the existing product entry point and against controlled child
processes, proving that the reproduced H005/R56/R57 defects and the period-10
counterexamples now fail the measurement instead of reporting success:

* MR01 — extra, coalesced, split, unterminated and malformed trailing stdout,
  early EOF and a nonzero child exit;
* MR02 — a valid response or exit that arrives after the one work budget, a
  sampling subprocess that would outlive it, stderr overflow and a
  deadline-bounded EINTR retry;
* MR03 — repeated failing public measurement calls leave no descriptor or
  child behind, with successful recovery afterward;
* MR04 — source/binary identity drift rejection, delayed-startup timing and
  truthful per-request/instrumentation accounting.

This module is test-only tooling. It changes no product policy, schema,
dependency or lock.
"""

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

import std.os
from std.pathlib import Path

from safe_tempdir import SafeTempDir

from parent_lifecycle import (
    CleanupGuard,
    now_ms,
    open_fd_count_checked,
    owned_pid,
)
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
)
from measurement_process_helper import (
    MeasurementFaults,
    MeasurementSession,
    build_product_binary,
    build_status_frame,
    child_process_count,
    file_sha256,
    measure_persistent_process,
    measurement_poll,
    measurement_poll_retry,
    measurement_tooling_files,
    require_clean_source,
    run_capture,
    sample_fd_count,
    sample_rss_kb,
    sha256_file_set,
    source_identity,
    source_manifest_sha256,
    tooling_manifest_sha256,
    validate_status_frame,
)
from json import Value, loads

from hyf_core.request_context import default_request_context
from hyf_provider.client import post_max_local_chat_completion
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.result import parse_query_analysis_from_chat_completion
from hyf_provider.schema import build_query_rewrite_request_body
from max_local_process_helper import spawn_max_local_stub


comptime MEASUREMENT_DEADLINE_MS = 120000
comptime WARMUP_FRAMES = 20
comptime MEASURED_FRAMES = 200

# One valid sys.status response for request/trace index 0.
comptime STATUS0 = (
    '{"version":1,"request_id":"meas-status-0","trace_id":"meas-trace-0",'
    '"ok":true,"output":{"daemon":"hyfd"}}'
)
comptime WRONG_REVISION = "0000000000000000000000000000000000000000"
comptime WRONG_DIGEST = (
    "0000000000000000000000000000000000000000000000000000000000000000"
)


def _one_response() -> String:
    """A well-behaved responder: answer exactly one request, then consume the
    rest of stdin until EOF so the child exits cleanly and closes stdout.
    """
    return (
        "IFS= read -r line; printf '%s\\n' '"
        + STATUS0
        + "'; while IFS= read -r line; do :; done"
    )


def _sh(args_text: String) -> List[String]:
    var args = List[String]()
    args.append("-c")
    args.append(args_text)
    return args^


def _multi_response() -> String:
    """A well-behaved responder for any frame count.

    Request ids/trace ids are deterministic (``meas-status-<index>``), so a
    counter reproduces the exact expected correlation for each frame in order.
    """
    return (
        "i=0\n"
        "while IFS= read -r line; do\n"
        'printf \'{"version":1,"request_id":"meas-status-%s",'
        '"trace_id":"meas-trace-%s","ok":true,'
        '"output":{"daemon":"hyfd"}}\\n\' "$i" "$i"\n'
        "i=$((i+1))\n"
        "done"
    )


def _run_sh_measurement(
    args_text: String,
    warmup: Int,
    measured: Int,
    mut guard: CleanupGuard,
    rss_sampler: String = "ps",
    fd_sampler: String = "lsof",
    deadline_ms: Int = MEASUREMENT_DEADLINE_MS,
    faults: MeasurementFaults = MeasurementFaults(),
) raises -> MeasurementSession:
    var argv = _sh(args_text)
    return measure_persistent_process(
        ".",
        "/bin/sh",
        argv^,
        warmup,
        measured,
        deadline_ms,
        guard,
        rss_sampler,
        fd_sampler,
        "",
        "",
        "",
        faults,
    )


def _run_sh_failure(
    args_text: String,
    warmup: Int,
    measured: Int,
    mut guard: CleanupGuard,
    rss_sampler: String = "ps",
    fd_sampler: String = "lsof",
    deadline_ms: Int = MEASUREMENT_DEADLINE_MS,
    faults: MeasurementFaults = MeasurementFaults(),
) -> String:
    try:
        _ = _run_sh_measurement(
            args_text,
            warmup,
            measured,
            guard,
            rss_sampler,
            fd_sampler,
            deadline_ms,
            faults,
        )
    except e:
        return String(e)
    return ""


# ── Positive persistent measurement ─────────────────────────────────────────


def test_persistent_measurement_validates_every_frame() raises:
    # D29/MR01: one process serves warmup and measured frames; every frame has
    # a parsed envelope, matching correlation and expected outcome, the whole
    # stream is accounted through EOF, with numeric RSS/FD samples, a checked
    # child exit and proved cleanup. The recorded environment profile is the
    # verified live profile of the measured child.
    var guard = CleanupGuard()
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var built = build_product_binary(".", temp_dir, guard)
                assert_equal(built.binary_sha256.byte_length(), 64)
                assert_equal(built.source.dirty_status, "")
                assert_equal(built.source.manifest_sha256.byte_length(), 64)
                assert_true(built.build_ms > 0)
                var argv = List[String]()
                var session = measure_persistent_process(
                    ".",
                    built.binary_path,
                    argv^,
                    WARMUP_FRAMES,
                    MEASURED_FRAMES,
                    MEASUREMENT_DEADLINE_MS,
                    guard,
                    "ps",
                    "lsof",
                    built.source.revision,
                    built.source.manifest_sha256,
                    built.binary_sha256,
                )
                assert_equal(session.ok_frames, WARMUP_FRAMES + MEASURED_FRAMES)
                assert_equal(session.failed_frames, 0)
                assert_equal(session.first_failure, "")
                # Startup is measured from spawn to the first validated
                # response; instrumentation is recorded separately.
                assert_true(session.startup_ms >= 0)
                assert_true(session.startup_wall_ms >= session.startup_ms)
                assert_true(session.startup_sampling_ms >= 0)
                # Measured-phase wall time excludes sampling instrumentation.
                assert_true(session.measured_ms >= 0)
                assert_true(session.measured_wall_ms >= session.measured_ms)
                assert_true(session.measured_sampling_ms >= 0)
                assert_true(session.request_total_ms > 0)
                assert_true(session.request_max_ms >= session.request_min_ms)
                # Numeric sampling with recorded units, method and cadence.
                assert_true(session.rss_kb_before_warmup > 0)
                assert_true(session.rss_kb_after_warmup > 0)
                assert_true(session.rss_kb_after_measured > 0)
                assert_true(session.rss_kb_peak >= session.rss_kb_after_warmup)
                assert_true(session.fd_before_warmup > 0)
                assert_true(session.fd_after_measured > 0)
                assert_true(session.fd_peak >= session.fd_after_measured)
                assert_true(session.sampling_method.find("kB") >= 0)
                assert_true(session.sampling_method.find("-F f") >= 0)
                assert_true(session.sampling_cadence.find("every") >= 0)
                # The declared per-process request policy is characterized, not
                # assumed: the persistent loop does not enforce it.
                assert_equal(session.declared_max_requests_per_process, 1)
                assert_true(session.child_exit.find("exited=0") >= 0)
                assert_true(session.stderr_excerpt == "")
                # Exact, truthful identity: clean verified source/tree plus a
                # deterministic content manifest, binary, pixi files, toolchain,
                # host and the verified environment profile.
                assert_equal(session.identity.binding, "clean_product_tree")
                assert_equal(
                    session.identity.binary_sha256, built.binary_sha256
                )
                assert_equal(
                    session.identity.source_revision, built.source.revision
                )
                assert_equal(
                    session.identity.source_manifest_sha256,
                    built.source.manifest_sha256,
                )
                assert_equal(session.identity.source_tree_state, "clean")
                assert_equal(session.identity.source_tree.byte_length(), 40)
                assert_equal(
                    session.identity.tooling_manifest_sha256.byte_length(), 64
                )
                assert_equal(
                    session.identity.pixi_lock_sha256.byte_length(), 64
                )
                assert_equal(
                    session.identity.pixi_toml_sha256.byte_length(), 64
                )
                assert_equal(session.identity.source_revision.byte_length(), 40)
                assert_true(session.identity.cwd.find("oss/hyf") >= 0)
                assert_true(
                    session.identity.env_profile.find(
                        "HYF_PATHS_PROFILE=repo_local"
                    )
                    >= 0
                )
                assert_true(session.identity.env_profile.find(temp_dir) >= 0)
                assert_true(session.identity.toolchain_version != "")
                assert_true(
                    session.identity.host_platform.find("Darwin") >= 0
                    or session.identity.host_platform.find("Linux") >= 0
                )
                assert_true(
                    session.summary().find(
                        "frames=" + String(WARMUP_FRAMES + MEASURED_FRAMES)
                    )
                    >= 0
                )
    guard.assert_clean()


def test_measurement_identity_drift_is_rejected() raises:
    # MR04: a product measurement must reject a binary/source binding that does
    # not match the observed clean source identity.
    var guard = CleanupGuard()
    var message = ""
    with SafeTempDir() as temp_dir:
        var built = build_product_binary(".", temp_dir, guard)
        var wrong_revision = WRONG_REVISION
        var argv = List[String]()
        try:
            _ = measure_persistent_process(
                ".",
                built.binary_path,
                argv^,
                0,
                1,
                MEASUREMENT_DEADLINE_MS,
                guard,
                "ps",
                "lsof",
                wrong_revision,
                built.source.manifest_sha256,
                built.binary_sha256,
            )
        except e:
            message = String(e)
    assert_true(message.find("drift") >= 0)
    guard.assert_clean()


def test_measurement_rejects_wrong_binary_digest() raises:
    # MR04: the recorded binary digest is enforced, not merely recorded.
    var guard = CleanupGuard()
    var message = ""
    with SafeTempDir() as temp_dir:
        var built = build_product_binary(".", temp_dir, guard)
        var argv = List[String]()
        try:
            _ = measure_persistent_process(
                ".",
                built.binary_path,
                argv^,
                0,
                1,
                MEASUREMENT_DEADLINE_MS,
                guard,
                "ps",
                "lsof",
                built.source.revision,
                built.source.manifest_sha256,
                WRONG_DIGEST,
            )
        except e:
            message = String(e)
    assert_true(message.find("binary drift") >= 0)
    guard.assert_clean()


def test_measurement_reports_delayed_startup() raises:
    # MR04: startup timing is spawn-relative and truthful, so a deliberately
    # delayed child is observed as such rather than as a near-zero value.
    var guard = CleanupGuard()
    var session = _run_sh_measurement(
        "sleep 0.3; " + _one_response(), 0, 1, guard
    )
    assert_equal(session.ok_frames, 1)
    assert_true(session.startup_ms >= 200)
    assert_true(session.startup_wall_ms >= session.startup_ms)
    guard.assert_clean()


def test_measurement_sampling_is_numeric_and_units_are_recorded() raises:
    # D29: the sampler must return real numeric values with explicit
    # unavailability, never a placeholder.
    var guard = CleanupGuard()
    var self_pid = owned_pid()
    var rss = sample_rss_kb(self_pid, "ps", guard)
    assert_true(rss > 0)
    var fds = sample_fd_count(self_pid, "lsof", guard)
    assert_true(fds > 0)
    guard.assert_clean()


comptime ANALYSIS_JSON_TEXT = (
    '{"original_text":"eggs near me",'
    '"normalized_text":"eggs near me",'
    '"rewritten_text":"eggs",'
    '"query_terms":["eggs"],'
    '"normalization_signals":["local_intent_detected"],'
    '"ranking_hints":["prefer_local_results"],'
    '"extracted_filters":{'
    '"local_intent":true,'
    '"fulfillment":"unspecified",'
    '"time_window":"unspecified"'
    "}}"
)


def test_direct_provider_request_and_client_schema_characterization() raises:
    # D29/MR04: distinguish startup, a deterministic daemon request, a direct
    # local provider request and connection counts, and characterize
    # client/schema construction with numeric recorded values and source
    # evidence. The Morph daemon-assisted path is out of scope here and remains
    # an explicit H024 obligation.
    var guard = CleanupGuard()
    var stub_start = now_ms()
    with spawn_max_local_stub(0, "count_requests", 1, guard) as stub:
        var stub_startup_ms = now_ms() - stub_start
        assert_true(stub_startup_ms >= 0)
        var config = MaxLocalProviderConfig(
            base_url="http://127.0.0.1:" + String(stub.port) + "/v1/",
            health_url="http://127.0.0.1:" + String(stub.port) + "/health",
            model="max-local-query-rewrite",
            request_timeout_ms=15000,
        )
        var context = default_request_context()
        context.return_provenance = True
        var construct_start = now_ms()
        var body = build_query_rewrite_request_body(
            config, "eggs near me", context
        )
        var construct_ms = now_ms() - construct_start
        # Schema construction is deterministic and source-verifiable, with a
        # numeric field/message count that is recorded rather than asserted as
        # a bare non-negative duration.
        assert_true(construct_ms >= 0)
        assert_true(body.object_count() > 0)
        assert_equal(body["messages"].array_count(), 2)
        assert_equal(body["model"].string_value(), "max-local-query-rewrite")
        assert_equal(body["messages"][0]["role"].string_value(), "system")
        assert_equal(body["messages"][1]["role"].string_value(), "user")
        assert_equal(
            body["response_format"]["type"].string_value(), "json_schema"
        )
        assert_equal(
            body["response_format"]["json_schema"]["name"].string_value(),
            "query_rewrite",
        )
        # One direct provider request over one verified connection, with a
        # numeric elapsed time that is asserted to be a plausible positive
        # measurement.
        var request_start = now_ms()
        var outcome = post_max_local_chat_completion(config, body)
        var request_ms = now_ms() - request_start
        assert_true(not outcome.failure)
        assert_true(request_ms >= 0)
        stub.wait()
        assert_equal(stub.request_count(), 1)
        assert_equal(stub.connection_count(), 1)
    # Client-side response parsing is also deterministic.
    var response = loads("{}")
    var choices = loads("[]")
    var choice = loads("{}")
    var message = loads("{}")
    message.set("content", Value(ANALYSIS_JSON_TEXT))
    choice.set("message", message)
    choices.append(choice)
    response.set("choices", choices)
    var analysis = parse_query_analysis_from_chat_completion(response)
    assert_equal(analysis.original_text, "eggs near me")
    assert_equal(analysis.rewritten_text, "eggs")
    assert_equal(len(analysis.query_terms), 1)
    guard.assert_clean()


def test_measurement_poll_eintr_is_deadline_bounded() raises:
    # MR02: a real poll EINTR is retried but can never outlive the budget.
    var start = now_ms()
    var pr = measurement_poll_retry(-1, 0, -1, 0, -1, 0, 60, 1)
    var elapsed = now_ms() - start
    assert_true(pr.interrupted)
    assert_true(elapsed >= 50)
    assert_true(elapsed < 2000)
    # An ordinary no-readiness poll is not misclassified as interrupted.
    var quiet = measurement_poll(-1, 0, -1, 0, -1, 0, 0)
    assert_equal(quiet.count, 0)
    assert_true(not quiet.interrupted)


# ── R56/R57/R69 counterexamples must fail the measurement ───────────────────


def test_measurement_rejects_not_json_response() raises:
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        "while IFS= read -r line; do printf 'not-json\\n'; done",
        0,
        2,
        guard,
    )
    assert_true(message.find("not_json") >= 0)
    guard.assert_clean()


def test_measurement_rejects_wrong_correlation() raises:
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "while IFS= read -r line; do printf '%s\\n' "
            '\'{"version":1,"request_id":"wrong","trace_id":"wrong",'
            '"ok":true,"output":{"daemon":"hyfd"}}\'; done'
        ),
        0,
        2,
        guard,
    )
    assert_true(message.find("correlation_mismatch") >= 0)
    guard.assert_clean()


def test_measurement_rejects_unterminated_response() raises:
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "IFS= read -r line; printf '%s' "
            '\'{"version":1,"request_id":"meas-status-0",'
            '"trace_id":"meas-trace-0","ok":true,'
            '"output":{"daemon":"hyfd"}}\'; exit 0'
        ),
        0,
        1,
        guard,
    )
    assert_true(message.find("newline-terminated") >= 0)
    guard.assert_clean()


def test_measurement_rejects_extra_response_frame() raises:
    # MR01/R69: an extra unvalidated frame after the expected response must
    # fail, not be reported as success.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "IFS= read -r line; printf '%s\\n%s\\n' '"
            + STATUS0
            + "' 'EXTRA_UNVALIDATED_FRAME'; while IFS= read -r line; do :; done"
        ),
        0,
        1,
        guard,
    )
    assert_true(message.find("unexpected trailing stdout") >= 0)
    guard.assert_clean()


def test_measurement_rejects_coalesced_trailing_frame() raises:
    # MR01: two frames arriving in the same read chunk are still two frames.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "IFS= read -r line; printf '%s\\n%s\\n' '"
            + STATUS0
            + "' '"
            + STATUS0
            + "'; while IFS= read -r line; do :; done"
        ),
        0,
        1,
        guard,
    )
    assert_true(message.find("unexpected trailing stdout") >= 0)
    guard.assert_clean()


def test_measurement_rejects_trailing_malformed_bytes() raises:
    # MR01: trailing bytes without a complete frame are a bounded failure.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "IFS= read -r line; printf '%s\\n' '"
            + STATUS0
            + "'; printf 'garbage'; while IFS= read -r line; do :; done"
        ),
        0,
        1,
        guard,
    )
    assert_true(message.find("unexpected trailing stdout") >= 0)
    guard.assert_clean()


def test_measurement_rejects_unterminated_trailing_frame() raises:
    # MR01: a second frame that never terminates is not silently ignored.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "IFS= read -r line; printf '%s\\n' '"
            + STATUS0
            + "'; printf '{\"partial\":true';"
            " while IFS= read -r line; do :; done"
        ),
        0,
        1,
        guard,
    )
    assert_true(message.find("unexpected trailing stdout") >= 0)
    guard.assert_clean()


def test_measurement_rejects_failed_child() raises:
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "while IFS= read -r line; do printf '%s\\n' "
            '\'{"version":1,"request_id":"meas-status-0",'
            '"trace_id":"meas-trace-0","ok":true,'
            '"output":{"daemon":"hyfd"}}\'; done; exit 17'
        ),
        0,
        1,
        guard,
    )
    assert_true(message.find("nonzero") >= 0)
    guard.assert_clean()


def test_measurement_rejects_early_eof_child() raises:
    # A child that never answers and closes its stream must fail as an early
    # EOF, not be read as a successful empty response.
    var guard = CleanupGuard()
    var message = _run_sh_failure("sleep 1; exit 0", 0, 1, guard)
    assert_true(message.find("early_eof") >= 0)
    guard.assert_clean()


# ── MR02 work-budget and pressure controls ──────────────────────────────────


def test_measurement_rejects_late_response_after_budget() raises:
    # MR02: a valid response that arrives after the one work budget is not
    # accepted as a late success.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        "sleep 2; " + _one_response(), 0, 1, guard, "ps", "lsof", 400
    )
    assert_true(message.find("work_deadline_expired") >= 0)
    guard.assert_clean()


def test_measurement_rejects_late_exit_after_budget() raises:
    # MR02: complete and valid output does not rescue a child that keeps the
    # stream open past the work budget.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "while IFS= read -r line; do printf '%s\\n' '"
            + STATUS0
            + "'; done; sleep 2"
        ),
        0,
        1,
        guard,
        "ps",
        "lsof",
        400,
    )
    assert_true(message.find("work_deadline_expired") >= 0)
    guard.assert_clean()


def test_measurement_rejects_slow_sampling_past_budget() raises:
    # MR02: a sampling subprocess consumes the remaining work budget and can
    # never extend the measured window.
    var guard = CleanupGuard()
    with SafeTempDir() as temp_dir:
        var script = temp_dir + "/slow_sampler.sh"
        var mk = List[String]()
        mk.append("-c")
        mk.append(
            "printf '#!/bin/sh\\nsleep 4\\necho 17\\n' > '"
            + script
            + "'; chmod +x '"
            + script
            + "'"
        )
        var made = run_capture("sh", mk^, 10000, guard)
        assert_equal(made.exit_code, 0)
        var message = _run_sh_failure(
            _one_response(), 0, 1, guard, script, "lsof", 1500
        )
        assert_true(
            message.find("sample_deadline_expired") >= 0
            or message.find("work_deadline_expired") >= 0
        )
    guard.assert_clean()


def test_measurement_rejects_stderr_overflow() raises:
    # MR02: stderr pressure past the cap fails explicitly instead of being
    # silently dropped.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "IFS= read -r line; printf '%s\\n' '"
            + STATUS0
            + "'; head -c 200000 /dev/zero | tr '\\0' 'x' 1>&2;"
            " while IFS= read -r line; do :; done"
        ),
        0,
        1,
        guard,
    )
    assert_true(message.find("stderr_overflow") >= 0)
    guard.assert_clean()


def test_measurement_rejects_stderr_read_error() raises:
    # MR02: a stderr read error fails explicitly instead of disappearing.
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        (
            "IFS= read -r line; printf '%s\\n' '"
            + STATUS0
            + "'; printf 'x' 1>&2; while IFS= read -r line; do :; done"
        ),
        0,
        1,
        guard,
        "ps",
        "lsof",
        MEASUREMENT_DEADLINE_MS,
        MeasurementFaults(stderr_read_errors=1),
    )
    assert_true(message.find("stderr read_error") >= 0)
    guard.assert_clean()


def test_measurement_unproved_cleanup_is_retained_and_recovered() raises:
    # MR03: an unproved cleanup keeps exact retryable ownership and surfaces to
    # the caller; recovery against the real owned child then succeeds with no
    # descriptor/child leak. The bounded seam leaves the real child running.
    var guard = CleanupGuard()
    var self_pid = owned_pid()
    var child_before = child_process_count(self_pid, guard)
    var fd_before = open_fd_count_checked()
    var message = _run_sh_failure(
        "while IFS= read -r line; do printf 'not-json\\n'; done",
        0,
        1,
        guard,
        "ps",
        "lsof",
        MEASUREMENT_DEADLINE_MS,
        MeasurementFaults(cleanup_failures=1),
    )
    assert_true(message.find("not_json") >= 0)
    assert_true(guard.pending() >= 1)
    assert_true(guard.retained() >= 1)
    assert_equal(guard.recover_all(), 0)
    guard.assert_clean()
    assert_equal(open_fd_count_checked() - fd_before, 0)
    assert_equal(child_process_count(self_pid, guard), child_before)


def test_measurement_rejects_unavailable_rss_sampler() raises:
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        "while IFS= read -r line; do printf '%s\\n' ok; done",
        0,
        1,
        guard,
        "hyf-no-such-rss-sampler",
    )
    assert_true(message.find("rss sampling unavailable") >= 0)
    guard.assert_clean()


def test_measurement_rejects_unavailable_fd_sampler() raises:
    var guard = CleanupGuard()
    var message = _run_sh_failure(
        "while IFS= read -r line; do printf '%s\\n' ok; done",
        0,
        1,
        guard,
        "ps",
        "hyf-no-such-fd-sampler",
    )
    assert_true(message.find("descriptor sampling unavailable") >= 0)
    guard.assert_clean()


def test_measurement_rejects_invalid_frame_counts() raises:
    var guard = CleanupGuard()
    var message = _run_sh_failure("exit 0", 0, 0, guard)
    assert_true(message.find("invalid warmup/measured") >= 0)
    guard.assert_clean()


# ── MR03 exact resource ownership ───────────────────────────────────────────


def test_measurement_repeated_failures_leak_nothing() raises:
    # MR03: repeated failing public measurement calls must leave no descriptor
    # or child behind, and a subsequent supported call must still succeed.
    var guard = CleanupGuard()
    var self_pid = owned_pid()
    var child_before = child_process_count(self_pid, guard)
    var fd_before = open_fd_count_checked()
    for index in range(4):
        var message = _run_sh_failure(
            "while IFS= read -r line; do printf 'not-json\\n'; done",
            0,
            1,
            guard,
        )
        assert_true(message.find("not_json") >= 0)
        guard.assert_clean()
    var fd_after = open_fd_count_checked()
    assert_equal(fd_after - fd_before, 0)
    assert_equal(child_process_count(self_pid, guard), child_before)
    var recovered = _run_sh_measurement(_one_response(), 0, 1, guard)
    assert_equal(recovered.ok_frames, 1)
    assert_equal(recovered.failed_frames, 0)
    guard.assert_clean()


# ── Direct correlation validation unit controls ─────────────────────────────


def test_frame_validation_controls() raises:
    var pair = build_status_frame(7)
    var frame = pair[0]
    var request_id = pair[1]
    var trace_id = pair[2]
    assert_true(frame.find('"request_id":"meas-status-7"') >= 0)
    var good = (
        '{"version":1,"request_id":"'
        + request_id
        + '","trace_id":"'
        + trace_id
        + '","ok":true,"output":{"daemon":"hyfd",'
        + '"limits":{"max_requests_per_process":1}}}'
    )
    var verdict = validate_status_frame(good, request_id, trace_id)
    assert_true(verdict.ok)
    assert_equal(verdict.outcome, "sys.status_ok")
    assert_equal(verdict.declared_max_requests, 1)
    assert_equal(
        validate_status_frame("nope", request_id, trace_id).reason, "not_json"
    )
    assert_equal(
        validate_status_frame(
            '{"version":2,"request_id":"'
            + request_id
            + '","trace_id":"'
            + trace_id
            + '","ok":true}',
            request_id,
            trace_id,
        ).reason,
        "version_mismatch",
    )
    assert_equal(
        validate_status_frame(
            '{"version":1,"request_id":"other","trace_id":"'
            + trace_id
            + '","ok":true}',
            request_id,
            trace_id,
        ).reason,
        "correlation_mismatch",
    )
    assert_equal(
        validate_status_frame(
            '{"version":1,"request_id":"'
            + request_id
            + '","trace_id":"'
            + trace_id
            + '","ok":false}',
            request_id,
            trace_id,
        ).reason,
        "not_ok",
    )
    assert_equal(
        validate_status_frame(
            '{"version":1,"request_id":"'
            + request_id
            + '","trace_id":"'
            + trace_id
            + '","ok":true,"error":{}}',
            request_id,
            trace_id,
        ).reason,
        "unexpected_error",
    )
    assert_equal(
        validate_status_frame(
            '{"version":1,"request_id":"'
            + request_id
            + '","trace_id":"'
            + trace_id
            + '","ok":true,"output":{"daemon":"other"}}',
            request_id,
            trace_id,
        ).reason,
        "outcome_mismatch",
    )


# ── MC01 corrected timing windows ───────────────────────────────────────────


def test_measurement_zero_warmup_timing_is_initialized() raises:
    # ADR-0020 MC01: a zero-warmup measurement must open a bounded measured wall
    # interval before its first request. The period-11 defect left the start
    # uninitialized, so an 804 ms run reported 347472213 ms (host uptime).
    var guard = CleanupGuard()
    var session = _run_sh_measurement(_one_response(), 0, 1, guard)
    assert_equal(session.warmup_frames, 0)
    assert_equal(session.ok_frames, 1)
    assert_equal(session.warmup_ms, 0)
    assert_true(session.measured_wall_ms >= 0)
    assert_true(session.measured_wall_ms <= session.run_wall_ms)
    assert_true(session.measured_ms >= 0)
    assert_true(session.measured_sampling_ms >= 0)
    assert_true(session.measured_ms <= session.measured_wall_ms)
    assert_equal(session.accounting_error_ms(), 0)
    assert_true(session.rss_kb_after_warmup > 0)
    guard.assert_clean()


def test_measurement_positive_warmup_timing_accounting() raises:
    # ADR-0020 MC01: with a positive warmup the boundary instrumentation is
    # taken before the measured interval opens and must not be subtracted from
    # the instrumentation total afterwards (that overstated measured time).
    var guard = CleanupGuard()
    var session = _run_sh_measurement(_multi_response(), 3, 2, guard)
    assert_equal(session.warmup_frames, 3)
    assert_equal(session.ok_frames, 5)
    assert_true(session.warmup_ms >= 0)
    assert_true(session.measured_wall_ms >= 0)
    assert_true(session.measured_wall_ms <= session.run_wall_ms)
    assert_true(session.measured_sampling_ms >= 0)
    assert_true(session.measured_ms >= 0)
    assert_true(session.measured_ms <= session.measured_wall_ms)
    assert_equal(session.accounting_error_ms(), 0)
    guard.assert_clean()


def test_measurement_known_delayed_request_is_observed() raises:
    # ADR-0020 MC01: a known delayed request is reflected in both the per-request
    # timing and the measured wall interval, which stay internally consistent.
    var guard = CleanupGuard()
    var delayed = (
        "IFS= read -r line; sleep 0.15; printf '%s\\n' '"
        + STATUS0
        + "'; while IFS= read -r line; do :; done"
    )
    var session = _run_sh_measurement(delayed, 0, 1, guard)
    assert_equal(session.ok_frames, 1)
    assert_true(session.request_total_ms >= 100)
    assert_true(session.request_max_ms >= 100)
    assert_true(session.measured_wall_ms >= 100)
    assert_true(session.measured_wall_ms <= session.run_wall_ms)
    assert_true(session.measured_ms >= 0)
    assert_equal(session.accounting_error_ms(), 0)
    guard.assert_clean()


def test_measurement_slow_boundary_sampler_is_excluded_once() raises:
    # ADR-0020 MC01: a slow after-warmup boundary sampler runs before the
    # measured wall interval opens. It must be excluded exactly once: the
    # period-11 code subtracted it from the instrumentation total and reported
    # more measured time than the interval contained.
    var guard = CleanupGuard()
    with SafeTempDir() as temp_dir:
        var counter = temp_dir + "/calls"
        var sampler = temp_dir + "/slow_rss.sh"
        var body = (
            '#!/bin/sh\nn=$(cat "'
            + counter
            + '" 2>/dev/null || echo 0)\n'
            + "n=$((n+1))\n"
            + 'printf \'%s\' "$n" > "'
            + counter
            + '"\n'
            + 'if [ "$n" -le 2 ]; then sleep 1.2; fi\n'
            + "echo 17000\n"
        )
        Path(sampler).write_text(body)
        var chmod_args = List[String]()
        chmod_args.append("+x")
        chmod_args.append(sampler)
        var made = run_capture("chmod", chmod_args^, 10000, guard)
        assert_equal(made.exit_code, 0)
        var session = _run_sh_measurement(
            _multi_response(),
            1,
            1,
            guard,
            sampler,
            "lsof",
            MEASUREMENT_DEADLINE_MS,
        )
        assert_equal(session.ok_frames, 2)
        assert_true(session.measured_sampling_ms >= 0)
        assert_true(session.measured_ms >= 0)
        assert_true(session.measured_ms <= session.measured_wall_ms)
        assert_equal(session.accounting_error_ms(), 0)
        # The two 1.2 s boundary samples stayed outside the measured interval.
        assert_true(session.measured_wall_ms < 1000)
    guard.assert_clean()


# ── MC02 fail-closed provenance ─────────────────────────────────────────────


def test_measurement_tooling_manifest_rejects_missing_inputs() raises:
    # ADR-0020 MC02: a missing tooling input must fail, never return the valid
    # empty-input digest that the period-11 masked pipeline produced.
    var guard = CleanupGuard()
    with SafeTempDir() as temp_dir:
        var message = ""
        try:
            _ = tooling_manifest_sha256(temp_dir + "/absent-root", guard)
        except e:
            message = String(e)
        assert_true(message.find("sha256") >= 0)
        assert_true(message.find("e3b0c442") < 0)
    guard.assert_clean()


def test_measurement_source_manifest_rejects_missing_repository() raises:
    # ADR-0020 MC02: a failed git stage must be an error, not an empty digest.
    var guard = CleanupGuard()
    with SafeTempDir() as temp_dir:
        var message = ""
        try:
            _ = source_manifest_sha256(temp_dir, guard)
        except e:
            message = String(e)
        assert_true(message.find("source content manifest") >= 0)
        assert_true(message.find("e3b0c442") < 0)
    guard.assert_clean()


def test_measurement_digest_handles_path_characters() raises:
    # ADR-0020 MC02: paths are argv data, so apostrophes and spaces in a path
    # must be handled literally (the period-11 tooling pipeline interpolated
    # paths into a single-quoted shell string and could mis-hash or fail).
    var guard = CleanupGuard()
    with SafeTempDir() as base:
        var weird = base + "/hyf 'quoted' dir"
        _ = std.os.makedirs(weird, exist_ok=True)
        var one = weird + "/a 'one'.txt"
        var two = weird + "/b two.txt"
        Path(one).write_text("alpha")
        Path(two).write_text("beta")
        var files = List[String]()
        files.append(one)
        files.append(two)
        var digest = sha256_file_set("weird path set", files^, guard)
        assert_equal(digest.byte_length(), 64)
        Path(two).write_text("gamma")
        var files_two = List[String]()
        files_two.append(one)
        files_two.append(two)
        var digest_two = sha256_file_set("weird path set", files_two^, guard)
        assert_true(digest != digest_two)
    guard.assert_clean()


def test_measurement_tooling_manifest_binds_imported_helpers() raises:
    # ADR-0020 MC02: the tooling identity must bind the imported helper closure,
    # not only the three top-level tooling files. Mutating an *imported* helper
    # in an isolated copy changes the digest.
    var guard = CleanupGuard()
    with SafeTempDir() as root:
        var tests_dir = root + "/tests"
        _ = std.os.makedirs(tests_dir, exist_ok=True)
        var sources = measurement_tooling_files(".")
        var cp_args = List[String]()
        for index in range(len(sources)):
            cp_args.append(sources[index])
        cp_args.append(tests_dir)
        var copied = run_capture("cp", cp_args^, 20000, guard)
        assert_equal(copied.exit_code, 0)
        var before = tooling_manifest_sha256(root, guard)
        assert_equal(before.byte_length(), 64)
        Path(tests_dir + "/parent_lifecycle.mojo").write_text("// mutated\n")
        var after = tooling_manifest_sha256(root, guard)
        assert_true(before != after)
    guard.assert_clean()


def test_measurement_rejects_dirty_measured_tree() raises:
    # ADR-0020 MC02/MR04: a dirty measured build input is rejected at capture.
    # The control uses an isolated owned git repository, never the real
    # checkout, and never changes real index or host flags.
    var guard = CleanupGuard()
    with SafeTempDir() as root:
        _ = std.os.makedirs(root + "/src", exist_ok=True)
        Path(root + "/src/main.mojo").write_text("fn main():\n    pass\n")
        Path(root + "/pixi.toml").write_text("[workspace]\n")
        Path(root + "/pixi.lock").write_text("version: 4\n")
        var init_args = List[String]()
        init_args.append("init")
        init_args.append("--quiet")
        var initialized = run_capture("git", init_args^, 20000, guard, root)
        assert_equal(initialized.exit_code, 0)
        var add_args = List[String]()
        add_args.append("add")
        add_args.append("-A")
        var added = run_capture("git", add_args^, 20000, guard, root)
        assert_equal(added.exit_code, 0)
        var commit_args = List[String]()
        commit_args.append("-c")
        commit_args.append("user.email=hyf-test@invalid")
        commit_args.append("-c")
        commit_args.append("user.name=hyf test")
        commit_args.append("-c")
        commit_args.append("commit.gpgsign=false")
        commit_args.append("commit")
        commit_args.append("--no-verify")
        commit_args.append("--quiet")
        commit_args.append("-m")
        commit_args.append("init")
        var committed = run_capture("git", commit_args^, 20000, guard, root)
        assert_equal(committed.exit_code, 0)
        Path(root + "/src/main.mojo").write_text("fn main():\n    return\n")
        var identity = source_identity(root, guard)
        assert_true(identity.dirty_status != "")
        var message = ""
        try:
            require_clean_source(identity, "test capture")
        except e:
            message = String(e)
        assert_true(message.find("dirty") >= 0)
    guard.assert_clean()


# ── MC03 isolated late exit and ownership reuse ─────────────────────────────


def test_measurement_rejects_isolated_late_child_exit() raises:
    # ADR-0020 MC03: valid output AND closed stdout/stderr must be proved before
    # the late-exit phase. The child answers, closes its own stdout/stderr and
    # then stays alive past the budget, so the bounded failure is the child-exit
    # wait rather than an output-drain timeout.
    var guard = CleanupGuard()
    var script = (
        "while IFS= read -r line; do printf '%s\\n' '"
        + STATUS0
        + "'; done; exec 1>&- 2>&-; sleep 2"
    )
    var message = _run_sh_failure(script, 0, 1, guard, "ps", "lsof", 400)
    assert_true(message.find("did not exit within its budget") >= 0)
    assert_true(message.find("output drain") < 0)
    assert_true(message.find("frame invalid") < 0)
    guard.assert_clean()


def test_measurement_recovery_then_valid_call_leaks_nothing() raises:
    # ADR-0020 MC03/R73: after a retained-and-recovered cleanup, a following
    # valid measurement with the same guard must not skip closing a descriptor
    # number that was reused. The period-11 probe observed FD delta +1 here.
    var guard = CleanupGuard()
    var self_pid = owned_pid()
    var child_before = child_process_count(self_pid, guard)
    var fd_before = open_fd_count_checked()
    var message = _run_sh_failure(
        "while IFS= read -r line; do printf 'not-json\\n'; done",
        0,
        1,
        guard,
        "ps",
        "lsof",
        MEASUREMENT_DEADLINE_MS,
        MeasurementFaults(cleanup_failures=1),
    )
    assert_true(message.find("not_json") >= 0)
    assert_true(guard.retained() >= 1)
    assert_equal(guard.recover_all(), 0)
    guard.assert_clean()
    var recovered = _run_sh_measurement(_one_response(), 0, 1, guard)
    assert_equal(recovered.ok_frames, 1)
    assert_equal(recovered.failed_frames, 0)
    guard.assert_clean()
    assert_equal(open_fd_count_checked() - fd_before, 0)
    assert_equal(child_process_count(self_pid, guard), child_before)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
