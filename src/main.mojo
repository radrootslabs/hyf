from hyf_runtime.startup import resolve_startup_context_from_process
from hyf_stdio.server import run_stdio_server_with_runtime_context


def main() raises:
    var startup_context = resolve_startup_context_from_process()
    run_stdio_server_with_runtime_context(startup_context)
