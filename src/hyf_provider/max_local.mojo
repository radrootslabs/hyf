from std.collections import Optional

from json import Value, loads

from hyf_assist.contract import max_local_query_rewrite_route
from hyf_core.capabilities.query_analysis import QueryAnalysis
from hyf_core.request_context import RequestContext
from hyf_provider.client import post_max_local_chat_completion
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


def max_local_query_rewrite_failure_from_reason(
    reason: String,
) -> MaxLocalQueryRewriteFailure:
    if reason == "invalid_url":
        return MaxLocalQueryRewriteFailure(
            kind="transport", reason="invalid_url"
        )
    if reason == "timeout":
        return MaxLocalQueryRewriteFailure(
            kind="transport", reason="timeout"
        )
    if reason == "connection_failed":
        return MaxLocalQueryRewriteFailure(
            kind="transport", reason="connection_failed"
        )
    if reason == "unknown_transport":
        return MaxLocalQueryRewriteFailure(
            kind="provider", reason="provider_error"
        )
    if reason == "provider_non_2xx":
        return MaxLocalQueryRewriteFailure(
            kind="http_status", reason="provider_non_2xx"
        )
    if reason == "provider_error_payload":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_error_payload"
        )
    if reason == "provider_invalid_json":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_invalid_json"
        )
    if reason == "provider_schema_invalid":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_schema_invalid"
        )
    if reason == "provider_empty_choices":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_empty_choices"
        )
    if reason == "provider_missing_content":
        return MaxLocalQueryRewriteFailure(
            kind="provider_payload", reason="provider_missing_content"
        )
    return MaxLocalQueryRewriteFailure(
        kind="provider", reason="provider_error"
    )


def _load_chat_completion_response_json(text: String) raises -> Value:
    try:
        return loads(text)
    except:
        raise Error("provider_invalid_json")


def _parse_query_analysis_from_body(text: String) raises -> QueryAnalysis:
    return parse_query_analysis_from_chat_completion(
        _load_chat_completion_response_json(text)
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
    var request_body: Value
    try:
        request_body = build_query_rewrite_request_body(config, text, context)
    except:
        return _query_rewrite_failure_outcome("provider", "provider_error")

    var transport = post_max_local_chat_completion(
        config,
        request_body^,
    )
    if transport.failure:
        var failure = max_local_query_rewrite_failure_from_reason(
            transport.failure.value().reason
        )
        return _query_rewrite_failure_outcome(
            String(failure.kind), String(failure.reason)
        )

    if transport.response:
        try:
            var response = transport.response.value().copy()
            var analysis = _parse_query_analysis_from_body(response.body_text)
            return _query_rewrite_success_outcome(
                MaxLocalQueryRewriteResult(
                    analysis=analysis^,
                    provider="max_local",
                    route=max_local_query_rewrite_route(),
                    model=String(config.model),
                    latency_ms=response.latency_ms,
                    schema_version=query_rewrite_schema_version(),
                    prompt_version=query_rewrite_prompt_version(),
                )
            )
        except e:
            var failure = max_local_query_rewrite_failure_from_reason(
                String(e)
            )
            return _query_rewrite_failure_outcome(
                String(failure.kind), String(failure.reason)
            )

    return _query_rewrite_failure_outcome("provider", "provider_error")


def max_local_provider_status(
    config: MaxLocalProviderConfig,
) -> MaxLocalProviderStatus:
    return resolve_max_local_provider_status(config)
