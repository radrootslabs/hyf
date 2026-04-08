from std.collections import List

from mojson import Value, loads

from hyf_core.provenance import (
    CoreResponseMeta,
    ExecutionProvenance,
    ProvenanceSourceRef,
)
from hyf_core.request_context import RequestContext


def _require_object(value: Value, context: String) raises:
    if not value.is_object():
        raise Error(context + " must be a JSON object")


def _require_allowed_keys(
    value: Value, key_a: String, key_b: String, context: String
) raises:
    for key in value.object_keys():
        if key != key_a and key != key_b:
            raise Error(context + " contains unexpected field '" + key + "'")


def has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def copy_string_list(items: List[String]) -> List[String]:
    var copied = List[String]()
    for item in items:
        copied.append(String(item))
    return copied^


def string_array_value(items: List[String]) raises -> Value:
    var array = loads("[]")
    for item in items:
        array.append(Value(String(item)))
    return array^


def collapse_whitespace(text: String) -> String:
    var parts = text.split()
    var collapsed = String()
    var first = True
    for part in parts:
        if not first:
            collapsed += " "
        collapsed += String(part)
        first = False
    return collapsed^


def join_strings(items: List[String]) -> String:
    var joined = String()
    var first = True
    for item in items:
        if not first:
            joined += " "
        joined += String(item)
        first = False
    return joined^


def normalize_free_text(text: String, mut signals: List[String]) -> String:
    var normalized = text.lower()
    if normalized != text:
        signals.append("lowercase")

    var replaced = normalized
    replaced = replaced.replace(",", " ")
    replaced = replaced.replace(".", " ")
    replaced = replaced.replace("!", " ")
    replaced = replaced.replace("?", " ")
    replaced = replaced.replace(":", " ")
    replaced = replaced.replace(";", " ")
    replaced = replaced.replace("/", " ")
    replaced = replaced.replace("\\", " ")
    replaced = replaced.replace("(", " ")
    replaced = replaced.replace(")", " ")
    replaced = replaced.replace("[", " ")
    replaced = replaced.replace("]", " ")
    replaced = replaced.replace("{", " ")
    replaced = replaced.replace("}", " ")
    replaced = replaced.replace("\"", " ")
    replaced = replaced.replace("'", " ")
    replaced = replaced.replace("-", " ")
    if replaced != normalized:
        signals.append("punctuation_trimmed")

    var collapsed = collapse_whitespace(replaced)
    if collapsed != replaced:
        signals.append("whitespace_collapsed")

    return collapsed^


def contains_token(items: List[String], token: String) -> Bool:
    for item in items:
        if item == token:
            return True
    return False


def _is_stop_word(token: String) -> Bool:
    return (
        token == "a"
        or token == "an"
        or token == "and"
        or token == "for"
        or token == "from"
        or token == "in"
        or token == "me"
        or token == "near"
        or token == "of"
        or token == "on"
        or token == "the"
        or token == "to"
        or token == "with"
    )


@fieldwise_init
struct ExtractedFilters(Copyable, Movable):
    var local_intent: Bool
    var fulfillment: String
    var time_window: String


@fieldwise_init
struct QueryAnalysis(Copyable, Movable):
    var original_text: String
    var normalized_text: String
    var rewritten_text: String
    var query_terms: List[String]
    var normalization_signals: List[String]
    var ranking_hints: List[String]
    var extracted_filters: ExtractedFilters


@fieldwise_init
struct QueryRewriteRequest(Copyable, Movable):
    var text: String


def extract_text_input(input: Value, capability_name: String) raises -> String:
    if not input.is_object():
        raise Error(capability_name + " input must be a JSON object")

    if has_key(input, "text"):
        var text_value = input["text"]
        if not text_value.is_string():
            raise Error(
                capability_name + " input field 'text' must be a string"
            )
        var collapsed = collapse_whitespace(text_value.string_value())
        if collapsed == "":
            raise Error(capability_name + " input text must not be empty")
        return collapsed^
    elif has_key(input, "query"):
        var query_value = input["query"]
        if not query_value.is_string():
            raise Error(
                capability_name + " input field 'query' must be a string"
            )
        var collapsed = collapse_whitespace(query_value.string_value())
        if collapsed == "":
            raise Error(capability_name + " input text must not be empty")
        return collapsed^
    else:
        raise Error(
            capability_name + " input requires 'text' or 'query'"
        )


def parse_query_rewrite_request(input: Value) raises -> QueryRewriteRequest:
    _require_object(input, "query_rewrite input")
    _require_allowed_keys(input, "text", "query", "query_rewrite input")

    var has_text = has_key(input, "text")
    var has_query = has_key(input, "query")

    if has_text and has_query:
        raise Error(
            "query_rewrite input must provide exactly one of 'text' or 'query'"
        )
    if not has_text and not has_query:
        raise Error(
            "query_rewrite input requires exactly one of 'text' or 'query'"
        )

    var source_field = "text" if has_text else "query"
    var text_value = input[source_field]
    if not text_value.is_string():
        raise Error(
            "query_rewrite input field '" + source_field + "' must be a string"
        )

    var collapsed = collapse_whitespace(text_value.string_value())
    if collapsed == "":
        raise Error("query_rewrite input text must not be empty")

    return QueryRewriteRequest(text=collapsed)


def analyze_query_text(
    original_text: String, context: RequestContext
) -> QueryAnalysis:
    var normalized_input = String(original_text)

    var normalization_signals = List[String]()
    var normalized_text = normalize_free_text(
        normalized_input, normalization_signals
    )
    var normalized_tokens = normalized_text.split()

    var query_terms = List[String]()
    var ranking_hints = List[String]()
    var local_intent = False
    var fulfillment = "unspecified"
    var time_window = "unspecified"
    var removed_stop_words = False
    var extracted_filter_tokens = False

    for raw_token in normalized_tokens:
        var token = String(raw_token)
        if token == "":
            continue

        if (
            token == "near"
            or token == "me"
            or token == "nearby"
            or token == "local"
        ):
            local_intent = True
            extracted_filter_tokens = True
            continue

        if token == "pickup" or token == "curbside":
            fulfillment = "pickup"
            extracted_filter_tokens = True
            continue

        if token == "delivery" or token == "ship" or token == "shipping":
            fulfillment = "delivery"
            extracted_filter_tokens = True
            continue

        if token == "weekend" or token == "saturday" or token == "sunday":
            time_window = "weekend"
            extracted_filter_tokens = True
            continue

        if _is_stop_word(token):
            removed_stop_words = True
            continue

        if not contains_token(query_terms, token):
            query_terms.append(token)

    if local_intent:
        normalization_signals.append("local_intent_detected")
        ranking_hints.append("prefer_local_results")
    if fulfillment == "pickup":
        normalization_signals.append("pickup_filter_detected")
        ranking_hints.append("prefer_pickup")
    elif fulfillment == "delivery":
        normalization_signals.append("delivery_filter_detected")
        ranking_hints.append("prefer_delivery")
    if time_window == "weekend":
        normalization_signals.append("weekend_filter_detected")
        ranking_hints.append("prefer_weekend_availability")
    if removed_stop_words:
        normalization_signals.append("stopwords_removed")
    if extracted_filter_tokens:
        normalization_signals.append("filter_tokens_extracted")
    if context.scope:
        ranking_hints.append("respect_scope")
        normalization_signals.append("scope_present")

    if len(query_terms) == 0:
        query_terms.append(String(normalized_text))
        normalization_signals.append("fallback_to_normalized_query")

    return QueryAnalysis(
        original_text=normalized_input,
        normalized_text=normalized_text,
        rewritten_text=join_strings(query_terms),
        query_terms=query_terms^,
        normalization_signals=normalization_signals^,
        ranking_hints=ranking_hints^,
        extracted_filters=ExtractedFilters(
            local_intent=local_intent,
            fulfillment=fulfillment,
            time_window=time_window,
        ),
    )


def analyze_query(
    input: Value, context: RequestContext, capability_name: String
) raises -> QueryAnalysis:
    var original_text = extract_text_input(input, capability_name)
    return analyze_query_text(original_text, context)


def serialize_extracted_filters(filters: ExtractedFilters) raises -> Value:
    var value = loads("{}")
    value.set("local_intent", Value(filters.local_intent))
    value.set("fulfillment", Value(String(filters.fulfillment)))
    value.set("time_window", Value(String(filters.time_window)))
    return value^


def query_signal_tags(analysis: QueryAnalysis) -> List[String]:
    var signal_tags = copy_string_list(analysis.normalization_signals)
    for hint in analysis.ranking_hints:
        signal_tags.append(String(hint))
    return signal_tags^


def build_deterministic_meta(
    context: RequestContext,
    capability_name: String,
    signal_tags: List[String],
    extra_source_refs: List[ProvenanceSourceRef],
) -> CoreResponseMeta:
    var source_refs = List[ProvenanceSourceRef]()
    source_refs.append(
        ProvenanceSourceRef(
            source_kind="local_input",
            source_ref=capability_name + ":input",
        )
    )
    for source_ref in extra_source_refs:
        source_refs.append(
            ProvenanceSourceRef(
                source_kind=String(source_ref.source_kind),
                source_ref=String(source_ref.source_ref),
            )
        )
    if context.scope:
        source_refs.append(
            ProvenanceSourceRef(
                source_kind="request_scope",
                source_ref="request_context.scope",
            )
        )

    if context.return_provenance:
        return CoreResponseMeta(
            execution_mode="deterministic",
            backend="heuristic",
            latency_ms=0,
            provenance=ExecutionProvenance(
                kind="deterministic",
                signal_tags=copy_string_list(signal_tags),
                source_refs=source_refs^,
                fallback=None,
                evidence_set_id=None,
            ),
        )

    return CoreResponseMeta(
        execution_mode="deterministic",
        backend="heuristic",
        latency_ms=0,
        provenance=None,
    )
