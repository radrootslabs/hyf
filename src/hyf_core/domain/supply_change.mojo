from std.collections import Optional


@fieldwise_init
struct ProposedSupplyChange(Copyable, Movable):
    var target_kind: String
    var target_id: Optional[String]
    var operation: String
    var expected_revision: Optional[String]
    var unresolved: Bool


def proposed_change(
    target_kind: String,
    target_id: Optional[String],
    operation: String,
    expected_revision: Optional[String],
) raises -> ProposedSupplyChange:
    var kinds = ["listing", "product", "farm"]
    var kind_known = False
    for candidate in kinds:
        if candidate == target_kind:
            kind_known = True
    if not kind_known:
        raise Error("target kind must be listing, product or farm")
    var operations = [
        "addition",
        "remaining",
        "replacement",
        "withdrawal",
        "correction",
        "unresolved",
    ]
    var operation_known = False
    for candidate in operations:
        if candidate == operation:
            operation_known = True
    if not operation_known:
        raise Error("unknown supply change operation: " + operation)

    var resolved_operation = String(operation)
    var unresolved = False
    if (
        operation == "withdrawal" or operation == "correction"
    ) and not target_id:
        resolved_operation = "unresolved"
        unresolved = True

    return ProposedSupplyChange(
        target_kind=String(target_kind),
        target_id=target_id.copy(),
        operation=resolved_operation,
        expected_revision=expected_revision.copy(),
        unresolved=unresolved,
    )


def change_expands_to_farm(change: ProposedSupplyChange) -> Bool:
    return False
