"""H005A measurement contract tests (ADR-0012 D29, ADR-0014 D34).

Drives the governed persistent-process measurement tooling against a real
build of the existing product entry point and against controlled child
processes, proving that the reproduced H005 defects (R56/R57) now fail the
measurement instead of reporting success: not-json output, wrong correlation,
unterminated output, early EOF, a failed child and unavailable ``ps``/``lsof``
sampling.

This module is test-only tooling. It changes no product policy, schema,
dependency or lock.
"""

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

from safe_tempdir import SafeTempDir

from parent_lifecycle import CleanupGuard, owned_pid, now_ms
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
)
from measurement_process_helper import (
    MeasurementSession,
    build_product_binary,
    build_status_frame,
    file_sha256,
    measure_persistent_process,
    run_capture,
    sample_fd_count,
    sample_rss_kb,
    validate_status_frame,
)
from json import Value, loads

from hyf_core.request_context import default_request_context
from hyf_provider.client import post_max_local_chat_completion
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.result import parse_query_analysis_from_chat_completion
from hyf_provider.schema import build_query_rewrite_request_body
from max_local_process_helper import (
    reserve_loopback_port,
    spawn_max_local_stub,
)


comptime MEASUREMENT_DEADLINE_MS = 120000
comptime WARMUP_FRAMES = 20
comptime MEASURED_FRAMES = 200


def _sh(args_text: String) -> List[String]:
    var args = List[String]()
    args.append("-c")
    args.append(args_text)
    return args^


def _run_sh_measurement(
    args_text: String,
    warmup: Int,
    measured: Int,
    mut guard: CleanupGuard,
    rss_sampler: String = "ps",
    fd_sampler: String = "lsof",
) raises -> MeasurementSession:
    var argv = _sh(args_text)
    return measure_persistent_process(
        ".",
        "/bin/sh",
        "argv=[/bin/sh -c <controlled child>]",
        "env=minimal; HYF_PATHS_PROFILE=repo_local",
        argv^,
        warmup,
        measured,
        MEASUREMENT_DEADLINE_MS,
        guard,
        rss_sampler,
        fd_sampler,
    )


# ── Positive persistent measurement ─────────────────────────────────────────


def test_persistent_measurement_validates_every_frame() raises:
    # D29: one process serves warmup and measured frames; every frame has a
    # parsed envelope, matching correlation and expected outcome, with numeric
    # RSS/FD samples, a checked child exit and proved cleanup.
    var guard = CleanupGuard()
    with SafeTempDir() as temp_dir:
        var binary = build_product_binary(temp_dir, guard)
        assert_true(file_sha256(binary, guard).byte_length() == 64)
        var argv = List[String]()
        var session = measure_persistent_process(
            ".",
            binary,
            "argv=[<hyfd>]",
            "env=HYF_PATHS_PROFILE=repo_local HYF_PATHS_REPO_LOCAL_ROOT=<temp>",
            argv^,
            WARMUP_FRAMES,
            MEASURED_FRAMES,
            MEASUREMENT_DEADLINE_MS,
            guard,
        )
        assert_equal(session.ok_frames, WARMUP_FRAMES + MEASURED_FRAMES)
        assert_equal(session.failed_frames, 0)
        assert_equal(session.first_failure, "")
        # Startup, warmup and measured timing are recorded separately (ms).
        assert_true(session.startup_ms >= 0)
        assert_true(session.measured_ms >= 0)
        # Numeric sampling with recorded units and method.
        assert_true(session.rss_kb_before_warmup > 0)
        assert_true(session.rss_kb_after_warmup > 0)
        assert_true(session.rss_kb_after_measured > 0)
        assert_true(session.rss_kb_peak >= session.rss_kb_after_warmup)
        assert_true(session.fd_before_warmup > 0)
        assert_true(session.fd_after_measured > 0)
        assert_true(session.fd_peak >= session.fd_after_measured)
        assert_true(session.sampling_method.find("kB") >= 0)
        assert_true(session.sampling_method.find("-F f") >= 0)
        # The declared per-process request policy is characterized, not assumed:
        # it is a declared limit that the persistent loop does not enforce.
        assert_equal(session.declared_max_requests_per_process, 1)
        assert_true(session.child_exit.find("exited=0") >= 0)
        assert_true(session.stderr_excerpt == "")
        # Identity is exact and reproducible.
        assert_equal(len(session.identity.binary_sha256), 64)
        assert_equal(len(session.identity.pixi_lock_sha256), 64)
        assert_equal(len(session.identity.pixi_toml_sha256), 64)
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
    # D29: distinguish startup, a deterministic daemon request, a direct local
    # provider request and connection counts, and characterize client/schema
    # construction with source evidence. The Morph daemon-assisted path is out
    # of scope here and remains an explicit H024 obligation.
    var guard = CleanupGuard()
    var startup_start = now_ms()
    with spawn_max_local_stub(0, "count_requests", 1, guard) as stub:
        var startup_ms = now_ms() - startup_start
        assert_true(startup_ms >= 0)
        var config = MaxLocalProviderConfig(
            base_url="http://127.0.0.1:" + String(stub.port) + "/v1/",
            health_url="http://127.0.0.1:" + String(stub.port) + "/health",
            model="max-local-query-rewrite",
            request_timeout_ms=15000,
        )
        var context = default_request_context()
        context.return_provenance = True
        var body = build_query_rewrite_request_body(
            config, "eggs near me", context
        )
        # Schema construction is deterministic and source-verifiable.
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
        # One direct provider request over one verified connection.
        var outcome = post_max_local_chat_completion(config, body)
        assert_true(not outcome.failure)
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


# ── R56/R57 counterexamples must fail the measurement ───────────────────────


def test_measurement_rejects_not_json_response() raises:
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement(
            "while IFS= read -r line; do printf 'not-json\\n'; done",
            0,
            2,
            guard,
        )
    except e:
        message = String(e)
    assert_true(message.find("not_json") >= 0)
    guard.assert_clean()


def test_measurement_rejects_wrong_correlation() raises:
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement(
            (
                "while IFS= read -r line; do printf '%s\\n' "
                '\'{"version":1,"request_id":"wrong","trace_id":"wrong",'
                '"ok":true,"output":{"daemon":"hyfd"}}\'; done'
            ),
            0,
            2,
            guard,
        )
    except e:
        message = String(e)
    assert_true(message.find("correlation_mismatch") >= 0)
    guard.assert_clean()


def test_measurement_rejects_unterminated_response() raises:
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement(
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
    except e:
        message = String(e)
    assert_true(message.find("newline-terminated") >= 0)
    guard.assert_clean()


def test_measurement_rejects_failed_child() raises:
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement(
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
    except e:
        message = String(e)
    assert_true(message.find("nonzero") >= 0)
    guard.assert_clean()


def test_measurement_rejects_early_eof_child() raises:
    # A child that never answers and closes its stream must fail as an early
    # EOF, not be read as a successful empty response.
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement("sleep 1; exit 0", 0, 1, guard)
    except e:
        message = String(e)
    assert_true(message.find("measurement") >= 0)
    assert_true(
        message.find("early_eof") >= 0
        or message.find("write") >= 0
        or message.find("descriptor sampling") >= 0
    )
    guard.assert_clean()


def test_measurement_rejects_unavailable_rss_sampler() raises:
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement(
            "while IFS= read -r line; do printf '%s\\n' ok; done",
            0,
            1,
            guard,
            "hyf-no-such-rss-sampler",
        )
    except e:
        message = String(e)
    assert_true(message.find("rss sampling unavailable") >= 0)
    guard.assert_clean()


def test_measurement_rejects_unavailable_fd_sampler() raises:
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement(
            "while IFS= read -r line; do printf '%s\\n' ok; done",
            0,
            1,
            guard,
            "ps",
            "hyf-no-such-fd-sampler",
        )
    except e:
        message = String(e)
    assert_true(message.find("descriptor sampling unavailable") >= 0)
    guard.assert_clean()


def test_measurement_rejects_invalid_frame_counts() raises:
    var guard = CleanupGuard()
    var message = ""
    try:
        _ = _run_sh_measurement("exit 0", 0, 0, guard)
    except e:
        message = String(e)
    assert_true(message.find("invalid warmup/measured") >= 0)
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
