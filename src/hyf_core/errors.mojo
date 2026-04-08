from std.collections import Optional

from mojson import Value

from hyf_core.provenance import CoreResponseMeta


@fieldwise_init
struct CoreError(Copyable, Movable):
    var code: String
    var message: String
    var retryable: Bool


@fieldwise_init
struct CapabilitySuccess(Copyable, Movable):
    var output: Value
    var meta: Optional[CoreResponseMeta]


@fieldwise_init
struct CapabilityFailure(Copyable, Movable):
    var error: CoreError


def invalid_context_error(message: String) -> CoreError:
    return CoreError(code="invalid_context", message=message, retryable=False)


def capability_not_implemented_error(capability: String) -> CoreError:
    return CoreError(
        code="capability_not_implemented",
        message="core capability '" + capability + "' is not implemented yet",
        retryable=False,
    )


def backend_unavailable_error(backend: String) -> CoreError:
    return CoreError(
        code="backend_unavailable",
        message="backend '" + backend + "' is unavailable",
        retryable=True,
    )
