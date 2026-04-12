from tempo import Timestamp

from hyf_assist.contract import AssistQueryRewriteResult
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
    query_rewrite_schema_version,
)


def execute_query_rewrite_via_max_local_provider(
    config: MaxLocalProviderConfig, text: String, context: RequestContext
) raises -> AssistQueryRewriteResult:
    var started_at_ms = Timestamp.now().unix_ms()
    with make_max_local_http_client(config) as client:
        var response = client.post(
            max_local_chat_completions_url(config),
            build_query_rewrite_request_body(config, text, context),
        )
        if not response.ok():
            raise Error(
                "max_local provider returned HTTP "
                + String(response.status)
            )

        var analysis = parse_query_analysis_from_chat_completion(
            response.json()
        )
        var latency_ms = Int(Timestamp.now().unix_ms() - started_at_ms)
        if latency_ms < 0:
            latency_ms = 0

        return AssistQueryRewriteResult(
            analysis=analysis^,
            provider="max_local",
            route=String(config.route),
            model=String(config.model),
            latency_ms=latency_ms,
            schema_version=query_rewrite_schema_version(),
        )


def max_local_provider_status(
    config: MaxLocalProviderConfig,
) -> MaxLocalProviderStatus:
    return resolve_max_local_provider_status(config)
