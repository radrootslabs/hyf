from std.testing import TestSuite

from safe_tempdir import SafeTempDir


def test_canary_generic_error_fails() raises:
    with SafeTempDir() as temp_dir:
        _ = temp_dir
        raise Error("intentional harness canary error")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
