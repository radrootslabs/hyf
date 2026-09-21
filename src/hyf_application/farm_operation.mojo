from std.collections import List
from json import Value, loads

from hyf_application.context import interpretation_source
from hyf_core.normalization.candidates import Candidate, discover_candidates


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _string_list(value: Value) raises -> List[String]:
    var items = List[String]()
    if not value.is_array():
        return items^
    for entry in value.array_items():
        if entry.is_string():
            items.append(entry.string_value())
    return items^


def _string_array_value(items: List[String]) raises -> Value:
    var array = loads("[]")
    for item in items:
        array.append(Value(String(item)))
    return array^


def _evidence_value(evidence: Candidate) raises -> Value:
    var value = loads("{}")
    value.set("start", Value(evidence.start))
    value.set("end", Value(evidence.end))
    value.set("method", Value("span"))
    return value^


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

    var products = List[String]()
    var units = List[String]()
    var dates = List[String]()
    if _has_key(input, "taxonomy"):
        var taxonomy = input["taxonomy"]
        if _has_key(taxonomy, "products"):
            products = _string_list(taxonomy["products"])
        if _has_key(taxonomy, "units"):
            units = _string_list(taxonomy["units"])
        if _has_key(taxonomy, "dates"):
            dates = _string_list(taxonomy["dates"])

    var candidates = discover_candidates(
        parsed.text, products, units, dates
    )

    var claims = loads("[]")
    var review_required = False
    var claim_index = 1
    for candidate in candidates:
        if candidate.kind != "product":
            continue
        var claim = loads("{}")
        claim.set("claim_id", Value("claim-" + String(claim_index)))
        var product = loads("{}")
        product.set("phrase", Value(String(candidate.text)))
        product.set("catalogue_id", Value(String(candidate.text)))
        product.set("resolution", Value("resolved"))
        claim.set("product", product)
        claim.set("status", Value("unclear"))
        var evidence = loads("[]")
        evidence.append(_evidence_value(candidate))
        claim.set("evidence", evidence)
        claim.set("review_required", Value(True))
        claims.append(claim)
        review_required = True
        claim_index += 1

    var output = loads("{}")
    output.set("claims", claims)
    output.set("proposed_changes", loads("[]"))
    var review = loads("{}")
    review.set("required", Value(review_required))
    var clarifications = loads("[]")
    if review_required:
        var clarification = loads("{}")
        clarification.set("field", Value("status"))
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
