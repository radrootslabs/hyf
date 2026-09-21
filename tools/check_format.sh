#!/usr/bin/env sh
# Check-only Mojo formatting verification.
#
# The pinned toolchain has `mojo format` but no `--check` mode, and it rewrites
# files in place. This wrapper formats a temporary copy and diffs it against the
# originals, so the working tree is never modified. Exit non-zero if any target
# file is not already formatted.
#
# Usage: sh tools/check_format.sh [path ...]   (default: src tests)
set -eu

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status=0

check() {
  src="$1"
  dst="$tmp/$(printf '%s' "$src" | tr '/' '_')"
  cp -R "$src" "$dst"
  mojo format -q "$dst" >/dev/null 2>&1 || true
  if ! diff -r "$src" "$dst" >/dev/null 2>&1; then
    echo "unformatted: $src"
    status=1
  fi
}

if [ "$#" -eq 0 ]; then
  check src
  check tests
else
  for path in "$@"; do
    check "$path"
  done
fi

exit "$status"
