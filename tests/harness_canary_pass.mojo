from std.testing import TestSuite, assert_true

from safe_tempdir import SafeTempDir


def test_canary_passes() raises:
    with SafeTempDir() as temp_dir:
        assert_true(temp_dir.byte_length() > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
