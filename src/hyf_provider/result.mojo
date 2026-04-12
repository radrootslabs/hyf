from std.collections import List

from mojson import Value, loads, validate

from hyf_core.capabilities.query_analysis import (
    ExtractedFilters,
    QueryAnalysis,
)
from hyf_provider.schema import query_rewrite_schema


@fieldwise_init
struct MaxLocalProviderStatus(Copyable, Movable):
    var backend_kind: String
    var provider: String
    var route: String
    var model: String
    var reachable: Bool
    var state: String


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _string_array(value: Value, context: String) raises -> List[String]:
    if not value.is_array():
        raise Error(context + " must be an array")

    var items = List[String]()
    for item in value.array_items():
        if not item.is_string():
            raise Error(context + " items must be strings")
        items.append(item.string_value())
    return items^


def _first_validation_error(value: Value) raises -> String:
    var validation = validate(value, query_rewrite_schema())
    if validation.valid:
        return ""
    if len(validation.errors) == 0:
        return "query_rewrite structured output failed schema validation"
    var error = validation.errors[0].copy()
    if error.path == "":
        return String(error.message)
    return String(error.path) + ": " + String(error.message)


def extract_chat_completion_text(response: Value) raises -> String:
    if not response.is_object():
        raise Error("max_local response must be a JSON object")
    if not _has_key(response, "choices"):
        raise Error("max_local response must contain choices")
    if (
        not response["choices"].is_array()
        or len(response["choices"].array_items()) == 0
    ):
        raise Error("max_local response choices must be a non-empty array")

    var message = response["choices"][0]["message"].clone()
    if not message.is_object():
        raise Error("max_local response choice message must be an object")

    var content = message["content"].clone()
    if content.is_string():
        return content.string_value()

    if content.is_array():
        var collected = String("")
        for part in content.array_items():
            if (
                part.is_object()
                and _has_key(part, "type")
                and part["type"].is_string()
                and part["type"].string_value() == "text"
                and _has_key(part, "text")
                and part["text"].is_string()
            ):
                collected += part["text"].string_value()

        if collected != "":
            return collected^

    raise Error("max_local response contained no text content")


def parse_query_analysis_json(value: Value) raises -> QueryAnalysis:
    if not value.is_object():
        raise Error("query_rewrite structured output must be an object")

    var validation_error = _first_validation_error(value.clone())
    if validation_error != "":
        raise Error(validation_error)

    var filters = value["extracted_filters"].clone()
    return QueryAnalysis(
        original_text=value["original_text"].string_value(),
        normalized_text=value["normalized_text"].string_value(),
        rewritten_text=value["rewritten_text"].string_value(),
        query_terms=_string_array(value["query_terms"], "query_terms"),
        normalization_signals=_string_array(
            value["normalization_signals"], "normalization_signals"
        ),
        ranking_hints=_string_array(value["ranking_hints"], "ranking_hints"),
        extracted_filters=ExtractedFilters(
            local_intent=filters["local_intent"].bool_value(),
            fulfillment=filters["fulfillment"].string_value(),
            time_window=filters["time_window"].string_value(),
        ),
    )


def parse_query_analysis_from_chat_completion(
    response: Value,
) raises -> QueryAnalysis:
    return parse_query_analysis_json(loads(extract_chat_completion_text(response)))
