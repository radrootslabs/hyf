

@fieldwise_init
struct RetryPolicy(Copyable, Movable):
    var max_retries: Int
    var base_delay_ms: Int
    var max_delay_ms: Int
    var budget_ms: Int


def retry_policy(
    max_retries: Int, base_delay_ms: Int, max_delay_ms: Int, budget_ms: Int
) raises -> RetryPolicy:
    if max_retries < 0:
        raise Error("max_retries must be non-negative")
    if base_delay_ms <= 0:
        raise Error("base_delay_ms must be positive")
    if max_delay_ms < base_delay_ms:
        raise Error("max_delay_ms must be at least base_delay_ms")
    if budget_ms <= 0:
        raise Error("budget_ms must be positive")
    return RetryPolicy(
        max_retries=max_retries,
        base_delay_ms=base_delay_ms,
        max_delay_ms=max_delay_ms,
        budget_ms=budget_ms,
    )


def retry_delay_ms(policy: RetryPolicy, attempt: Int) -> Int:
    var delay = policy.base_delay_ms
    for _ in range(attempt):
        delay *= 2
        if delay >= policy.max_delay_ms:
            return policy.max_delay_ms
    if delay > policy.max_delay_ms:
        return policy.max_delay_ms
    return delay


def should_retry(
    policy: RetryPolicy, attempt: Int, elapsed_ms: Int, retryable: Bool
) -> Bool:
    if not retryable:
        return False
    if attempt >= policy.max_retries:
        return False
    if elapsed_ms + retry_delay_ms(policy, attempt) >= policy.budget_ms:
        return False
    return True
