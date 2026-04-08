from mojson import Value

from hyf_core.capabilities.explain_result import execute_explain_result
from hyf_core.capabilities.query_rewrite import execute_query_rewrite
from hyf_core.capabilities.semantic_rank import execute_semantic_rank
from hyf_core.errors import (
    CapabilityResult,
    capability_not_implemented_error,
    failed_capability,
)
from hyf_core.request_context import RequestContext


def backend_name() -> String:
    return "heuristic"


def execute_capability(
    capability_id: String, input: Value, context: RequestContext
) raises -> CapabilityResult:
    if capability_id == "query_rewrite":
        return execute_query_rewrite(input, context)
    if capability_id == "semantic_rank":
        return execute_semantic_rank(input, context)
    if capability_id == "explain_result":
        return execute_explain_result(input, context)

    return failed_capability(capability_not_implemented_error(capability_id))
