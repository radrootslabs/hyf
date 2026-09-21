#!/usr/bin/env sh
# Check-only Mojo formatting verification.
#
# The pinned toolchain has `mojo format` but no `--check` mode, and it rewrites
# files in place. This wrapper formats a temporary copy and diffs it against the
# originals, so the working tree is never modified.
#
# Exit non-zero if any target file is not already formatted. A formatter
# invocation failure (missing binary, crash, non-zero exit) is reported
# distinctly from a formatting diff; it is never swallowed.
#
# Usage: sh tools/check_format.sh [path ...]   (default: src tests)
#        sh tools/check_format.sh --self-test  (isolated negative controls)
set -eu

usage() {
  echo "usage: $0 [--self-test] [path ...]" >&2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status=0

check() {
  src="$1"
  dst="$tmp/$(printf '%s' "$src" | tr '/' '_')"
  cp -R "$src" "$dst"
  if ! mojo format -q "$dst" >"$tmp/format.err" 2>&1; then
    echo "formatter-error: $src"
    sed 's/^/  /' "$tmp/format.err" >&2
    status=1
    return
  fi
  if ! diff -r "$src" "$dst" >/dev/null 2>&1; then
    echo "unformatted: $src"
    status=1
  fi
}

self_test() {
  test_status=0
  bindir="$tmp/bin"
  mkdir -p "$bindir"

  # Negative control 1: a formatter that crashes must be reported as a
  # formatter error, not silently treated as a formatting diff.
  printf '#!/bin/sh\nexit 42\n' > "$bindir/mojo"
  chmod +x "$bindir/mojo"
  src="$tmp/crash_input"
  mkdir -p "$src"
  printf 'def main():\n    pass\n' > "$src/x.mojo"
  if out="$(PATH="$bindir:$PATH" sh "$0" "$src" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] || ! printf '%s' "$out" | grep -q 'formatter-error'; then
    echo "self-test failed: formatter crash was not reported" >&2
    test_status=1
  fi

  # Negative control 2: a known-unformatted input must fail the check.
  if command -v mojo >/dev/null 2>&1; then
    src2="$tmp/unformatted_input"
    mkdir -p "$src2"
    printf 'def main( ):   \n    pass\n' > "$src2/x.mojo"
    if sh "$0" "$src2" >/dev/null 2>&1; then
      echo "self-test failed: unformatted input was not detected" >&2
      test_status=1
    fi
  fi

  if [ "$test_status" -eq 0 ]; then
    echo "check_format self-test: ok"
  fi
  return "$test_status"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

for arg in "$@"; do
  if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
    usage
    exit 0
  fi
done

if [ "$#" -eq 0 ]; then
  check src
  check tests
else
  for path in "$@"; do
    check "$path"
  done
fi

if [ "$status" -eq 0 ]; then
  echo "check_format: ok"
fi
exit "$status"
