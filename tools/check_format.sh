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

  # A missing/broken formatter must fail the self-test, never make it pass.
  if ! command -v mojo >/dev/null 2>&1; then
    echo "self-test failed: no Mojo formatter available" >&2
    return 1
  fi

  # Positive control: an already-formatted input must pass the check.
  positive="$tmp/positive"
  mkdir -p "$positive"
  printf 'def main():\n    pass\n' > "$positive/x.mojo"
  if ! mojo format -q "$positive" >/dev/null 2>&1; then
    echo "self-test failed: cannot produce a formatted positive case" >&2
    return 1
  fi
  if ! sh "$0" "$positive" >/dev/null 2>&1; then
    echo "self-test failed: formatted input did not pass" >&2
    test_status=1
  fi

  # Unformatted control: must be classified as `unformatted`.
  unformatted="$tmp/unformatted"
  mkdir -p "$unformatted"
  printf 'def main( ):   \n    pass\n' > "$unformatted/x.mojo"
  if output="$(sh "$0" "$unformatted" 2>&1)"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ] || ! printf '%s' "$output" | grep -q 'unformatted:'; then
    echo "self-test failed: unformatted input not classified" >&2
    test_status=1
  fi

  # Crashing formatter control: must be classified as `formatter-error`.
  bindir="$tmp/bin-crash"
  mkdir -p "$bindir"
  printf '#!/bin/sh\nexit 42\n' > "$bindir/mojo"
  chmod +x "$bindir/mojo"
  if output="$(PATH="$bindir:$PATH" sh "$0" "$unformatted" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] || ! printf '%s' "$output" | grep -q 'formatter-error:'; then
    echo "self-test failed: crashing formatter not classified" >&2
    test_status=1
  fi

  # Missing formatter control: must be classified as `formatter-error`.
  if output="$(PATH="/usr/bin:/bin" sh "$0" "$positive" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] || ! printf '%s' "$output" | grep -q 'formatter-error:'; then
    echo "self-test failed: missing formatter not classified" >&2
    test_status=1
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
