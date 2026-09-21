from std.collections import List


@fieldwise_init
struct PreferenceComponent(Copyable, Movable):
    var policy: String
    var score: Float64
    var weight: Float64


def preference_component(
    policy: String, score: Float64, weight: Float64
) raises -> PreferenceComponent:
    if String(policy).strip().byte_length() == 0:
        raise Error("preference component requires a policy")
    if score < 0.0 or score > 1.0:
        raise Error("preference score must be within [0, 1]")
    if weight < 0.0:
        raise Error("preference weight must be non-negative")
    return PreferenceComponent(policy=String(policy), score=score, weight=weight)


def compose_preference(components: List[PreferenceComponent]) -> Int:
    var weighted = 0.0
    var total_weight = 0.0
    for component in components:
        weighted += component.score * component.weight
        total_weight += component.weight
    if total_weight <= 0.0:
        return 0
    return Int((weighted / total_weight) * 100.0)


def preference_is_success_probability() -> Bool:
    return False


def rank_by_preference(
    plan_ids: List[String], scores: List[Int]
) raises -> List[String]:
    if len(plan_ids) != len(scores):
        raise Error("plan ids and scores must align")
    var pairs = List[PreferenceComponent]()
    _ = pairs
    var order = List[Int]()
    for index in range(len(plan_ids)):
        order.append(index)
    # insertion sort: deterministic desc by score, then asc by plan id
    var ranked = List[Int]()
    for index in order:
        var inserted = False
        var updated = List[Int]()
        for existing in ranked:
            if not inserted and (
                scores[index] > scores[existing]
                or (
                    scores[index] == scores[existing]
                    and plan_ids[index] < plan_ids[existing]
                )
            ):
                updated.append(index)
                inserted = True
            updated.append(existing)
        if not inserted:
            updated.append(index)
        ranked = updated^
    var result = List[String]()
    for index in ranked:
        result.append(String(plan_ids[index]))
    return result^


from hyf_core.domain.plan import MatchPlan


def rank_match_plans(
    plans: List[MatchPlan], scores: List[Int]
) raises -> List[MatchPlan]:
    if len(plans) != len(scores):
        raise Error("plans and scores must align")
    var ids = List[String]()
    for plan in plans:
        ids.append(String(plan.plan_id))
    var ranked_ids = rank_by_preference(ids, scores)
    var ranked = List[MatchPlan]()
    for plan_id in ranked_ids:
        for plan in plans:
            if plan.plan_id == plan_id:
                ranked.append(plan.copy())
    return ranked^


def ranking_is_order_independent() -> Bool:
    return True
