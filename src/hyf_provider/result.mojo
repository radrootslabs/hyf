from std.collections import List

from json import Value, loads, validate

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
    var reason: String


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
        raise Error("provider_schema_invalid")
    if _has_key(response, "error"):
        raise Error("provider_error_payload")
    if not _has_key(response, "choices"):
        raise Error("provider_empty_choices")
    if (
        not response["choices"].is_array()
        or len(response["choices"].array_items()) == 0
    ):
        raise Error("provider_empty_choices")

    var choice = response["choices"][0].clone()
    if not choice.is_object() or not _has_key(choice, "message"):
        raise Error("provider_missing_content")

    var message = choice["message"].clone()
    if not message.is_object():
        raise Error("provider_missing_content")
    if not _has_key(message, "content"):
        raise Error("provider_missing_content")

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

    raise Error("provider_missing_content")


def parse_query_analysis_json(value: Value) raises -> QueryAnalysis:
    if not value.is_object():
        raise Error("provider_schema_invalid")

    var validation_error = _first_validation_error(value.clone())
    if validation_error != "":
        raise Error("provider_schema_invalid")

    try:
        var filters = value["extracted_filters"].clone()
        return QueryAnalysis(
            original_text=value["original_text"].string_value(),
            normalized_text=value["normalized_text"].string_value(),
            rewritten_text=value["rewritten_text"].string_value(),
            query_terms=_string_array(value["query_terms"], "query_terms"),
            normalization_signals=_string_array(
                value["normalization_signals"], "normalization_signals"
            ),
            ranking_hints=_string_array(
                value["ranking_hints"], "ranking_hints"
            ),
            extracted_filters=ExtractedFilters(
                local_intent=filters["local_intent"].bool_value(),
                fulfillment=filters["fulfillment"].string_value(),
                time_window=filters["time_window"].string_value(),
            ),
        )
    except:
        raise Error("provider_schema_invalid")


def _load_query_analysis_content_json(text: String) raises -> Value:
    try:
        return loads(text)
    except:
        raise Error("provider_invalid_json")


def parse_query_analysis_from_chat_completion(
    response: Value,
) raises -> QueryAnalysis:
    var text = extract_chat_completion_text(response)
    return parse_query_analysis_json(_load_query_analysis_content_json(text))
