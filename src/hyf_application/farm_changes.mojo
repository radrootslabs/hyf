from std.collections import List, Optional

from hyf_core.domain.supply_change import ProposedSupplyChange, proposed_change


def interpret_update_operation(verb: String) -> String:
    var lowered = verb.lower()
    if lowered == "another" or lowered == "more" or lowered == "added":
        return "addition"
    if lowered == "left" or lowered == "remaining":
        return "remaining"
    if lowered == "total":
        return "replacement"
    if lowered == "sold out" or lowered == "gone" or lowered == "withdrawn":
        return "withdrawal"
    if lowered == "actually" or lowered == "correction":
        return "correction"
    return "unresolved"


def interpret_update_change(
    verb: String, target_kind: String, target_id: Optional[String]
) raises -> ProposedSupplyChange:
    return proposed_change(
        target_kind=target_kind,
        target_id=target_id,
        operation=interpret_update_operation(verb),
        expected_revision=None,
    )


def operation_is_proposal() -> Bool:
    return True
