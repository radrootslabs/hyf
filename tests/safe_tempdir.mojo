"""Non-swallowing temporary-directory context manager for tests.

On this toolchain, using the standard library's temporary-directory helper as a
`with` context manager suppresses an exception raised inside the body, silently
masking failing assertions. This wrapper delegates enter/exit to the standard
implementation but does not reproduce that suppression, so body exceptions
propagate normally.

This describes observed behavior only; the standard library's exact internal
mechanism is not asserted here. Use `SafeTempDir` anywhere a test currently
uses the standard helper as a `with` context manager. The interface is
identical: `__enter__` returns the temporary directory path as a `String`.
"""

from std.tempfile import TemporaryDirectory as _StdTemporaryDirectory


struct SafeTempDir:
    var _inner: _StdTemporaryDirectory

    def __init__(out self) raises:
        self._inner = _StdTemporaryDirectory()

    def __enter__(mut self) raises -> String:
        return self._inner.__enter__()

    def __exit__(mut self) raises:
        # Delegate cleanup. The observed standard behavior suppresses a body
        # exception at this point; this wrapper's non-suppressing exit lets the
        # body exception propagate instead.
        self._inner.__exit__()
