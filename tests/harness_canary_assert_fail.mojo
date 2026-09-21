from std.testing import TestSuite, assert_true

from safe_tempdir import SafeTempDir


def test_canary_assertion_fails() raises:
    with SafeTempDir() as temp_dir:
        _ = temp_dir
        assert_true(False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
