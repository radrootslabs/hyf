

@fieldwise_init
struct Budget(Copyable, Movable):
    var start_monotonic_ns: Int
    var cap_ms: Int


def budget(deadline_ms: Int, server_cap_ms: Int) -> Budget:
    var cap = server_cap_ms
    if deadline_ms > 0 and deadline_ms < cap:
        cap = deadline_ms
    if cap <= 0:
        cap = server_cap_ms
    return Budget(start_monotonic_ns=0, cap_ms=cap)


def budget_from_clock(deadline_ms: Int, server_cap_ms: Int, now_ns: Int) -> Budget:
    var value = budget(deadline_ms, server_cap_ms)
    value.start_monotonic_ns = now_ns
    return value^


def budget_remaining_ms(value: Budget, now_ns: Int) -> Int:
    var elapsed_ms = (now_ns - value.start_monotonic_ns) // 1_000_000
    var remaining = value.cap_ms - elapsed_ms
    if remaining < 0:
        return 0
    return remaining


def budget_exhausted(value: Budget, now_ns: Int) -> Bool:
    return budget_remaining_ms(value, now_ns) == 0
