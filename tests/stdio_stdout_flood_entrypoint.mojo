"""Test-only stdio entrypoint that floods stdout before reading stdin.

Exercises LC04: the parent must drain stdout concurrently with writing a large
request instead of deadlocking on a full stdout pipe. The flood is whitespace,
which JSON parsing tolerates, so a correctly interleaved run succeeds.
"""

from std.io.io import _fdopen
from std.sys import stdin


def main() raises:
    var spaces = String("")
    for _ in range(1000):
        spaces += " "
    for _ in range(100):
        print(spaces)
    with _fdopen["r"](stdin) as input_file:
        _ = input_file.readline()
    print('{"ok":true}')
