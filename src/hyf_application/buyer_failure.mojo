

@fieldwise_init
struct BuyerInferenceOutcome(Copyable, Movable):
    var status: String
    var resolved_lines: Int
    var unresolved_lines: Int
    var reason: String


def buyer_inference_failure(reason: String) raises -> BuyerInferenceOutcome:
    if String(reason).strip().byte_length() == 0:
        raise Error("buyer inference failure requires a reason")
    return BuyerInferenceOutcome(
        status="failed", resolved_lines=0, unresolved_lines=1, reason=String(reason)
    )


def buyer_inference_degraded(reason: String) raises -> BuyerInferenceOutcome:
    if String(reason).strip().byte_length() == 0:
        raise Error("buyer inference degradation requires a reason")
    return BuyerInferenceOutcome(
        status="degraded", resolved_lines=0, unresolved_lines=1, reason=String(reason)
    )


def buyer_failure_means_unavailable_supply() -> Bool:
    return False
