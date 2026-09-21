

@fieldwise_init
struct Freshness(Copyable, Movable):
    var record_age_minutes: Int
    var harvest_age_minutes: Int
    var verification_age_minutes: Int


def freshness(
    record_age_minutes: Int,
    harvest_age_minutes: Int,
    verification_age_minutes: Int,
) raises -> Freshness:
    if record_age_minutes < 0:
        raise Error("record age must be non-negative")
    if harvest_age_minutes < 0:
        raise Error("harvest age must be non-negative")
    if verification_age_minutes < 0:
        raise Error("verification age must be non-negative")
    return Freshness(
        record_age_minutes=record_age_minutes,
        harvest_age_minutes=harvest_age_minutes,
        verification_age_minutes=verification_age_minutes,
    )


def record_recency_implies_harvest_age() -> Bool:
    return False
