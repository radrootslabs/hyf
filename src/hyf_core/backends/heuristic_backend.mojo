from mojson import Value

from hyf_core.capabilities.registry import (
    execute_registered_business_capability,
)
from hyf_core.errors import CapabilityResult
from hyf_core.request_context import RequestContext


def backend_name() -> String:
    return "heuristic"


def execute_capability(
    capability_id: String, input: Value, context: RequestContext
) raises -> CapabilityResult:
    return execute_registered_business_capability(capability_id, input, context)
