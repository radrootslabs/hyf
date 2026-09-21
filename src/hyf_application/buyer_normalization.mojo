from hyf_core.domain.price import Price, known_price, unknown_price
from hyf_core.domain.quantity import Quantity, new_quantity
from hyf_core.domain.units import unit_dimension


def normalize_buyer_quantity(
    value: Int, scale: Int, unit: String, qualifier: String
) raises -> Quantity:
    return new_quantity(value, scale, unit, unit_dimension(unit), qualifier)


def normalize_buyer_price(
    amount: Int, scale: Int, currency: String, basis: String
) raises -> Price:
    if String(currency).strip().byte_length() == 0:
        return unknown_price()
    return known_price(amount, scale, currency, basis)


def unknown_price_is_free() -> Bool:
    return False


def unsupported_conversion_is_zero() -> Bool:
    return False
