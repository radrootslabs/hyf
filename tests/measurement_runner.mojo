"""Standalone governed H005A measurement entry point (ADR-0012 D29).

Runs one persistent HYF stdio process through warmup and measured frames and
prints the exact identity, per-phase timing, numeric RSS/FD samples, frame
counts and child exit. Exits nonzero on any failed mandatory guarantee.

Usage (governed lane): ``cargo extbuild run -- pixi run --frozen measure-h005a``
"""

from std.collections import List

from safe_tempdir import SafeTempDir

from parent_lifecycle import CleanupGuard
from stdio_process_helper import (
    HYF_PATHS_PROFILE_ENV,
    HYF_PATHS_REPO_LOCAL_ROOT_ENV,
    ScopedEnvVar,
)
from measurement_process_helper import (
    build_product_binary,
    measure_persistent_process,
)


comptime MEASUREMENT_DEADLINE_MS = 180000
comptime WARMUP_FRAMES = 100
comptime MEASURED_FRAMES = 1000


def main() raises:
    var guard = CleanupGuard()
    with SafeTempDir() as temp_dir:
        with ScopedEnvVar(HYF_PATHS_PROFILE_ENV, "repo_local"):
            with ScopedEnvVar(HYF_PATHS_REPO_LOCAL_ROOT_ENV, temp_dir):
                var binary = build_product_binary(temp_dir, guard)
                var argv = List[String]()
                var measured = measure_persistent_process(
                    ".",
                    binary,
                    "argv=[<hyfd>]",
                    "env=verified at run time",
                    argv^,
                    WARMUP_FRAMES,
                    MEASURED_FRAMES,
                    MEASUREMENT_DEADLINE_MS,
                    guard,
                )
                print("h005a.identity", measured.identity.describe())
                print("h005a.measurement", measured.summary())
                print("h005a.sampling_method", measured.sampling_method)
                print(
                    "h005a.stderr_bytes",
                    measured.stderr_excerpt.byte_length(),
                )
    guard.assert_clean()
    print("h005a_measurement: ok")
