from std.collections import Optional

from hyf_core.domain.demand import Condition, condition


def interpret_condition_strength(phrase: String) -> String:
    var lowered = phrase.lower()
    if lowered == "required" or lowered == "must" or lowered == "need":
        return "mandatory"
    if lowered == "ideally" or lowered == "prefer" or lowered == "preferred":
        return "preferred"
    if lowered == "not" or lowered == "no" or lowered == "exclude":
        return "excluded"
    if lowered == "fine" or lowered == "ok" or lowered == "permitted":
        return "permitted"
    return "preferred"


def interpret_buyer_condition(
    kind: String, phrase: String, value: Optional[String]
) raises -> Condition:
    var strength = interpret_condition_strength(phrase)
    if strength == "excluded" and not value:
        return condition(kind, strength, None)
    return condition(kind, strength, value)


def delivery_exclusion_means_pickup() -> Bool:
    return False


def missing_information_is_prohibition() -> Bool:
    return False
