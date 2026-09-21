from hyf_core.domain.time import DateOnly
from hyf_core.normalization.dates import resolve_relative_expression


@fieldwise_init
struct FulfillmentClaim(Copyable, Movable):
    var method: String
    var window_expression: String
    var resolved_date: String
    var ambiguity: String
    var area_verified: Bool


def _is_blank(value: String) -> Bool:
    return String(value).strip().byte_length() == 0


def interpret_fulfillment(
    method: String,
    window_expression: String,
    reference_date: DateOnly,
    timezone: String,
) raises -> FulfillmentClaim:
    if _is_blank(method):
        raise Error("fulfillment requires a method")
    if _is_blank(window_expression):
        return FulfillmentClaim(
            method=String(method), window_expression="", resolved_date="",
            ambiguity="none", area_verified=False,
        )
    if _is_blank(timezone):
        return FulfillmentClaim(
            method=String(method), window_expression=String(window_expression),
            resolved_date="", ambiguity="missing_zone", area_verified=False,
        )
    var resolved = resolve_relative_expression(window_expression, reference_date)
    if resolved.resolution != "resolved":
        return FulfillmentClaim(
            method=String(method), window_expression=String(window_expression),
            resolved_date="", ambiguity=String(resolved.ambiguity),
            area_verified=False,
        )
    var date = (
        String(resolved.date.year)
        + "-"
        + String(resolved.date.month)
        + "-"
        + String(resolved.date.day)
    )
    return FulfillmentClaim(
        method=String(method), window_expression=String(window_expression),
        resolved_date=date, ambiguity="none", area_verified=False,
    )
