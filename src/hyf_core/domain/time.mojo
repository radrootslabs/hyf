from std.collections import Optional


@fieldwise_init
struct DateOnly(Copyable, Movable):
    var year: Int
    var month: Int
    var day: Int


@fieldwise_init
struct Timestamp(Copyable, Movable):
    var epoch_seconds: Int
    var timezone: Optional[String]


@fieldwise_init
struct TimeContext(Copyable, Movable):
    var source_time: Timestamp
    var ingestion_time: Timestamp
    var evaluation_time: Timestamp


def date_only(year: Int, month: Int, day: Int) raises -> DateOnly:
    if month < 1 or month > 12:
        raise Error("date month must be between 1 and 12")
    if day < 1 or day > 31:
        raise Error("date day must be between 1 and 31")
    return DateOnly(year=year, month=month, day=day)


def timestamp(epoch_seconds: Int, timezone: String) raises -> Timestamp:
    if timezone.strip() == "":
        raise Error("timestamp timezone must not be empty")
    return Timestamp(
        epoch_seconds=epoch_seconds,
        timezone=Optional[String](String(timezone)),
    )


def zoneless_timestamp(epoch_seconds: Int) -> Timestamp:
    return Timestamp(epoch_seconds=epoch_seconds, timezone=None)


def timestamp_has_zone(value: Timestamp) -> Bool:
    return value.timezone is not None


def time_context(
    source: Timestamp, ingestion: Timestamp, evaluation: Timestamp
) raises -> TimeContext:
    if not timestamp_has_zone(source):
        raise Error("source time requires a known timezone")
    return TimeContext(
        source_time=source.copy(),
        ingestion_time=ingestion.copy(),
        evaluation_time=evaluation.copy(),
    )
