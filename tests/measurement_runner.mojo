"""Standalone governed H005A measurement entry point (ADR-0012 D29).

Runs one persistent HYF stdio process through warmup and measured frames and
prints the exact identity, per-phase timing, numeric RSS/FD samples, frame
counts and child exit. Exits nonzero on any failed mandatory guarantee.

ADR-0019 D39 MR04 additionally records the numeric direct-local-provider
elapsed time, request/connection counts and the deterministic client/schema
construction characterization, so the pre-migration baseline is source-backed
rather than a test duration or an unprinted assertion.

Usage (governed lane): ``cargo extbuild run -- pixi run --frozen measure-h005a``
"""

from std.collections import List

from safe_tempdir import SafeTempDir

from parent_lifecycle import CleanupGuard, now_ms
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
)
from measurement_process_helper import (
    build_product_binary,
    measure_persistent_process,
)
from max_local_process_helper import spawn_max_local_stub

from json import Value, loads

from hyf_core.request_context import default_request_context
from hyf_provider.client import post_max_local_chat_completion
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.result import parse_query_analysis_from_chat_completion
from hyf_provider.schema import build_query_rewrite_request_body


comptime MEASUREMENT_DEADLINE_MS = 180000
comptime WARMUP_FRAMES = 100
comptime MEASURED_FRAMES = 1000

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


def characterize_direct_provider(mut guard: CleanupGuard) raises:
    """Numeric direct-local-provider and client/schema characterization.

    One direct provider request over one verified connection against the local
    stub: the elapsed stub-startup, schema-construction and request times and
    the request/connection counts are printed, and the deterministic request
    body/response parsing is proved. The Morph daemon-assisted path is out of
    scope here and remains the explicit H024 obligation.
    """
    var stub_start = now_ms()
    with spawn_max_local_stub(0, "count_requests", 1, guard) as stub:
        var stub_startup_ms = now_ms() - stub_start
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
        var response_format = body["response_format"]
        print(
            "h005a.client_schema",
            "fields=" + String(body.object_count()),
            "messages=" + String(body["messages"].array_count()),
            "response_format_type=" + response_format["type"].string_value(),
            "json_schema_name="
            + response_format["json_schema"]["name"].string_value(),
            "model=" + body["model"].string_value(),
        )
        var request_start = now_ms()
        var outcome = post_max_local_chat_completion(config, body)
        var request_ms = now_ms() - request_start
        stub.wait()
        var failure_text = "false"
        if outcome.failure:
            failure_text = "true"
        print(
            "h005a.direct_provider",
            "stub_startup_ms=" + String(stub_startup_ms),
            "construct_ms=" + String(construct_ms),
            "request_ms=" + String(request_ms),
            "requests=" + String(stub.request_count()),
            "connections=" + String(stub.connection_count()),
            "failure=" + failure_text,
        )
        if outcome.failure:
            raise Error("measurement: direct provider request failed")
        if stub.request_count() != 1:
            raise Error("measurement: direct provider request count mismatch")
        if stub.connection_count() != 1:
            raise Error(
                "measurement: direct provider connection count mismatch"
            )
    var response = loads("{}")
    var choices = loads("[]")
    var choice = loads("{}")
    var message = loads("{}")
    message.set("content", Value(ANALYSIS_JSON_TEXT))
    choice.set("message", message)
    choices.append(choice)
    response.set("choices", choices)
    var analysis = parse_query_analysis_from_chat_completion(response)
    if analysis.original_text != "eggs near me":
        raise Error("measurement: provider response parsing mismatch")
    if len(analysis.query_terms) != 1:
        raise Error("measurement: provider response term count mismatch")


def main() raises:
    var guard = CleanupGuard()
    var source_root = "."
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var built = build_product_binary(source_root, temp_dir, guard)
                print(
                    "h005a.build",
                    "build_ms=" + String(built.build_ms),
                    built.source.describe(),
                )
                var argv = List[String]()
                var measured = measure_persistent_process(
                    source_root,
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
                print("h005a.identity", measured.identity.describe())
                print("h005a.measurement", measured.summary())
                print("h005a.sampling_method", measured.sampling_method)
                print("h005a.sampling_cadence", measured.sampling_cadence)
                print(
                    "h005a.stderr_bytes",
                    measured.stderr_excerpt.byte_length(),
                )
        characterize_direct_provider(guard)
    guard.assert_clean()
    print("h005a_measurement: ok")
