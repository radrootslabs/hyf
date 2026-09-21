from std.collections import List

from json import Value

from hyf_assist.evaluator import TypedAnswer, typed_choice, typed_noul, typed_score


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def parse_noul_answer(question_id: String, value: Value) raises -> TypedAnswer:
    if not value.is_object() or not _has_key(value, "type"):
        raise Error("provider_answer_invalid")
    if value["type"].string_value() != "noul":
        raise Error("provider_answer_wrong_type")
    if not _has_key(value, "noul") or not value["noul"].is_float():
        raise Error("provider_answer_invalid")
    var probability = value["noul"].float_value()
    if probability < 0.0 or probability > 1.0:
        raise Error("provider_answer_noul_out_of_range")
    return typed_noul(question_id, probability)


def parse_choice_answer(
    question_id: String, value: Value, choices: List[String]
) raises -> TypedAnswer:
    if not value.is_object() or not _has_key(value, "type"):
        raise Error("provider_answer_invalid")
    if value["type"].string_value() != "choice":
        raise Error("provider_answer_wrong_type")
    if not _has_key(value, "choice"):
        raise Error("provider_answer_invalid")
    var selected = value["choice"].string_value()
    var known = False
    for choice in choices:
        if choice == selected:
            known = True
    if not known:
        raise Error("provider_answer_unknown_choice")
    if not _has_key(value, "confidence") or not value["confidence"].is_float():
        raise Error("provider_answer_invalid")
    var confidence = value["confidence"].float_value()
    if confidence < 0.0 or confidence > 1.0:
        raise Error("provider_answer_confidence_out_of_range")
    if _has_key(value, "probabilities"):
        var probabilities = value["probabilities"]
        if not probabilities.is_object():
            raise Error("provider_answer_invalid")
        var total = 0.0
        for choice in choices:
            if not _has_key(probabilities, choice):
                raise Error("provider_answer_missing_probability")
            total += probabilities[choice].float_value()
        if total < 0.999 or total > 1.001:
            raise Error("provider_answer_bad_distribution_sum")
    return typed_choice(question_id, selected, confidence)
