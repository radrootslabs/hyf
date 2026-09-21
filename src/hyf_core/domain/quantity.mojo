from std.collections import Optional


@fieldwise_init
struct Quantity(Copyable, Movable):
    var value: Int
    var scale: Int
    var unit: String
    var dimension: String
    var qualifier: String


def _pow10(exponent: Int) -> Int:
    var result = 1
    for _ in range(exponent):
        result *= 10
    return result


def _checked_mul10(value: Int, times: Int) raises -> Int:
    var result = value
    for _ in range(times):
        var before = result
        result = before * 10
        if before != 0 and result // 10 != before:
            raise Error("quantity overflow")
    return result


def _checked_add(left: Int, right: Int) raises -> Int:
    var result = left + right
    if left > 0 and right > 0 and result < 0:
        raise Error("quantity overflow")
    if left < 0 and right < 0 and result >= 0:
        raise Error("quantity overflow")
    return result


def new_quantity(
    value: Int, scale: Int, unit: String, dimension: String, qualifier: String
) raises -> Quantity:
    if scale < 0 or scale > 9:
        raise Error("quantity scale must be between 0 and 9")
    if qualifier != "exact" and qualifier != "approximate":
        raise Error("quantity qualifier must be 'exact' or 'approximate'")
    if unit.strip() == "" or dimension.strip() == "":
        raise Error("quantity requires unit and dimension")
    return Quantity(
        value=value,
        scale=scale,
        unit=String(unit),
        dimension=String(dimension),
        qualifier=String(qualifier),
    )


def quantity_rescale(quantity: Quantity, target_scale: Int) raises -> Quantity:
    if target_scale < quantity.scale:
        raise Error("quantity rescale must not reduce precision")
    var value = _checked_mul10(quantity.value, target_scale - quantity.scale)
    var result = quantity.copy()
    result.value = value
    result.scale = target_scale
    return result^


def _compatible(left: Quantity, right: Quantity) raises:
    if left.unit != right.unit:
        raise Error("quantity units differ: " + left.unit + " vs " + right.unit)
    if left.dimension != right.dimension:
        raise Error("quantity dimensions differ")


def quantity_add(left: Quantity, right: Quantity) raises -> Quantity:
    _compatible(left, right)
    var scale = left.scale if left.scale > right.scale else right.scale
    var scaled_left = quantity_rescale(left, scale)
    var scaled_right = quantity_rescale(right, scale)
    var qualifier = "exact"
    if left.qualifier == "approximate" or right.qualifier == "approximate":
        qualifier = "approximate"
    return new_quantity(
        _checked_add(scaled_left.value, scaled_right.value),
        scale,
        left.unit,
        left.dimension,
        qualifier,
    )


def quantity_compare(left: Quantity, right: Quantity) raises -> Int:
    _compatible(left, right)
    var scale = left.scale if left.scale > right.scale else right.scale
    var scaled_left = quantity_rescale(left, scale).value
    var scaled_right = quantity_rescale(right, scale).value
    if scaled_left < scaled_right:
        return -1
    if scaled_left > scaled_right:
        return 1
    return 0


def quantity_is_negative(quantity: Quantity) -> Bool:
    return quantity.value < 0
