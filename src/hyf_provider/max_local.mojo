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


def execute_query_rewrite_via_max_local_provider(
    config: MaxLocalProviderConfig, text: String, context: RequestContext
) raises -> MaxLocalQueryRewriteResult:
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

        return MaxLocalQueryRewriteResult(
            analysis=parse_query_analysis_from_chat_completion(
                response.json()
            ),
            provider="max_local",
            route=String(config.route),
            model=String(config.model),
            latency_ms=0,
            schema_version=query_rewrite_schema_version(),
            prompt_version=query_rewrite_prompt_version(),
        )


def max_local_provider_status(
    config: MaxLocalProviderConfig,
) -> MaxLocalProviderStatus:
    return resolve_max_local_provider_status(config)
