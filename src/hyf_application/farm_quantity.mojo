

@fieldwise_init
struct ProductQuantityAssociation(Copyable, Movable):
    var product_phrase: String
    var quantity_value: Int
    var quantity_scale: Int
    var unit: String
    var qualifier: String
    var unreserved_verified: Bool


def associate_quantity(
    product_phrase: String,
    quantity_value: Int,
    quantity_scale: Int,
    unit: String,
    qualifier: String,
) raises -> ProductQuantityAssociation:
    if String(product_phrase).strip().byte_length() == 0:
        raise Error("association requires a product phrase")
    if quantity_scale < 0 or quantity_scale > 9:
        raise Error("association scale must be between 0 and 9")
    if qualifier != "exact" and qualifier != "approximate":
        raise Error("association qualifier must be exact or approximate")
    return ProductQuantityAssociation(
        product_phrase=String(product_phrase),
        quantity_value=quantity_value,
        quantity_scale=quantity_scale,
        unit=String(unit),
        qualifier=String(qualifier),
        unreserved_verified=False,
    )


def reported_quantity_is_unreserved_stock() -> Bool:
    return False
