from std.collections import List

from hyf_core.domain.plan import (
    Allocation,
    LotCapacity,
    MatchPlan,
    allocation,
    match_plan,
    plan_conservation_violations,
)


def group_lots_by_supplier(
    lot_ids: List[String], supplier_ids: List[String]
) raises -> List[String]:
    if len(lot_ids) != len(supplier_ids):
        raise Error("lot ids and supplier ids must align")
    var suppliers = List[String]()
    for supplier in supplier_ids:
        if String(supplier).strip().byte_length() == 0:
            raise Error("supplier id must not be empty")
        var seen = False
        for existing in suppliers:
            if existing == supplier:
                seen = True
        if not seen:
            suppliers.append(String(supplier))
    return suppliers^


def allocate_single_line(
    plan_id: String,
    line_id: String,
    supplier_id: String,
    required_value: Int,
    required_scale: Int,
    lots: List[LotCapacity],
) raises -> MatchPlan:
    var remaining = required_value
    var allocations = List[Allocation]()
    for lot in lots:
        if remaining <= 0:
            break
        var capacity = lot.value
        var take = remaining if remaining < capacity else capacity
        allocations.append(
            allocation(lot.lot_id, lot.revision, line_id, take, lot.scale)
        )
        remaining -= take
    return match_plan(plan_id, supplier_id, allocations)


def multi_supplier_is_supported() -> Bool:
    return False
