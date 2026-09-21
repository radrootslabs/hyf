@fieldwise_init
struct FarmInferenceOutcome(Copyable, Movable):
    var status: String
    var confirmed_claims: Int
    var unresolved_claims: Int
    var reason: String


def farm_inference_failure(reason: String) raises -> FarmInferenceOutcome:
    if String(reason).strip().byte_length() == 0:
        raise Error("inference failure requires a reason")
    return FarmInferenceOutcome(
        status="failed",
        confirmed_claims=0,
        unresolved_claims=1,
        reason=String(reason),
    )


def farm_inference_degraded(reason: String) raises -> FarmInferenceOutcome:
    if String(reason).strip().byte_length() == 0:
        raise Error("inference degradation requires a reason")
    return FarmInferenceOutcome(
        status="degraded",
        confirmed_claims=0,
        unresolved_claims=1,
        reason=String(reason),
    )


def inference_failure_confirms_stock() -> Bool:
    return False
