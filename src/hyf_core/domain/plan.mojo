from std.collections import List


@fieldwise_init
struct Allocation(Copyable, Movable):
    var lot_id: String
    var revision: String
    var line_id: String
    var value: Int
    var scale: Int


@fieldwise_init
struct LotCapacity(Copyable, Movable):
    var lot_id: String
    var revision: String
    var value: Int
    var scale: Int


@fieldwise_init
struct MatchPlan(Copyable, Movable):
    var plan_id: String
    var supplier_id: String
    var allocations: List[Allocation]


def allocation(
    lot_id: String, revision: String, line_id: String, value: Int, scale: Int
) raises -> Allocation:
    if lot_id.strip() == "" or revision.strip() == "" or line_id.strip() == "":
        raise Error("allocation requires lot id, revision and line id")
    if value < 0:
        raise Error("allocation value must be non-negative")
    return Allocation(
        lot_id=String(lot_id),
        revision=String(revision),
        line_id=String(line_id),
        value=value,
        scale=scale,
    )


def match_plan(
    plan_id: String, supplier_id: String, allocations: List[Allocation]
) raises -> MatchPlan:
    if plan_id.strip() == "" or supplier_id.strip() == "":
        raise Error("plan requires plan id and supplier id")
    var copied = List[Allocation]()
    for entry in allocations:
        copied.append(entry.copy())
    return MatchPlan(
        plan_id=String(plan_id), supplier_id=String(supplier_id), allocations=copied^
    )


def _rescale(value: Int, scale: Int, target: Int) -> Int:
    var result = value
    for _ in range(target - scale):
        result *= 10
    return result


def plan_conservation_violations(
    plan: MatchPlan, lots: List[LotCapacity]
) raises -> List[String]:
    var violations = List[String]()
    var lot_keys = List[String]()
    var allocated = List[Int]()
    var allocated_scale = List[Int]()
    for entry in plan.allocations:
        var key = entry.lot_id + "@" + entry.revision
        var found = -1
        for index in range(len(lot_keys)):
            if lot_keys[index] == key:
                found = index
        var scale = entry.scale
        var value = entry.value
        if found >= 0:
            if allocated_scale[found] > scale:
                scale = allocated_scale[found]
            value = _rescale(value, entry.scale, scale) + _rescale(
                allocated[found], allocated_scale[found], scale
            )
            allocated[found] = value
            allocated_scale[found] = scale
        else:
            lot_keys.append(String(key))
            allocated.append(value)
            allocated_scale.append(scale)

    for index in range(len(lot_keys)):
        var capacity_value = -1
        var capacity_scale = 0
        for lot in lots:
            if lot.lot_id + "@" + lot.revision == lot_keys[index]:
                capacity_value = lot.value
                capacity_scale = lot.scale
        var scale = capacity_scale if capacity_scale > allocated_scale[index] else allocated_scale[index]
        if capacity_value < 0:
            violations.append(lot_keys[index] + ": unknown capacity")
            continue
        if _rescale(allocated[index], allocated_scale[index], scale) > _rescale(
            capacity_value, capacity_scale, scale
        ):
            violations.append(lot_keys[index] + ": over-allocated")
    return violations^
