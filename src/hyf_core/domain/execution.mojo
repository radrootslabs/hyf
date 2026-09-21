from std.collections import Optional


@fieldwise_init
struct ExecutionMeta(Copyable, Movable):
    var status: String
    var provider_calls: Int
    var model: Optional[String]
    var question_bundle: Optional[String]
    var degraded_reason: Optional[String]


def execution_meta(
    status: String,
    provider_calls: Int,
    model: Optional[String],
    question_bundle: Optional[String],
    degraded_reason: Optional[String],
) raises -> ExecutionMeta:
    if status != "complete" and status != "degraded" and status != "failed":
        raise Error("execution status must be complete, degraded or failed")
    if provider_calls < 0:
        raise Error("provider call count must be non-negative")
    if status == "degraded" and not degraded_reason:
        raise Error("degraded execution requires a reason")
    return ExecutionMeta(
        status=String(status),
        provider_calls=provider_calls,
        model=model.copy(),
        question_bundle=question_bundle.copy(),
        degraded_reason=degraded_reason.copy(),
    )


def execution_is_business_outcome() -> Bool:
    return False
