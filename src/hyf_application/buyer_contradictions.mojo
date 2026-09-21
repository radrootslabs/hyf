from std.collections import List

from hyf_core.domain.demand import Condition


def detect_contradictions(conditions: List[Condition]) -> List[String]:
    var contradictions = List[String]()
    for required in conditions:
        if required.strength != "mandatory":
            continue
        for excluded in conditions:
            if excluded.strength != "excluded":
                continue
            if required.kind != excluded.kind:
                continue
            var required_value = ""
            if required.value:
                required_value = required.value.value()
            var excluded_value = ""
            if excluded.value:
                excluded_value = excluded.value.value()
            if required_value == excluded_value and required_value != "":
                var token = "contradiction:" + required.kind
                var seen = False
                for existing in contradictions:
                    if existing == token:
                        seen = True
                if not seen:
                    contradictions.append(String(token))
    return contradictions^


def contradictions_are_visible() -> Bool:
    return True
