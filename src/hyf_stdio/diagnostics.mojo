from hyf_runtime.diagnostics import (
    append_internal_diagnostic as append_internal_diagnostic_to_dir,
    effective_diagnostics_dir_from_process_startup,
)


def append_internal_diagnostic(line: String):
    try:
        append_internal_diagnostic_to_dir(
            line, effective_diagnostics_dir_from_process_startup()
        )
    except:
        pass
