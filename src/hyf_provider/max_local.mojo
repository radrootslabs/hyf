from std.collections import Optional
from std.time import perf_counter_ns

from hyf_assist.contract import max_local_query_rewrite_route
from hyf_core.capabilities.query_analysis import QueryAnalysis
from hyf_core.request_context import RequestContext
from hyf_provider.client import (
    make_max_local_http_client,
    max_local_chat_completions_url,
)
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.health import resolve_max_local_provider_status
from hyf_provider.result import (
    MaxLocalProviderStatus,
    parse_query_analysis_from_chat_completion,
)
from hyf_provider.schema import (
    build_query_rewrite_request_body,
    query_rewrite_prompt_version,
    query_rewrite_schema_version,
)


@fieldwise_init
struct MaxLocalQueryRewriteResult(Copyable, Movable):
    var analysis: QueryAnalysis
    var provider: String
    var route: String
    var model: String
    var latency_ms: Int
    var schema_version: Int
    var prompt_version: String


@fieldwise_init
struct MaxLocalQueryRewriteFailure(Copyable, Movable):
    var kind: String
    var reason: String


@fieldwise_init
struct MaxLocalQueryRewriteOutcome(Copyable, Movable):
    var result: Optional[MaxLocalQueryRewriteResult]
    var failure: Optional[MaxLocalQueryRewriteFailure]


def _query_rewrite_success_outcome(
    result: MaxLocalQueryRewriteResult
) -> MaxLocalQueryRewriteOutcome:
    return MaxLocalQueryRewriteOutcome(
        result=Optional[MaxLocalQueryRewriteResult](result.copy()),
        failure=Optional[MaxLocalQueryRewriteFailure](None),
    )


def _query_rewrite_failure_outcome(
    kind: String, reason: String
) -> MaxLocalQueryRewriteOutcome:
    return MaxLocalQueryRewriteOutcome(
        result=Optional[MaxLocalQueryRewriteResult](None),
        failure=Optional[MaxLocalQueryRewriteFailure](
            MaxLocalQueryRewriteFailure(
                kind=String(kind), reason=String(reason)
            )
        ),
    )


def _elapsed_ms_since(start_ns: UInt) -> Int:
    return Int((perf_counter_ns() - start_ns) // 1_000_000)


def max_local_query_rewrite_failure_from_error(
    message: String,
) -> MaxLocalQueryRewriteFailure:
    if message == "invalid_url":
        return MaxLocalQueryRewriteFailure(
            kind="transport", reason="invalid_url"
        )
    if message == "timeout":
        return MaxLocalQueryRewriteFailure(
            kind="transport", reason="timeout"
        )
    if message == "connection_failed":
        return MaxLocalQueryRewriteFailure(
            kind="transport", reason="connection_failed"
        )
    if message == "provider_non_2xx":
        return MaxLocalQueryRewriteFailure(
            kind="http_status", reason="provider_non_2xx"
        )
    if message == "provider_error_payload":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_error_payload"
        )
    if message == "provider_invalid_json":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_invalid_json"
        )
    if message == "provider_schema_invalid":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_schema_invalid"
        )
    if message == "provider_empty_choices":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_empty_choices"
        )
    if message == "provider_missing_content":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_missing_content"
        )
    return MaxLocalQueryRewriteFailure(
        kind="provider", reason="provider_error"
    )


def execute_query_rewrite_via_max_local_provider(
    config: MaxLocalProviderConfig, text: String, context: RequestContext
) raises -> MaxLocalQueryRewriteResult:
    var outcome = try_execute_query_rewrite_via_max_local_provider(
        config, text, context
    )
    if outcome.result:
        return outcome.result.value().copy()
    if outcome.failure:
        raise Error(String(outcome.failure.value().reason))
    raise Error("provider_error")


def try_execute_query_rewrite_via_max_local_provider(
    config: MaxLocalProviderConfig, text: String, context: RequestContext
) -> MaxLocalQueryRewriteOutcome:
    with make_max_local_http_client(config) as client:
        var start_ns = perf_counter_ns()
        try:
            var response = client.post(
                max_local_chat_completions_url(config),
                build_query_rewrite_request_body(config, text, context),
            )
            var latency_ms = Int(
                (perf_counter_ns() - start_ns) // 1_000_000
            )
            if not response.ok():
                return _query_rewrite_failure_outcome(
                    "http_status", "provider_non_2xx"
                )

            var analysis = parse_query_analysis_from_chat_completion(
                response.json()
            )
            return _query_rewrite_success_outcome(
                MaxLocalQueryRewriteResult(
                    analysis=analysis^,
                    provider="max_local",
                    route=max_local_query_rewrite_route(),
                    model=String(config.model),
                    latency_ms=latency_ms,
                    schema_version=query_rewrite_schema_version(),
                    prompt_version=query_rewrite_prompt_version(),
                )
            )
        except e:
            var failure = max_local_query_rewrite_failure_from_error(
                String(e)
            )
            if (
                failure.reason == "provider_error"
                and _elapsed_ms_since(start_ns) >= config.request_timeout_ms
            ):
                failure = MaxLocalQueryRewriteFailure(
                    kind="transport", reason="timeout"
                )
            return _query_rewrite_failure_outcome(
                String(failure.kind), String(failure.reason)
            )


def max_local_provider_status(
    config: MaxLocalProviderConfig,
) -> MaxLocalProviderStatus:
    return resolve_max_local_provider_status(config)
