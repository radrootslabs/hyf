from std.collections import List


@fieldwise_init
struct ConstraintAssessment(Copyable, Movable):
    var kind: String
    var result: String
    var mandatory: Bool
    var reason: String


def constraint_assessment(
    kind: String, result: String, mandatory: Bool, reason: String
) raises -> ConstraintAssessment:
    if kind.strip() == "":
        raise Error("constraint kind must not be empty")
    if result != "pass" and result != "fail" and result != "unknown":
        raise Error("constraint result must be 'pass', 'fail' or 'unknown'")
    if reason.strip() == "":
        raise Error("constraint reason must not be empty")
    return ConstraintAssessment(
        kind=String(kind),
        result=String(result),
        mandatory=mandatory,
        reason=String(reason),
    )


def compose_eligibility(checks: List[ConstraintAssessment]) -> String:
    var mandatory_fail = False
    var mandatory_unknown = False
    for check in checks:
        if not check.mandatory:
            continue
        if check.result == "fail":
            mandatory_fail = True
        elif check.result == "unknown":
            mandatory_unknown = True
    if mandatory_fail:
        return "ineligible"
    if mandatory_unknown:
        return "conditional"
    return "eligible"
