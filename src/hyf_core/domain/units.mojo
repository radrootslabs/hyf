from hyf_core.domain.quantity import Quantity, new_quantity


@fieldwise_init
struct ConversionRule(Copyable, Movable):
    var from_unit: String
    var to_unit: String
    var numerator: Int
    var denominator: Int
    var version: String


def unit_dimension(unit: String) -> String:
    var lowered = unit.lower()
    if lowered == "kg" or lowered == "lb" or lowered == "g" or lowered == "oz":
        return "mass"
    if lowered == "l" or lowered == "ml":
        return "volume"
    if lowered == "each" or lowered == "box" or lowered == "bunch":
        return "count"
    return "unknown"


def _power_of_ten_exponent(denominator: Int) raises -> Int:
    if denominator <= 0:
        raise Error("conversion denominator must be positive")
    var remaining = denominator
    var exponent = 0
    while remaining > 1:
        if remaining % 10 != 0:
            raise Error(
                "unsupported conversion denominator (must be a power of ten)"
            )
        remaining //= 10
        exponent += 1
    return exponent


def conversion_rule(
    from_unit: String,
    to_unit: String,
    numerator: Int,
    denominator: Int,
    version: String,
) raises -> ConversionRule:
    if from_unit.strip() == "" or to_unit.strip() == "":
        raise Error("conversion requires from_unit and to_unit")
    if numerator <= 0:
        raise Error("conversion numerator must be positive")
    if unit_dimension(from_unit) != unit_dimension(to_unit):
        raise Error("conversion rule crosses incompatible dimensions")
    _ = _power_of_ten_exponent(denominator)
    return ConversionRule(
        from_unit=String(from_unit),
        to_unit=String(to_unit),
        numerator=numerator,
        denominator=denominator,
        version=String(version),
    )


def apply_conversion(quantity: Quantity, rule: ConversionRule) raises -> Quantity:
    if quantity.unit != rule.from_unit:
        raise Error("conversion rule does not apply to unit " + quantity.unit)
    if quantity.dimension != unit_dimension(rule.to_unit):
        raise Error("conversion rule crosses incompatible dimensions")
    var exponent = _power_of_ten_exponent(rule.denominator)
    var result = quantity.copy()
    result.value = quantity.value * rule.numerator
    result.scale = quantity.scale + exponent
    result.unit = String(rule.to_unit)
    result.dimension = String(unit_dimension(rule.to_unit))
    return result^
