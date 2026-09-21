from std.collections import List, Optional

from hyf_core.domain.product import ProductRef


@fieldwise_init
struct Condition(Copyable, Movable):
    var kind: String
    var strength: String
    var value: Optional[String]


@fieldwise_init
struct DemandLine(Copyable, Movable):
    var line_id: String
    var product: ProductRef
    var quantity_state: String
    var quantity_value: Int
    var quantity_scale: Int
    var unit: String
    var conditions: List[Condition]


def condition(
    kind: String, strength: String, value: Optional[String]
) raises -> Condition:
    if kind.strip() == "":
        raise Error("condition kind must not be empty")
    var strengths = ["mandatory", "preferred", "excluded", "permitted"]
    var known = False
    for candidate in strengths:
        if candidate == strength:
            known = True
    if not known:
        raise Error("unknown condition strength: " + strength)
    if strength != "excluded" and not value:
        raise Error("non-excluded condition requires a value")
    return Condition(
        kind=String(kind), strength=String(strength), value=value.copy()
    )


def demand_line(
    line_id: String,
    product: ProductRef,
    quantity_state: String,
    quantity_value: Int,
    quantity_scale: Int,
    conditions: List[Condition],
) raises -> DemandLine:
    if line_id.strip() == "":
        raise Error("demand line requires an id")
    if quantity_state != "known" and quantity_state != "unknown":
        raise Error("demand quantity state must be 'known' or 'unknown'")
    var copied = List[Condition]()
    for entry in conditions:
        copied.append(entry.copy())
    return DemandLine(
        line_id=String(line_id),
        product=product.copy(),
        quantity_state=String(quantity_state),
        quantity_value=quantity_value,
        quantity_scale=quantity_scale,
        unit="kg",
        conditions=copied^,
    )


def condition_is_exclusion(value: Condition) -> Bool:
    return value.strength == "excluded"


def missing_information_is_prohibition() -> Bool:
    return False
