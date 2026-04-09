from std.ffi import c_int, external_call
from std.os import getenv, makedirs
from std.pathlib import Path

from hyf_runtime.paths import RuntimePaths
from hyf_runtime.startup import resolve_startup_context_from_process


comptime _HYF_DIAGNOSTICS_DIR_ENV = "HYF_DIAGNOSTICS_DIR"
comptime _HYF_DIAGNOSTICS_FILE_PREFIX = "hyf-internal-error-pid-"
comptime _HYF_DIAGNOSTICS_FILE_SUFFIX = ".log"
comptime _HYF_DIAGNOSTICS_DIR_MODE = 0o700
comptime _HYF_DIAGNOSTICS_FILE_MODE = 0o600


def hyf_diagnostics_dir_debug_override_env_name() -> String:
    return _HYF_DIAGNOSTICS_DIR_ENV


def _current_process_id() -> Int:
    return Int(external_call["getpid", c_int]())


def _ensure_directory_mode(path: Path):
    var path_str = path.__fspath__()
    _ = external_call["chmod", c_int](
        path_str.as_c_string_slice().unsafe_ptr(),
        c_int(_HYF_DIAGNOSTICS_DIR_MODE),
    )


def _ensure_file_mode(handle: Int):
    _ = external_call["fchmod", c_int](
        c_int(handle), c_int(_HYF_DIAGNOSTICS_FILE_MODE)
    )


def diagnostics_debug_override_dir_from_env() -> String:
    return getenv(_HYF_DIAGNOSTICS_DIR_ENV, "")


def diagnostics_dir_for_runtime_paths(paths: RuntimePaths) -> String:
    return String(paths.diagnostics_dir)


def effective_diagnostics_dir_for_runtime_paths(paths: RuntimePaths) -> String:
    var configured = diagnostics_debug_override_dir_from_env()
    if configured != "":
        return configured
    return diagnostics_dir_for_runtime_paths(paths)


def effective_diagnostics_dir_from_process_startup() raises -> String:
    var startup_context = resolve_startup_context_from_process()
    return effective_diagnostics_dir_for_runtime_paths(startup_context.paths)


def _diagnostic_log_path(diagnostics_dir: String) raises -> Path:
    var dir_path = Path(diagnostics_dir)
    makedirs(dir_path, mode=_HYF_DIAGNOSTICS_DIR_MODE, exist_ok=True)
    _ensure_directory_mode(dir_path)
    return dir_path / (
        _HYF_DIAGNOSTICS_FILE_PREFIX
        + String(_current_process_id())
        + _HYF_DIAGNOSTICS_FILE_SUFFIX
    )


def append_internal_diagnostic(line: String, diagnostics_dir: String):
    try:
        var log_path = _diagnostic_log_path(diagnostics_dir)
        with open(log_path, "a") as log_file:
            _ensure_file_mode(log_file.handle)
            log_file.write(line)
    except:
        pass
