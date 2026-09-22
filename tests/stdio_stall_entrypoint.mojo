"""Test-only stdio entrypoint that stalls to exercise parent deadlines."""

from std.ffi import c_int, external_call


def main():
    for _ in range(200):
        _ = external_call["usleep", c_int](c_int(1_000_000))
