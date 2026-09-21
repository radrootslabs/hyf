

@fieldwise_init
struct ResourceEnvelope(Copyable, Movable):
    var max_candidates: Int
    var max_plans: Int
    var max_state_bytes: Int
    var max_questions: Int
    var max_provider_calls: Int


def default_resource_envelope() -> ResourceEnvelope:
    return ResourceEnvelope(
        max_candidates=64,
        max_plans=8,
        max_state_bytes=4096,
        max_questions=32,
        max_provider_calls=4,
    )


def within_envelope(
    envelope: ResourceEnvelope,
    candidates: Int,
    plans: Int,
    state_bytes: Int,
    questions: Int,
    provider_calls: Int,
) -> Bool:
    return (
        candidates <= envelope.max_candidates
        and plans <= envelope.max_plans
        and state_bytes <= envelope.max_state_bytes
        and questions <= envelope.max_questions
        and provider_calls <= envelope.max_provider_calls
    )
