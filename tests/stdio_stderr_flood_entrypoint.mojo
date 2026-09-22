"""Test-only stdio entrypoint that floods stdout and stderr interleaved.

Exercises LC04: the parent must drain stdout and stderr concurrently with
writing the request instead of deadlocking on a full pipe, and must bound the
diagnostics it retains with a distinct overflow cause.
"""

from std.sys import stderr


def main():
    var out_chunk = String("")
    for _ in range(1000):
        out_chunk += "o"
    var err_chunk = String("")
    for _ in range(1000):
        err_chunk += "e"
    for _ in range(100):
        print(out_chunk)
        print(err_chunk, file=stderr)
    print('{"ok":true}')
