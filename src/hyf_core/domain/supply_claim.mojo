from hyf_core.domain.product import ProductRef


@fieldwise_init
struct SupplyClaim(Copyable, Movable):
    var claim_id: String
    var product: ProductRef
    var status: String
    var quantity_state: String
    var quantity_value: Int
    var quantity_scale: Int
    var unit: String
    var qualifier: String
    var review_required: Bool


def supply_claim(
    claim_id: String,
    product: ProductRef,
    status: String,
    quantity_state: String,
    quantity_value: Int,
    quantity_scale: Int,
    unit: String,
    qualifier: String,
) raises -> SupplyClaim:
    if claim_id.strip() == "":
        raise Error("claim id must not be empty")
    var allowed = [
        "offered",
        "forecast",
        "unavailable",
        "correction",
        "unclear",
    ]
    var known = False
    for candidate in allowed:
        if candidate == status:
            known = True
    if not known:
        raise Error("unknown supply status: " + status)
    if quantity_state != "known" and quantity_state != "unknown":
        raise Error("quantity state must be 'known' or 'unknown'")
    if quantity_scale < 0 or quantity_scale > 9:
        raise Error("quantity scale must be between 0 and 9")
    return SupplyClaim(
        claim_id=String(claim_id),
        product=product.copy(),
        status=String(status),
        quantity_state=String(quantity_state),
        quantity_value=quantity_value,
        quantity_scale=quantity_scale,
        unit=String(unit),
        qualifier=String(qualifier),
        review_required=True,
    )


def claim_confirms_inventory(claim: SupplyClaim) -> Bool:
    return False


def claim_is_forecast(claim: SupplyClaim) -> Bool:
    return claim.status == "forecast"
