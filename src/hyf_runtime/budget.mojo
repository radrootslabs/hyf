"""Shared absolute request budget and frozen timeout/retry/circuit constants
(ADR-0010 D21; policy table
``docs/spec/hyf_http_v1/policy/hyf_http_v1_policy.v1.toml``).

:class:`Budget` is one monotonic absolute cap with no per-stage reset. The
named constants freeze the Codex-selected local bounds so the dependent slices
(H092 timeout derivation, C006/C007 transport, C043 circuit) consume exact
values instead of restating them; they are not production SLOs.
"""

comptime CONNECT_READ_CAP_MS: Int = 1000
comptime OUTPUT_BLOCK_CAP_MS: Int = 1000
comptime MAX_WIRE_ATTEMPTS: Int = 4
comptime MAX_RETRIES_PER_CALL: Int = 1
comptime RETRY_BACKOFF_MS: Int = 100
comptime CIRCUIT_OPEN_THRESHOLD: Int = 3
comptime CIRCUIT_COOLDOWN_MS: Int = 30000
comptime CIRCUIT_HALF_OPEN_PROBES: Int = 1


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


def budget_from_clock(
    deadline_ms: Int, server_cap_ms: Int, now_ns: Int
) -> Budget:
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


def request_budget_cap_ms(
    request_deadline_ms: Int, configured_request_timeout_ms: Int
) raises -> Int:
    """ADR-0010 D21 absolute request-budget derivation.

    The assisted-work cap is ``min(positive request deadline_ms, configured
    provider request_timeout_ms)``. A non-positive configured timeout is an
    invalid configuration and is rejected; a non-positive request deadline
    means the caller supplied none, so the configured cap governs. The result
    is always positive and neither input can enlarge the other.
    """
    if configured_request_timeout_ms <= 0:
        raise Error("configured provider request_timeout_ms must be positive")
    if request_deadline_ms <= 0:
        return configured_request_timeout_ms
    if request_deadline_ms < configured_request_timeout_ms:
        return request_deadline_ms
    return configured_request_timeout_ms


def derived_stage_cap_ms(stage_cap_ms: Int, remaining_budget_ms: Int) -> Int:
    """``min(stage cap, remaining overall budget)``, never negative.

    D21 connect/read and output caps are derived from the positive remaining
    absolute budget; this helper never replaces or extends the total deadline.
    A non-positive stage cap has no admissible budget and collapses to zero.
    """
    if stage_cap_ms <= 0 or remaining_budget_ms <= 0:
        return 0
    if remaining_budget_ms < stage_cap_ms:
        return remaining_budget_ms
    return stage_cap_ms


def derived_connect_read_cap_ms(remaining_budget_ms: Int) -> Int:
    return derived_stage_cap_ms(CONNECT_READ_CAP_MS, remaining_budget_ms)


def derived_output_block_cap_ms(remaining_budget_ms: Int) -> Int:
    return derived_stage_cap_ms(OUTPUT_BLOCK_CAP_MS, remaining_budget_ms)


def budget_stage_cap_ms(value: Budget, now_ns: Int, stage_cap_ms: Int) -> Int:
    """Absolute-deadline-aware stage cap: ``min(stage cap, remaining budget)``.
    """
    return derived_stage_cap_ms(
        stage_cap_ms, budget_remaining_ms(value, now_ns)
    )


def request_budget_from_config(
    request_deadline_ms: Int,
    configured_request_timeout_ms: Int,
    now_ns: Int,
) raises -> Budget:
    """One monotonic absolute budget from an explicit D21 derivation."""
    var cap_ms = request_budget_cap_ms(
        request_deadline_ms, configured_request_timeout_ms
    )
    return budget_from_clock(cap_ms, cap_ms, now_ns)
