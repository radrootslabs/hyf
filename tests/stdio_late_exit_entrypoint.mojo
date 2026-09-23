"""Test-only stdio entrypoint that emits valid JSON, closes stdio and lingers.

Exercises PC03: a child that finishes its output and then delays exit past the
parent's declared budget must be rejected within that budget, with the bounded
cleanup grace used only for cleanup.
"""

from std.ffi import c_int, external_call
from std.sys._libc import close


def main():
    print('{"ok":true}')
    _ = close(c_int(1))
    _ = close(c_int(2))
    _ = external_call["usleep", c_int](c_int(1500000))
