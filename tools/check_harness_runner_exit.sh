#!/usr/bin/env sh
# Negative controls for test-harness exception propagation.
#
# A failing assertion or a raised error inside SafeTempDir must make the Mojo
# test runner exit nonzero. A passing canary must exit zero. This proves the
# SafeTempDir wrapper does not reintroduce the TemporaryDirectory masking
# behavior.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"

run_canary() {
  if mojo -I "$root/src" -I "$root/tests" "$1" >/dev/null 2>&1; then
    printf '0'
  else
    printf '1'
  fi
}

assert_fail="$(run_canary "$root/tests/harness_canary_assert_fail.mojo")"
error_fail="$(run_canary "$root/tests/harness_canary_error_fail.mojo")"
pass_ok="$(run_canary "$root/tests/harness_canary_pass.mojo")"

status=0
if [ "$assert_fail" -eq 0 ]; then
  echo "harness canary: failing assertion did not fail the runner" >&2
  status=1
fi
if [ "$error_fail" -eq 0 ]; then
  echo "harness canary: raised error did not fail the runner" >&2
  status=1
fi
if [ "$pass_ok" -ne 0 ]; then
  echo "harness canary: passing canary unexpectedly failed" >&2
  status=1
fi
if [ "$status" -eq 0 ]; then
  echo "harness runner-exit canaries: ok"
fi
exit "$status"
