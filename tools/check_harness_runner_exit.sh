#!/usr/bin/env sh
# Runner-exit control: prove that a failing test actually fails the Mojo test
# runner, and that infrastructure failures (compiler, loader, missing tool,
# pre-body crash) make THIS control fail instead of being mistaken for an
# expected failing test.
#
# For every canary: compile it first, then execute it, then require the exact
# expected test identity, failure/pass summary and zero skips. Any compile or
# loader error, any missing executable, or any output that does not name the
# expected executed test is an infrastructure failure.
#
# Usage: sh tools/check_harness_runner_exit.sh
#        sh tools/check_harness_runner_exit.sh --self-test
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# run_one <canary.mojo> <expected_test_name> <fail|pass>
run_one() {
  canary="$1"
  expected_name="$2"
  expect="$3"
  bin="$tmp/$(basename "$canary" .mojo).bin"

  if ! mojo build -I "$root/src" -I "$root/tests" "$canary" -o "$bin" \
      >"$tmp/build.log" 2>&1; then
    echo "INFRA: compile failed: $canary" >&2
    sed 's/^/  /' "$tmp/build.log" >&2
    return 1
  fi
  if [ ! -x "$bin" ]; then
    echo "INFRA: compile produced no executable: $canary" >&2
    return 1
  fi

  if output="$("$bin" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  case "$expect" in
    fail)
      if [ "$rc" -eq 0 ]; then
        echo "CONTROL: $canary did not fail the runner" >&2
        return 1
      fi
      if ! printf '%s' "$output" | grep -q "FAIL .*$expected_name"; then
        echo "CONTROL: $canary did not report executed test $expected_name" >&2
        printf '%s\n' "$output" >&2
        return 1
      fi
      if ! printf '%s' "$output" | grep -qE 'failed , 0 skipped'; then
        echo "CONTROL: $canary produced no failure summary with zero skips" >&2
        return 1
      fi
      ;;
    pass)
      if [ "$rc" -ne 0 ]; then
        echo "CONTROL: passing canary $canary exited $rc" >&2
        return 1
      fi
      if ! printf '%s' "$output" | grep -q '1 passed , 0 failed , 0 skipped'; then
        echo "CONTROL: passing canary produced no clean pass summary" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

self_test() {
  test_status=0

  # A formatter/runner binary that fails compilation must be detected as
  # infrastructure failure, never as an expected failing test.
  bindir="$tmp/bin"
  mkdir -p "$bindir"
  printf '#!/bin/sh\necho "error: synthetic compiler failure" >&2\nexit 1\n' \
    > "$bindir/mojo"
  chmod +x "$bindir/mojo"
  if PATH="$bindir:$PATH" run_one \
      "$root/tests/harness_canary_assert_fail.mojo" \
      test_canary_assertion_fails fail; then
    echo "self-test failed: synthetic compile failure accepted" >&2
    test_status=1
  fi

  # A loader/pre-body crash must also be rejected.
  crash="$tmp/prebody_crash.mojo"
  printf 'def main() raises:\n    raise Error("pre-body crash")\n' > "$crash"
  if run_one "$crash" test_none fail; then
    echo "self-test failed: pre-body crash accepted" >&2
    test_status=1
  fi

  # A missing toolchain must fail the control, not pass it.
  if PATH="/usr/bin:/bin" run_one \
      "$root/tests/harness_canary_assert_fail.mojo" \
      test_canary_assertion_fails fail; then
    echo "self-test failed: missing tool accepted" >&2
    test_status=1
  fi

  if [ "$test_status" -eq 0 ]; then
    echo "harness runner-exit self-test: ok"
  fi
  return "$test_status"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

status=0
run_one "$root/tests/harness_canary_assert_fail.mojo" \
  test_canary_assertion_fails fail || status=1
run_one "$root/tests/harness_canary_error_fail.mojo" \
  test_canary_generic_error_fails fail || status=1
run_one "$root/tests/harness_canary_pass.mojo" \
  test_canary_passes pass || status=1

if [ "$status" -eq 0 ]; then
  echo "harness runner-exit canaries: ok"
fi
exit "$status"
