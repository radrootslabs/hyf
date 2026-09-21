from std.collections import Optional


@fieldwise_init
struct DecodedField(Copyable, Movable):
    var state: String
    var value: Optional[String]
    var qualifier: String
    var method: String


def known_field(value: String, method: String) raises -> DecodedField:
    if method.strip() == "":
        raise Error("field method must not be empty")
    return DecodedField(
        state="known",
        value=Optional[String](String(value)),
        qualifier="exact",
        method=String(method),
    )


def known_approximate_field(value: String, method: String) raises -> DecodedField:
    var field = known_field(value, method)
    field.qualifier = "approximate"
    return field^


def unresolved_field(method: String) raises -> DecodedField:
    if method.strip() == "":
        raise Error("field method must not be empty")
    return DecodedField(
        state="unresolved",
        value=None,
        qualifier="unknown",
        method=String(method),
    )


def field_is_known(field: DecodedField) -> Bool:
    if field.state != "known":
        return False
    if not field.value:
        return False
    return True


def field_known_or(field: DecodedField, fallback: String) -> String:
    if field_is_known(field):
        return field.value.value()
    return String(fallback)


def validate_field_consistency(field: DecodedField) raises:
    if field.state == "known" and not field.value:
        raise Error("known field must carry a value")
    if field.state == "unresolved" and field.value:
        raise Error("unresolved field must not carry a value")
    if field.state != "known" and field.state != "unresolved":
        raise Error("field state must be 'known' or 'unresolved'")
