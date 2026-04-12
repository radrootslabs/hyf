from mojson import Value, loads

from hyf_core.request_context import RequestContext
from hyf_provider.config import MaxLocalProviderConfig


def query_rewrite_schema_version() -> Int:
    return 1


def query_rewrite_schema() raises -> Value:
    var schema = loads("{}")
    schema.set("type", Value("object"))
    schema.set("additionalProperties", Value(False))

    var required = loads("[]")
    required.append(Value("original_text"))
    required.append(Value("normalized_text"))
    required.append(Value("rewritten_text"))
    required.append(Value("query_terms"))
    required.append(Value("normalization_signals"))
    required.append(Value("ranking_hints"))
    required.append(Value("extracted_filters"))
    schema.set("required", required)

    var properties = loads("{}")
    properties.set("original_text", loads('{"type":"string"}'))
    properties.set("normalized_text", loads('{"type":"string"}'))
    properties.set("rewritten_text", loads('{"type":"string"}'))
    properties.set(
        "query_terms",
        loads('{"type":"array","items":{"type":"string"}}'),
    )
    properties.set(
        "normalization_signals",
        loads('{"type":"array","items":{"type":"string"}}'),
    )
    properties.set(
        "ranking_hints",
        loads('{"type":"array","items":{"type":"string"}}'),
    )
    properties.set(
        "extracted_filters",
        loads(
            '{"type":"object","additionalProperties":false,"required":["local_intent","fulfillment","time_window"],"properties":{"local_intent":{"type":"boolean"},"fulfillment":{"type":"string"},"time_window":{"type":"string"}}}'
        ),
    )
    schema.set("properties", properties)
    return schema^


def query_rewrite_system_prompt() -> String:
    return (
        "Return only strict JSON matching the supplied schema. Preserve "
        + "original_text, normalized_text, rewritten_text, query_terms, "
        + "normalization_signals, ranking_hints, and extracted_filters."
    )


def build_query_rewrite_user_prompt(
    text: String, context: RequestContext
) -> String:
    var prompt = (
        "Rewrite the market search query into normalized search terms and "
        + "extracted filters.\nquery: "
        + text
        + "\n"
    )

    if context.scope and len(context.scope.value().listing_ids) > 0:
        var first = True
        prompt += "scope_listing_ids: "
        for listing_id in context.scope.value().listing_ids:
            if not first:
                prompt += ","
            prompt += String(listing_id)
            first = False
        prompt += "\n"

    if context.time_range:
        prompt += (
            "time_range: "
            + context.time_range.value().start
            + " -> "
            + context.time_range.value().end
            + "\n"
        )

    prompt += "consistency: " + context.consistency + "\n"
    prompt += "evidence_limit: " + String(context.evidence_limit) + "\n"
    prompt += "explain_plan: " + String(context.explain_plan) + "\n"
    return prompt^


def build_query_rewrite_request_body(
    config: MaxLocalProviderConfig, text: String, context: RequestContext
) raises -> Value:
    var body = loads("{}")
    body.set("model", Value(String(config.model)))

    var messages = loads("[]")

    var system_message = loads("{}")
    system_message.set("role", Value("system"))
    system_message.set("content", Value(query_rewrite_system_prompt()))
    messages.append(system_message)

    var user_message = loads("{}")
    user_message.set("role", Value("user"))
    user_message.set(
        "content", Value(build_query_rewrite_user_prompt(text, context))
    )
    messages.append(user_message)

    body.set("messages", messages)
    body.set("temperature", Value(0.1))
    body.set("max_tokens", Value(256))

    var response_format = loads("{}")
    response_format.set("type", Value("json_schema"))

    var json_schema = loads("{}")
    json_schema.set("name", Value("query_rewrite"))
    json_schema.set("strict", Value(True))
    json_schema.set("schema", query_rewrite_schema())
    response_format.set("json_schema", json_schema)

    body.set("response_format", response_format)
    return body^
