#!/usr/bin/env sh
# Lightweight repo-owned architecture boundary check for the Hyf capsule.
#
# Enforced rules:
#   1. Domain purity: files under src/hyf_core must not import the provider,
#      runtime or stdio layers, or network/OS I/O (flare, std.os, std.net).
#      (The current src/hyf_stdio -> hyf_provider coupling is a tracked
#      deviation resolved by step S065, not part of this rule.)
#   2. No source references a capsule-local .github/.act workflow path or the
#      out-of-tree secrets.txt file.
#
# Usage: sh tools/check_architecture.sh [root]   (default: .)
#        sh tools/check_architecture.sh --self-test
set -eu

check_root() {
  root="$1"
  violations=0

  if [ -d "$root/src/hyf_core" ]; then
    for file in $(find "$root/src/hyf_core" -name '*.mojo' 2>/dev/null); do
      if grep -nE '^[[:space:]]*(from|import)[[:space:]]+(hyf_provider|hyf_runtime|hyf_stdio)(\.|[[:space:]])' "$file" >/dev/null 2>&1 ||
         grep -nE '^[[:space:]]*(from|import)[[:space:]]+(flare|std\.os|std\.net)(\.|[[:space:]])' "$file" >/dev/null 2>&1; then
        echo "domain boundary violation: $file"
        violations=1
      fi
    done
  fi

  if [ -d "$root/src" ]; then
    for file in $(find "$root/src" -name '*.mojo' 2>/dev/null); do
      if grep -nE '\.github/|\.act/|secrets\.txt' "$file" >/dev/null 2>&1; then
        echo "prohibited workflow/secret path: $file"
        violations=1
      fi
    done
  fi

  return "$violations"
}

self_test() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # Clean tree must pass.
  mkdir -p "$tmp/clean/src/hyf_core"
  printf 'from std.collections import List\n' > "$tmp/clean/src/hyf_core/a.mojo"
  if ! check_root "$tmp/clean"; then
    echo "self-test failed: clean tree rejected"
    return 1
  fi
  # Domain-layer I/O import must fail.
  mkdir -p "$tmp/bad/src/hyf_core"
  printf 'from hyf_provider.client import get\n' > "$tmp/bad/src/hyf_core/b.mojo"
  if check_root "$tmp/bad"; then
    echo "self-test failed: provider import not detected"
    return 1
  fi
  rm -rf "$tmp/bad"
  mkdir -p "$tmp/bad2/src"
  printf 'const P = ".github/workflows/ci.yml"\n' > "$tmp/bad2/src/x.mojo"
  if check_root "$tmp/bad2"; then
    echo "self-test failed: prohibited path not detected"
    return 1
  fi
  echo "architecture self-test: ok"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  check_root "."
  echo "architecture check: ok"
  exit 0
fi

check_root "${1:-.}"
echo "architecture check: ok"
