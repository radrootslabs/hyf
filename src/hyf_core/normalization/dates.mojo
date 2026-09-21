from hyf_core.domain.time import DateOnly


@fieldwise_init
struct ResolvedDate(Copyable, Movable):
    var resolution: String
    var date: DateOnly
    var ambiguity: String


def _days_from_civil(year: Int, month: Int, day: Int) -> Int:
    var y = year
    var m = month
    if m <= 2:
        y -= 1
    var era = y // 400
    if y < 0 and y % 400 != 0:
        era -= 1
    var yoe = y - era * 400
    var adjusted_month = m - 3 if m > 2 else m + 9
    var doy = (153 * adjusted_month + 2) // 5 + day - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _civil_from_days(z: Int) raises -> DateOnly:
    var adjusted = z + 719468
    var era = adjusted // 146097
    if adjusted < 0 and adjusted % 146097 != 0:
        era -= 1
    var doe = adjusted - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return DateOnly(year=y, month=m, day=d)


def weekday_index(date: DateOnly) -> Int:
    # 0 = Monday ... 6 = Sunday
    var days = _days_from_civil(date.year, date.month, date.day)
    return (((days + 3) % 7) + 7) % 7


def _weekday_number(name: String) raises -> Int:
    var lowered = name.lower()
    var names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    for index in range(len(names)):
        if lowered == names[index]:
            return index
    raise Error("unknown weekday: " + name)


def resolve_weekday(
    reference: DateOnly, weekday_name: String, direction: String
) raises -> ResolvedDate:
    var target = _weekday_number(weekday_name)
    var current = weekday_index(reference)
    var delta = (target - current + 7) % 7
    if direction == "next":
        if delta == 0:
            delta = 7
    elif direction != "on_or_after":
        raise Error("direction must be 'next' or 'on_or_after'")
    var base = _days_from_civil(reference.year, reference.month, reference.day)
    return ResolvedDate(
        resolution="resolved",
        date=_civil_from_days(base + delta),
        ambiguity="none",
    )


def resolve_relative_expression(
    expression: String, reference: DateOnly
) raises -> ResolvedDate:
    var lowered = expression.lower()
    var base = _days_from_civil(reference.year, reference.month, reference.day)
    if lowered == "today":
        return ResolvedDate(
            resolution="resolved", date=reference.copy(), ambiguity="none"
        )
    if lowered == "tomorrow":
        return ResolvedDate(
            resolution="resolved",
            date=_civil_from_days(base + 1),
            ambiguity="none",
        )
    return resolve_weekday(reference, lowered, "next")
