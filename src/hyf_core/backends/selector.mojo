from mojson import Value

from hyf_core.backends.heuristic_backend import (
    backend_name as heuristic_backend_name,
    execute_capability as execute_heuristic_capability,
)
from hyf_core.capabilities.registry import (
    execute_registered_business_capability_with_runtime_config,
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
from hyf_runtime.config import HyfLoadedRuntimeConfig


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


def execute_capability_with_runtime_config(
    capability_id: String,
    input: Value,
    context: RequestContext,
    runtime_config: HyfLoadedRuntimeConfig,
) raises -> CapabilityResult:
    if assisted_execution_requested(context) and capability_id != "query_rewrite":
        return failed_capability(backend_unavailable_error("assisted_execution"))

    return execute_registered_business_capability_with_runtime_config(
        capability_id, input, context, runtime_config
    )
