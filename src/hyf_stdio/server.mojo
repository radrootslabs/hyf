from hyf_core.backends.null_backend import backend_name
from hyf_core.capabilities.registry import bootstrap_capability_count
from hyf_core.errors import core_error_module_name
from hyf_core.provenance import provenance_module_name
from hyf_core.request_context import request_context_module_name
from hyf_stdio.envelope import envelope_module_name
from hyf_stdio.errors import stdio_error_module_name


def run_stdio_server() raises:
    _ = backend_name()
    _ = bootstrap_capability_count()
    _ = core_error_module_name()
    _ = provenance_module_name()
    _ = request_context_module_name()
    _ = envelope_module_name()
    _ = stdio_error_module_name()

