"""Test-only stdio entrypoint that floods stderr before reading stdin.

Exercises LC04: the parent must drain stderr concurrently with writing the
request instead of deadlocking on a full stderr pipe, and must bound the
diagnostics it retains with a distinct overflow cause.
"""

from std.sys import stderr


def main():
    var chunk = String("")
    for _ in range(1000):
        chunk += "e"
    for _ in range(100):
        print(chunk, file=stderr)
    print('{"ok":true}')
