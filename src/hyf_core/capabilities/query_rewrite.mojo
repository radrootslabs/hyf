from std.collections import List, Optional

from mojson import Value, loads

from hyf_core.errors import (
    CapabilityResult,
    failed_capability,
    invalid_input_error,
    successful_capability,
)
from hyf_core.provenance import (
    CoreResponseMeta,
    ExecutionProvenance,
    ProvenanceSourceRef,
)
from hyf_core.request_context import RequestContext


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _copy_strings(items: List[String]) -> List[String]:
    var copied = List[String]()
    for item in items:
        copied.append(String(item))
    return copied^


def _string_array(items: List[String]) raises -> Value:
    var array = loads("[]")
    for item in items:
        array.append(Value(String(item)))
    return array^


def _collapse_whitespace(text: String) -> String:
    var parts = text.split()
    var collapsed = String()
    var first = True
    for part in parts:
        if not first:
            collapsed += " "
        collapsed += String(part)
        first = False
    return collapsed^


def _join_strings(items: List[String]) -> String:
    var joined = String()
    var first = True
    for item in items:
        if not first:
            joined += " "
        joined += String(item)
        first = False
    return joined^


def _normalize_text(text: String, mut signals: List[String]) -> String:
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

    var collapsed = _collapse_whitespace(replaced)
    if collapsed != replaced:
        signals.append("whitespace_collapsed")

    return collapsed^


def _contains_token(items: List[String], token: String) -> Bool:
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


def _extract_text_input(input: Value) raises -> String:
    if not input.is_object():
        raise Error("query_rewrite input must be a JSON object")

    if _has_key(input, "text"):
        var text_value = input["text"]
        if not text_value.is_string():
            raise Error("query_rewrite input field 'text' must be a string")
        var collapsed = _collapse_whitespace(text_value.string_value())
        if collapsed == "":
            raise Error("query_rewrite input text must not be empty")
        return collapsed^
    elif _has_key(input, "query"):
        var query_value = input["query"]
        if not query_value.is_string():
            raise Error("query_rewrite input field 'query' must be a string")
        var collapsed = _collapse_whitespace(query_value.string_value())
        if collapsed == "":
            raise Error("query_rewrite input text must not be empty")
        return collapsed^
    else:
        raise Error("query_rewrite input requires 'text' or 'query'")


def _build_output(
    original_text: String,
    normalized_text: String,
    rewritten_text: String,
    query_terms: List[String],
    normalization_signals: List[String],
    ranking_hints: List[String],
    local_intent: Bool,
    fulfillment: String,
    time_window: String,
) raises -> Value:
    var output = loads("{}")
    output.set("original_text", Value(String(original_text)))
    output.set("normalized_text", Value(String(normalized_text)))
    output.set("rewritten_text", Value(String(rewritten_text)))
    output.set("query_terms", _string_array(query_terms))
    output.set("normalization_signals", _string_array(normalization_signals))
    output.set("ranking_hints", _string_array(ranking_hints))

    var filters = loads("{}")
    filters.set("local_intent", Value(local_intent))
    filters.set("fulfillment", Value(String(fulfillment)))
    filters.set("time_window", Value(String(time_window)))
    output.set("extracted_filters", filters)
    return output^


def _build_meta(
    context: RequestContext,
    normalization_signals: List[String],
    ranking_hints: List[String],
) -> Optional[CoreResponseMeta]:
    var source_refs = List[ProvenanceSourceRef]()
    source_refs.append(
        ProvenanceSourceRef(
            source_kind="local_input",
            source_ref="query_rewrite:input",
        )
    )
    if context.scope:
        source_refs.append(
            ProvenanceSourceRef(
                source_kind="request_scope",
                source_ref="request_context.scope",
            )
        )

    var signal_tags = _copy_strings(normalization_signals)
    for hint in ranking_hints:
        signal_tags.append(String(hint))

    if context.return_provenance:
        return CoreResponseMeta(
            mode="a",
            backend="heuristic",
            latency_ms=0,
            provenance=ExecutionProvenance(
                kind="deterministic",
                signal_tags=signal_tags^,
                source_refs=source_refs^,
                fallback=None,
                evidence_set_id=None,
            ),
        )

    return CoreResponseMeta(
        mode="a",
        backend="heuristic",
        latency_ms=0,
        provenance=None,
    )


def execute_query_rewrite(
    input: Value, context: RequestContext
) raises -> CapabilityResult:
    try:
        var original_text = _extract_text_input(input)

        var normalization_signals = List[String]()
        var normalized_text = _normalize_text(original_text, normalization_signals)
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

            if not _contains_token(query_terms, token):
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

        var rewritten_text = _join_strings(query_terms)

        return successful_capability(
            _build_output(
                original_text=original_text,
                normalized_text=normalized_text,
                rewritten_text=rewritten_text,
                query_terms=query_terms,
                normalization_signals=normalization_signals,
                ranking_hints=ranking_hints,
                local_intent=local_intent,
                fulfillment=fulfillment,
                time_window=time_window,
            ),
            meta=_build_meta(
                context=context,
                normalization_signals=normalization_signals,
                ranking_hints=ranking_hints,
            ),
        )
    except e:
        return failed_capability(invalid_input_error(String(e)))
