from json import Value, loads

from hyf_application.context import interpretation_source


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _validate_source(input: Value) raises:
    if not input.is_object() or not _has_key(input, "source"):
        raise Error("buyer operation input requires 'source'")
    var source = input["source"]
    _ = interpretation_source(
        source_id=source["source_id"].string_value(),
        revision=source["revision"].string_value(),
        text=source["text"].string_value(),
        source_time=source["source_time"].string_value(),
        timezone=source["timezone"].string_value(),
        actor_id=source["actor_id"].string_value(),
        farm_id=source["farm_id"].string_value(),
    )


def execute_buyer_request_interpret(input: Value) raises -> Value:
    _validate_source(input)
    var output = loads("{}")
    var lines = loads("[]")
    output.set("demand_lines", lines)
    var review = loads("{}")
    review.set("required", Value(True))
    var clarifications = loads("[]")
    var clarification = loads("{}")
    clarification.set("field", Value("demand_lines"))
    clarification.set("reason", Value("information_needed"))
    clarifications.append(clarification)
    review.set("clarifications", clarifications)
    output.set("review", review)
    var execution = loads("{}")
    execution.set("status", Value("complete"))
    execution.set("provider_calls", Value(0))
    output.set("execution", execution)
    return output^


def execute_buyer_request_match(input: Value) raises -> Value:
    if not input.is_object() or not _has_key(input, "need"):
        raise Error("buyer_request.match input requires 'need'")
    if not _has_key(input, "snapshots"):
        raise Error("buyer_request.match input requires 'snapshots'")
    var output = loads("{}")
    output.set("assessments", loads("[]"))
    output.set("plans", loads("[]"))
    var limitations = loads("{}")
    limitations.set("scope", Value("supplied_only"))
    limitations.set("truncated", Value(False))
    limitations.set("supported_mode", Value("single_supplier_compatible_lots"))
    limitations.set("unsupported", loads("[]"))
    output.set("limitations", limitations)
    var execution = loads("{}")
    execution.set("status", Value("complete"))
    execution.set("provider_calls", Value(0))
    output.set("execution", execution)
    return output^
