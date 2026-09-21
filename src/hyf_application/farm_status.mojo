from std.collections import List


@fieldwise_init
struct ProductStatus(Copyable, Movable):
    var product_phrase: String
    var status: String
    var review_required: Bool


def interpret_product_statuses(
    products: List[String], evaluator_status: String
) raises -> List[ProductStatus]:
    var allowed = [
        "offered",
        "forecast",
        "unavailable",
        "correction",
        "unclear",
    ]
    var status = String(evaluator_status)
    var known = False
    for candidate in allowed:
        if candidate == status:
            known = True
    if not known:
        status = "unclear"
    var results = List[ProductStatus]()
    for product in products:
        results.append(
            ProductStatus(
                product_phrase=String(product),
                status=String(status),
                review_required=True,
            )
        )
    return results^


def status_is_confirmed_inventory(status: String) -> Bool:
    return False


def status_is_forecast(status: String) -> Bool:
    return status == "forecast"
