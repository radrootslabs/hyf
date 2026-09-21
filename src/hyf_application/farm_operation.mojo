from json import Value, loads

from hyf_application.context import interpretation_source
from hyf_application.farm_failure import farm_inference_failure
from hyf_application.farm_review_output import assemble_farm_output
from hyf_core.domain.execution import execution_meta
from hyf_core.domain.review import review_required


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def execute_farm_update_interpret(input: Value) raises -> Value:
    if not input.is_object() or not _has_key(input, "source"):
        raise Error("farm_update.interpret input requires 'source'")
    var source = input["source"]
    var parsed = interpretation_source(
        source_id=source["source_id"].string_value(),
        revision=source["revision"].string_value(),
        text=source["text"].string_value(),
        source_time=source["source_time"].string_value(),
        timezone=source["timezone"].string_value(),
        actor_id=source["actor_id"].string_value(),
        farm_id=source["farm_id"].string_value(),
    )
    _ = parsed
    var output = loads("{}")
    var claims = loads("[]")
    output.set("claims", claims)
    var changes = loads("[]")
    output.set("proposed_changes", changes)
    var review = loads("{}")
    review.set("required", Value(True))
    var clarifications = loads("[]")
    var clarification = loads("{}")
    clarification.set("field", Value("review"))
    clarification.set("reason", Value("information_needed"))
    clarifications.append(clarification)
    review.set("clarifications", clarifications)
    output.set("review", review)
    var execution = loads("{}")
    execution.set("status", Value("complete"))
    execution.set("provider_calls", Value(0))
    output.set("execution", execution)
    output.set("original_source_preserved", Value(True))
    return output^
