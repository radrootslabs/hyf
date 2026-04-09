from std.testing import assert_equal, assert_true

from mojson import Value, dumps, loads

from fixture_loader import load_fixture_scenario_field


def load_scenario_request(relative_path: String) raises -> Value:
    return load_fixture_scenario_field(relative_path, "request")


def load_scenario_request_json(relative_path: String) raises -> String:
    return _compact_json(load_scenario_request(relative_path))


def status_request_with_invalid_version_json() raises -> String:
    var request = load_scenario_request("scenarios/status_ok.json")
    request.set("version", Value(2))
    return _compact_json(request)


def assert_matches_scenario_response(
    actual: Value, relative_path: String
) raises:
    var expected = load_fixture_scenario_field(relative_path, "expected")

    if _has_key(expected, "ok"):
        _assert_json_equal(actual["ok"], expected["ok"])

    if _has_key(expected, "equals"):
        var equals = expected["equals"]
        for path in equals.object_keys():
            _assert_json_equal(
                _require_path(actual, path, "equals"), equals[path]
            )

    if _has_key(expected, "contains_all"):
        var contains_all = expected["contains_all"]
        for path in contains_all.object_keys():
            _assert_contains_all(
                _require_path(actual, path, "contains_all"),
                contains_all[path],
            )

    if _has_key(expected, "present_paths"):
        for path in expected["present_paths"].array_items():
            assert_true(
                _path_exists(actual, path.string_value()),
                "expected present path '" + path.string_value() + "'",
            )

    if _has_key(expected, "absent_paths"):
        for path in expected["absent_paths"].array_items():
            assert_true(
                not _path_exists(actual, path.string_value()),
                "expected absent path '" + path.string_value() + "'",
            )

    if _has_key(expected, "error_code"):
        _assert_json_equal(actual["error"]["code"], expected["error_code"])

    if _has_key(expected, "message_contains"):
        assert_true(
            actual["error"]["message"].string_value().find(
                expected["message_contains"].string_value()
            )
            >= 0
        )


def _lookup_path(value: Value, dotted_path: String) raises -> Value:
    var current = value.copy()
    for token in dotted_path.split("."):
        var token_string = String(token)
        if current.is_array():
            var items = current.array_items()
            current = items[Int(token_string)].copy()
        else:
            current = loads(current.get(token_string))
    return current^


def _require_path(
    value: Value, dotted_path: String, section: String
) raises -> Value:
    try:
        return _lookup_path(value, dotted_path)
    except:
        raise Error(
            "missing "
            + section
            + " path '"
            + dotted_path
            + "' in actual response"
        )


def _path_exists(value: Value, dotted_path: String) -> Bool:
    try:
        _ = _lookup_path(value, dotted_path)
        return True
    except:
        return False


def _compact_json(value: Value) raises -> String:
    if value.is_null() or value.is_bool() or value.is_int() or value.is_float():
        return dumps(value)

    if value.is_string():
        return dumps(Value(value.string_value()))

    if value.is_array() or value.is_object():
        return _minify_json(value.raw_json())

    return dumps(value)


def _minify_json(raw: String) -> String:
    var result = String("")
    var in_string = False
    var escaped = False

    for byte in raw.as_bytes():
        if escaped:
            result += chr(Int(byte))
            escaped = False
            continue

        if in_string:
            result += chr(Int(byte))
            if byte == UInt8(ord("\\")):
                escaped = True
            elif byte == UInt8(ord('"')):
                in_string = False
            continue

        if byte == UInt8(ord('"')):
            in_string = True
            result += chr(Int(byte))
            continue

        if (
            byte == UInt8(ord(" "))
            or byte == UInt8(ord("\n"))
            or byte == UInt8(ord("\t"))
            or byte == UInt8(ord("\r"))
        ):
            continue

        result += chr(Int(byte))

    return result^


def _assert_contains_all(actual: Value, expected_subset: Value) raises:
    if expected_subset.is_array():
        assert_true(actual.is_array())
        var actual_items = actual.array_items()
        for expected_item in expected_subset.array_items():
            var found = False
            for actual_item in actual_items:
                if _json_values_equal(actual_item, expected_item):
                    found = True
                    break
            assert_true(
                found,
                "expected array item missing: " + dumps(expected_item),
            )
        return

    if expected_subset.is_object():
        assert_true(actual.is_object())
        for key in expected_subset.object_keys():
            assert_true(
                _has_key(actual, key),
                "expected object key '" + key + "'",
            )
            _assert_contains_all(actual[key], expected_subset[key])
        return

    _assert_json_equal(actual, expected_subset)


def _json_values_equal(lhs: Value, rhs: Value) raises -> Bool:
    if lhs.is_null() or rhs.is_null():
        return lhs.is_null() and rhs.is_null()

    if lhs.is_bool() or rhs.is_bool():
        return (
            lhs.is_bool()
            and rhs.is_bool()
            and lhs.bool_value() == rhs.bool_value()
        )

    if lhs.is_int() or rhs.is_int():
        return (
            lhs.is_int()
            and rhs.is_int()
            and lhs.int_value() == rhs.int_value()
        )

    if lhs.is_float() or rhs.is_float():
        return (
            lhs.is_float()
            and rhs.is_float()
            and lhs.float_value() == rhs.float_value()
        )

    if lhs.is_string() or rhs.is_string():
        return (
            lhs.is_string()
            and rhs.is_string()
            and lhs.string_value() == rhs.string_value()
        )

    if lhs.is_array() or rhs.is_array():
        if not lhs.is_array() or not rhs.is_array():
            return False
        var lhs_items = lhs.array_items()
        var rhs_items = rhs.array_items()
        if len(lhs_items) != len(rhs_items):
            return False
        for i in range(len(lhs_items)):
            if not _json_values_equal(lhs_items[i], rhs_items[i]):
                return False
        return True

    if lhs.is_object() or rhs.is_object():
        if not lhs.is_object() or not rhs.is_object():
            return False
        var rhs_keys = rhs.object_keys()
        if len(lhs.object_keys()) != len(rhs_keys):
            return False
        for key in rhs_keys:
            if not _has_key(lhs, key):
                return False
            if not _json_values_equal(lhs[key], rhs[key]):
                return False
        return True

    return dumps(lhs) == dumps(rhs)


def _assert_json_equal(actual: Value, expected: Value) raises:
    if expected.is_null():
        assert_true(actual.is_null())
        return

    if expected.is_bool():
        assert_true(actual.is_bool())
        assert_equal(actual.bool_value(), expected.bool_value())
        return

    if expected.is_int():
        assert_true(actual.is_int())
        assert_equal(Int(actual.int_value()), Int(expected.int_value()))
        return

    if expected.is_float():
        assert_true(actual.is_float())
        assert_equal(actual.float_value(), expected.float_value())
        return

    if expected.is_string():
        assert_true(actual.is_string())
        assert_equal(actual.string_value(), expected.string_value())
        return

    if expected.is_array():
        assert_true(actual.is_array())
        var actual_items = actual.array_items()
        var expected_items = expected.array_items()
        assert_equal(len(actual_items), len(expected_items))
        for i in range(len(expected_items)):
            _assert_json_equal(actual_items[i], expected_items[i])
        return

    if expected.is_object():
        assert_true(actual.is_object())
        var expected_keys = expected.object_keys()
        assert_equal(len(actual.object_keys()), len(expected_keys))
        for key in expected_keys:
            assert_true(_has_key(actual, key))
            _assert_json_equal(actual[key], expected[key])
        return

    assert_equal(dumps(actual), dumps(expected))


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False
