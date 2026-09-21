from hyf_core.domain.quantity import Quantity
from hyf_core.domain.units import unit_dimension


@fieldwise_init
struct PackRule(Copyable, Movable):
    var product_id: String
    var pack_unit: String
    var inner_unit: String
    var per_pack_value: Int
    var per_pack_scale: Int
    var version: String


def pack_rule(
    product_id: String,
    pack_unit: String,
    inner_unit: String,
    per_pack_value: Int,
    per_pack_scale: Int,
    version: String,
) raises -> PackRule:
    if product_id.strip() == "" or version.strip() == "":
        raise Error("pack rule requires product_id and version")
    if pack_unit.strip() == "" or inner_unit.strip() == "":
        raise Error("pack rule requires pack_unit and inner_unit")
    if per_pack_value <= 0:
        raise Error("pack rule per_pack_value must be positive")
    if per_pack_scale < 0 or per_pack_scale > 9:
        raise Error("pack rule per_pack_scale must be between 0 and 9")
    if unit_dimension(inner_unit) == "unknown":
        raise Error("pack rule inner_unit dimension is unknown")
    return PackRule(
        product_id=String(product_id),
        pack_unit=String(pack_unit),
        inner_unit=String(inner_unit),
        per_pack_value=per_pack_value,
        per_pack_scale=per_pack_scale,
        version=String(version),
    )


def apply_pack_conversion(
    product_id: String, packs: Quantity, rule: PackRule
) raises -> Quantity:
    if product_id != rule.product_id:
        raise Error("pack rule does not apply to product " + product_id)
    if packs.unit != rule.pack_unit:
        raise Error("pack rule does not apply to unit " + packs.unit)
    var result = packs.copy()
    result.value = packs.value * rule.per_pack_value
    result.scale = packs.scale + rule.per_pack_scale
    result.unit = String(rule.inner_unit)
    result.dimension = String(unit_dimension(rule.inner_unit))
    return result^
