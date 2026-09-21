from std.collections import List, Optional

from hyf_core.domain.supply_change import ProposedSupplyChange, proposed_change


def resolve_change_target(
    operation: String,
    requested_target: Optional[String],
    authorized_targets: List[String],
) raises -> ProposedSupplyChange:
    var resolved_target: Optional[String] = None
    if requested_target:
        var requested = requested_target.value()
        for authorized in authorized_targets:
            if authorized == requested:
                resolved_target = Optional[String](String(requested))
    return proposed_change(
        target_kind="listing",
        target_id=resolved_target,
        operation=operation,
        expected_revision=None,
    )
