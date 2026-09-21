from std.collections import Optional


@fieldwise_init
struct Price(Copyable, Movable):
    var state: String
    var amount: Int
    var scale: Int
    var currency: String
    var basis: String


def known_price(
    amount: Int, scale: Int, currency: String, basis: String
) raises -> Price:
    if scale < 0 or scale > 9:
        raise Error("price scale must be between 0 and 9")
    if currency.strip() == "":
        raise Error("known price requires a currency")
    if (
        basis != "per_unit"
        and basis != "per_pack"
        and basis != "per_order"
    ):
        raise Error("price basis must be per_unit, per_pack or per_order")
    if amount < 0:
        raise Error("price amount must be non-negative")
    return Price(
        state="known",
        amount=amount,
        scale=scale,
        currency=String(currency),
        basis=String(basis),
    )


def unknown_price() -> Price:
    return Price(
        state="unknown", amount=0, scale=0, currency="", basis="unknown"
    )


def price_is_known(price: Price) -> Bool:
    return price.state == "known"


def price_compare(left: Price, right: Price) raises -> Int:
    if not price_is_known(left) or not price_is_known(right):
        raise Error("cannot compare unknown prices")
    if left.currency != right.currency:
        raise Error(
            "cannot compare prices in different currencies without conversion"
        )
    if left.basis != right.basis:
        raise Error("cannot compare prices with different bases")
    var scale = left.scale if left.scale > right.scale else right.scale
    var left_value = left.amount
    var right_value = right.amount
    for _ in range(scale - left.scale):
        left_value *= 10
    for _ in range(scale - right.scale):
        right_value *= 10
    if left_value < right_value:
        return -1
    if left_value > right_value:
        return 1
    return 0
