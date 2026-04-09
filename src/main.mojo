from hyf_runtime.startup import resolve_startup_context_from_process
from hyf_stdio.server import run_stdio_server


def main() raises:
    var startup_context = resolve_startup_context_from_process()
    _ = startup_context.paths.config_path
    run_stdio_server()
