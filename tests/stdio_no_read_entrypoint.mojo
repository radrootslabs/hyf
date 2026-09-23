"""Test-only stdio entrypoint that ignores stdin, emits valid JSON and exits 0.

Exercises PC03: the parent must reject a run whose intended request bytes were
never delivered even though the child's stdout is valid JSON and its exit code
is zero.
"""


def main():
    print('{"ok":true}')
