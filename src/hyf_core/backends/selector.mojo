from mojson import Value

from hyf_core.backends.heuristic_backend import (
    backend_name as heuristic_backend_name,
    execute_capability as execute_heuristic_capability,
)
from hyf_core.errors import (
    CapabilityResult,
    backend_unavailable_error,
    failed_capability,
)
from hyf_core.request_context import (
    RequestContext,
    assisted_execution_requested,
)


@fieldwise_init
struct BackendSelection(Copyable, Movable):
    var backend_name: String
    var available: Bool


def resolve_backend(context: RequestContext) -> BackendSelection:
    if assisted_execution_requested(context):
        return BackendSelection(
            backend_name="assisted_execution", available=False
        )

    return BackendSelection(
        backend_name=heuristic_backend_name(), available=True
    )


def execute_capability(
    capability_id: String, input: Value, context: RequestContext
) raises -> CapabilityResult:
    var selection = resolve_backend(context)
    if not selection.available:
        return failed_capability(
            backend_unavailable_error(selection.backend_name)
        )

    if selection.backend_name == heuristic_backend_name():
        return execute_heuristic_capability(capability_id, input, context)

    return failed_capability(backend_unavailable_error(selection.backend_name))
