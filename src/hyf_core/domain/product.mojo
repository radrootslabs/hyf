from std.collections import Optional


@fieldwise_init
struct ProductRef(Copyable, Movable):
    var phrase: String
    var catalogue_id: Optional[String]
    var resolution: String


def resolved_product(phrase: String, catalogue_id: String) raises -> ProductRef:
    if phrase.strip() == "":
        raise Error("product phrase must not be empty")
    if catalogue_id.strip() == "":
        raise Error("resolved product requires a catalogue id")
    return ProductRef(
        phrase=String(phrase),
        catalogue_id=Optional[String](String(catalogue_id)),
        resolution="resolved",
    )


def unresolved_product(phrase: String) raises -> ProductRef:
    if phrase.strip() == "":
        raise Error("product phrase must not be empty")
    return ProductRef(
        phrase=String(phrase), catalogue_id=None, resolution="unresolved"
    )


def product_is_resolved(product: ProductRef) -> Bool:
    return product.resolution == "resolved" and product.catalogue_id is not None


def product_matches(left: ProductRef, right: ProductRef) -> Bool:
    if not product_is_resolved(left) or not product_is_resolved(right):
        return False
    return left.catalogue_id.value() == right.catalogue_id.value()
