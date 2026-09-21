"""Non-swallowing temporary-directory context manager for tests.

The Mojo 1.0.0b1 `std.tempfile.TemporaryDirectory.__exit__` suppresses an
exception raised inside its `with` body, which silently masks failing
assertions. This wrapper delegates enter/exit to the standard implementation
but discards the suppression return value so body exceptions propagate
normally.

Use `SafeTempDir` anywhere a test currently uses `TemporaryDirectory` as a
`with` context manager. The interface is identical: `__enter__` returns the
temporary directory path as a `String`.
"""

from std.tempfile import TemporaryDirectory as _StdTemporaryDirectory


struct SafeTempDir:
    var _inner: _StdTemporaryDirectory

    def __init__(out self) raises:
        self._inner = _StdTemporaryDirectory()

    def __enter__(mut self) raises -> String:
        return self._inner.__enter__()

    def __exit__(mut self) raises:
        # Discard the inner return value deliberately: the standard
        # implementation returns a suppression flag that would otherwise swallow
        # an exception raised in the `with` body.
        self._inner.__exit__()
