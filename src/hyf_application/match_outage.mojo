

@fieldwise_init
struct RankingOutcome(Copyable, Movable):
    var feasibility: String
    var advisory: String
    var reason: String


def ranking_outage(feasibility: String, reason: String) raises -> RankingOutcome:
    if String(reason).strip().byte_length() == 0:
        raise Error("ranking outage requires a reason")
    return RankingOutcome(
        feasibility=String(feasibility), advisory="degraded", reason=String(reason)
    )


def outage_changes_feasibility() -> Bool:
    return False
