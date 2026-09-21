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


@fieldwise_init
struct PlannerBounds(Copyable, Movable):
    var max_candidates: Int
    var max_plans: Int


def planner_bounds(max_candidates: Int, max_plans: Int) raises -> PlannerBounds:
    if max_candidates <= 0 or max_plans <= 0:
        raise Error("planner bounds must be positive")
    return PlannerBounds(max_candidates=max_candidates, max_plans=max_plans)


def enforce_plan_bound(plan_count: Int, bounds: PlannerBounds) raises:
    if plan_count > bounds.max_plans:
        raise Error("plan enumeration exceeds the bound")


def allocate_multiple_lines(
    plan_id: String,
    supplier_id: String,
    line_ids: List[String],
    required_values: List[Int],
    lots: List[LotCapacity],
) raises -> MatchPlan:
    if len(line_ids) != len(required_values):
        raise Error("line ids and requirements must align")
    var remaining = List[Int]()
    for lot in lots:
        remaining.append(lot.value)
    var allocations = List[Allocation]()
    for index in range(len(line_ids)):
        var needed = required_values[index]
        for lot_index in range(len(lots)):
            if needed <= 0:
                break
            if remaining[lot_index] <= 0:
                continue
            var capacity = remaining[lot_index]
            var take = needed if needed < capacity else capacity
            allocations.append(
                allocation(
                    lots[lot_index].lot_id,
                    lots[lot_index].revision,
                    line_ids[index],
                    take,
                    lots[lot_index].scale,
                )
            )
            remaining[lot_index] -= take
            needed -= take
    return match_plan(plan_id, supplier_id, allocations)


def shared_lot_allows_concurrent_over_allocation() -> Bool:
    return False


@fieldwise_init
struct PartialOutcome(Copyable, Movable):
    var fulfilled: Bool
    var uncovered_value: Int
    var permitted: Bool


def partial_outcome(
    required_value: Int, allocated_value: Int, partial_allowed: Bool
) raises -> PartialOutcome:
    if required_value < 0 or allocated_value < 0:
        raise Error("partial outcome requires non-negative quantities")
    if allocated_value >= required_value:
        return PartialOutcome(fulfilled=True, uncovered_value=0, permitted=True)
    var uncovered = required_value - allocated_value
    return PartialOutcome(
        fulfilled=False, uncovered_value=uncovered, permitted=partial_allowed
    )


def partial_discloses_deficit() -> Bool:
    return True
