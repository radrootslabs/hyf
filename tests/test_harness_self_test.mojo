from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from safe_tempdir import SafeTempDir


def test_safe_tempdir_propagates_assertion_failure() raises:
    var entered_body = False
    var caught = False
    try:
        with SafeTempDir() as temp_dir:
            _ = temp_dir
            entered_body = True
            assert_true(False)
    except:
        caught = True
    assert_true(entered_body)
    assert_true(caught)


def test_safe_tempdir_propagates_generic_error_with_exact_identity() raises:
    var entered_body = False
    var caught = False
    var message = String("")
    try:
        with SafeTempDir() as temp_dir:
            _ = temp_dir
            entered_body = True
            raise Error("intentional generic harness error")
    except e:
        caught = True
        message = String(e)
    assert_true(entered_body)
    assert_true(caught)
    assert_equal(message, "intentional generic harness error")


def test_safe_tempdir_nested_contexts_are_distinct_and_cleaned() raises:
    var outer_path = String("")
    var inner_path = String("")
    with SafeTempDir() as outer:
        outer_path = outer
        with SafeTempDir() as inner:
            inner_path = inner
            assert_true(exists(inner_path))
        assert_true(exists(outer_path))
    assert_true(outer_path != inner_path)
    assert_true(not exists(outer_path))
    assert_true(not exists(inner_path))


def test_safe_tempdir_nested_error_propagates_and_cleans_up() raises:
    var outer_path = String("")
    var inner_path = String("")
    var caught = False
    try:
        with SafeTempDir() as outer:
            outer_path = outer
            with SafeTempDir() as inner:
                inner_path = inner
                raise Error("nested harness error")
    except e:
        caught = True
        assert_equal(String(e), "nested harness error")
    assert_true(caught)
    assert_true(not exists(outer_path))
    assert_true(not exists(inner_path))


def test_safe_tempdir_cleans_up_on_exception() raises:
    var path = String("")
    var entered_body = False
    var caught = False
    try:
        with SafeTempDir() as temp_dir:
            path = temp_dir
            entered_body = True
            raise Error("intentional cleanup harness error")
    except:
        caught = True
    assert_true(entered_body)
    assert_true(caught)
    assert_true(not exists(path))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
