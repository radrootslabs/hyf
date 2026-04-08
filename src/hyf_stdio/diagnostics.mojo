from std.ffi import c_int, external_call
from std.os import getenv, makedirs
from std.pathlib import Path
from std.tempfile import gettempdir


comptime _HYF_DIAGNOSTICS_DIR_ENV = "HYF_DIAGNOSTICS_DIR"
comptime _HYF_DIAGNOSTICS_DIR_NAME = "hyf-diagnostics"
comptime _HYF_DIAGNOSTICS_FILE_PREFIX = "hyf-internal-error-pid-"
comptime _HYF_DIAGNOSTICS_FILE_SUFFIX = ".log"
comptime _HYF_DIAGNOSTICS_DIR_MODE = 0o700
comptime _HYF_DIAGNOSTICS_FILE_MODE = 0o600


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


def _default_diagnostics_dir() raises -> Path:
    var tmpdir = gettempdir()
    if tmpdir:
        return Path(tmpdir.value()) / _HYF_DIAGNOSTICS_DIR_NAME
    return Path("/tmp") / _HYF_DIAGNOSTICS_DIR_NAME


def _diagnostics_dir() raises -> Path:
    var configured = getenv(_HYF_DIAGNOSTICS_DIR_ENV, "")
    if configured != "":
        return Path(configured)
    return _default_diagnostics_dir()


def _diagnostic_log_path() raises -> Path:
    var diagnostics_dir = _diagnostics_dir()
    makedirs(diagnostics_dir, mode=_HYF_DIAGNOSTICS_DIR_MODE, exist_ok=True)
    _ensure_directory_mode(diagnostics_dir)
    return diagnostics_dir / (
        _HYF_DIAGNOSTICS_FILE_PREFIX
        + String(_current_process_id())
        + _HYF_DIAGNOSTICS_FILE_SUFFIX
    )


def append_internal_diagnostic(line: String):
    try:
        var log_path = _diagnostic_log_path()
        with open(log_path, "a") as log_file:
            _ensure_file_mode(log_file.handle)
            log_file.write(line)
    except:
        pass
