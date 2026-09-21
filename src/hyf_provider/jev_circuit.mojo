@fieldwise_init
struct CircuitState(Copyable, Movable):
    var open: Bool
    var consecutive_failures: Int
    var threshold: Int


def circuit_state(threshold: Int) raises -> CircuitState:
    if threshold <= 0:
        raise Error("circuit threshold must be positive")
    return CircuitState(open=False, consecutive_failures=0, threshold=threshold)


def circuit_record_success(state: CircuitState) -> CircuitState:
    return CircuitState(
        open=False, consecutive_failures=0, threshold=state.threshold
    )


def circuit_record_failure(state: CircuitState) -> CircuitState:
    var failures = state.consecutive_failures + 1
    return CircuitState(
        open=failures >= state.threshold,
        consecutive_failures=failures,
        threshold=state.threshold,
    )


def circuit_allows(state: CircuitState) -> Bool:
    return not state.open


def process_liveness_is_provider_readiness() -> Bool:
    return False
