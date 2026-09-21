@fieldwise_init
struct JevFailure(Copyable, Movable):
    var family: String
    var retryable: Bool


def map_jev_failure(kind: String) raises -> JevFailure:
    var lowered = kind.lower()
    if lowered == "authentication":
        return JevFailure(family="provider_auth", retryable=False)
    if lowered == "validation":
        return JevFailure(family="provider_validation", retryable=False)
    if lowered == "bad_request":
        return JevFailure(family="provider_validation", retryable=False)
    if lowered == "not_found":
        return JevFailure(family="provider_validation", retryable=False)
    if lowered == "unprocessable_entity":
        return JevFailure(family="provider_validation", retryable=False)
    if lowered == "rate_limit":
        return JevFailure(family="provider_capacity", retryable=True)
    if lowered == "overloaded":
        return JevFailure(family="provider_capacity", retryable=True)
    if lowered == "internal_server":
        return JevFailure(family="provider_transport", retryable=True)
    if lowered == "request_timeout":
        return JevFailure(family="provider_transport", retryable=True)
    if lowered == "connection":
        return JevFailure(family="provider_transport", retryable=True)
    if lowered == "timeout":
        return JevFailure(family="provider_transport", retryable=True)
    if lowered == "response_validation":
        return JevFailure(family="provider_response_contract", retryable=False)
    if lowered == "transport":
        return JevFailure(family="provider_transport", retryable=False)
    raise Error("unknown provider failure kind: " + kind)
