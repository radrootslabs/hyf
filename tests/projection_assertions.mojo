from std.collections import List

from json import Value, dumps, loads


def registered_projection_operators() -> List[String]:
    var operators = List[String]()
    operators.append("equals")
    operators.append("absent")
    operators.append("present")
    operators.append("contains")
    operators.append("not_equals")
    operators.append("tolerance")
    return operators^


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _lookup(actual: Value, pointer: String) raises -> Value:
    var current = actual.copy()
    if pointer == "" or pointer == "/":
        return current^
    for raw_token in pointer.split("/"):
        var token = String(raw_token)
        if token == "":
            continue
        if current.is_array():
            current = current.array_items()[Int(token)].copy()
        elif current.is_object():
            current = loads(current.get(token))
        else:
            raise Error("projection path does not resolve: " + pointer)
    return current^


def _path_exists(actual: Value, pointer: String) -> Bool:
    try:
        _ = _lookup(actual, pointer)
        return True
    except:
        return False


def _deep_equal(lhs: Value, rhs: Value) -> Bool:
    return dumps(lhs) == dumps(rhs)


def _is_number(value: Value) -> Bool:
    return value.is_int() or value.is_float()


def _as_float(value: Value) -> Float64:
    if value.is_float():
        return value.float_value()
    return Float64(value.int_value())


def assert_projection(actual: Value, assertions: List[Value]) raises:
    for assertion in assertions:
        if not _has_key(assertion, "operator"):
            raise Error("projection assertion requires 'operator'")
        var operator = assertion["operator"].string_value()
        var registered = registered_projection_operators()
        var known = False
        for candidate in registered:
            if candidate == operator:
                known = True
        if not known:
            raise Error("unknown projection operator: " + operator)

        if operator == "present":
            if not _path_exists(actual, assertion["path"].string_value()):
                raise Error(
                    "expected present path: " + assertion["path"].string_value()
                )
            continue
        if operator == "absent":
            if _path_exists(actual, assertion["path"].string_value()):
                raise Error(
                    "expected absent path: " + assertion["path"].string_value()
                )
            continue

        var observed = _lookup(actual, assertion["path"].string_value())
        if operator == "equals":
            if not _deep_equal(observed, assertion["value"]):
                raise Error(
                    "expected equality at " + assertion["path"].string_value()
                )
        elif operator == "not_equals":
            if _deep_equal(observed, assertion["value"]):
                raise Error(
                    "expected inequality at " + assertion["path"].string_value()
                )
        elif operator == "contains":
            if not observed.is_array():
                raise Error(
                    "contains requires an array at "
                    + assertion["path"].string_value()
                )
            var found = False
            for item in observed.array_items():
                if _deep_equal(item, assertion["value"]):
                    found = True
            if not found:
                raise Error(
                    "expected contained value at "
                    + assertion["path"].string_value()
                )
        elif operator == "tolerance":
            if not _is_number(observed) or not _is_number(assertion["value"]):
                raise Error(
                    "tolerance requires numeric values at "
                    + assertion["path"].string_value()
                )
            var delta = _as_float(observed) - _as_float(assertion["value"])
            if delta < 0.0:
                delta = -delta
            var tolerance = _as_float(assertion["tolerance"])
            if delta > tolerance:
                raise Error(
                    "value out of tolerance at "
                    + assertion["path"].string_value()
                )
