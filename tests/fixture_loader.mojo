from std.pathlib import Path, _dir_of_current_file

from mojson import Value, loads


def fixture_root_path() raises -> Path:
    return _dir_of_current_file() / "fixtures" / "v1"


def fixture_manifest_path() raises -> Path:
    return fixture_root_path() / "manifest.json"


def load_fixture_json_file(path: Path) raises -> Value:
    return loads(path.read_text())


def _skip_whitespace(raw: String, start_index: Int) -> Int:
    var data = raw.as_bytes()
    var index = start_index
    while index < len(data):
        var byte = data[index]
        if (
            byte == UInt8(ord(" "))
            or byte == UInt8(ord("\n"))
            or byte == UInt8(ord("\t"))
            or byte == UInt8(ord("\r"))
        ):
            index += 1
            continue
        break
    return index


def _extract_json_value(raw: String, start_index: Int) raises -> String:
    var data = raw.as_bytes()
    if start_index >= len(data):
        raise Error("fixture field value start out of bounds")

    var first = data[start_index]
    if first == UInt8(ord("{")) or first == UInt8(ord("[")):
        var depth = 0
        var in_string = False
        var escaped = False
        var index = start_index
        while index < len(data):
            var byte = data[index]
            if escaped:
                escaped = False
            elif in_string:
                if byte == UInt8(ord("\\")):
                    escaped = True
                elif byte == UInt8(ord('"')):
                    in_string = False
            else:
                if byte == UInt8(ord('"')):
                    in_string = True
                elif byte == UInt8(ord("{")) or byte == UInt8(ord("[")):
                    depth += 1
                elif byte == UInt8(ord("}")) or byte == UInt8(ord("]")):
                    depth -= 1
                    if depth == 0:
                        return String(raw[byte=start_index : index + 1])
            index += 1
        raise Error("unterminated fixture object or array field")

    if first == UInt8(ord('"')):
        var escaped = False
        var index = start_index + 1
        while index < len(data):
            var byte = data[index]
            if escaped:
                escaped = False
            elif byte == UInt8(ord("\\")):
                escaped = True
            elif byte == UInt8(ord('"')):
                return String(raw[byte=start_index : index + 1])
            index += 1
        raise Error("unterminated fixture string field")

    var index = start_index
    while index < len(data):
        var byte = data[index]
        if (
            byte == UInt8(ord(","))
            or byte == UInt8(ord("}"))
            or byte == UInt8(ord("]"))
        ):
            return String(raw[byte=start_index:index])
        index += 1

    return String(raw[byte=start_index:])


def load_fixture_top_level_field_from_path(path: Path, key: String) raises -> Value:
    var raw = path.read_text()
    var data = raw.as_bytes()
    var index = _skip_whitespace(raw, 0)
    if index >= len(data) or data[index] != UInt8(ord("{")):
        raise Error("fixture scenario must be a top-level JSON object")

    index += 1
    while index < len(data):
        index = _skip_whitespace(raw, index)
        if index >= len(data):
            break

        if data[index] == UInt8(ord("}")):
            break

        if data[index] != UInt8(ord('"')):
            raise Error("fixture scenario object key must be a JSON string")

        var key_json = _extract_json_value(raw, index)
        var parsed_key = loads(key_json)
        if not parsed_key.is_string():
            raise Error("fixture scenario object key did not parse as a string")

        index += key_json.byte_length()
        index = _skip_whitespace(raw, index)
        if index >= len(data) or data[index] != UInt8(ord(":")):
            raise Error(
                "fixture scenario field '" + parsed_key.string_value()
                + "' missing colon"
            )

        var value_start = _skip_whitespace(raw, index + 1)
        var value_json = _extract_json_value(raw, value_start)
        if parsed_key.string_value() == key:
            return loads(value_json)

        index = value_start + value_json.byte_length()
        index = _skip_whitespace(raw, index)
        if index >= len(data):
            break
        if data[index] == UInt8(ord(",")):
            index += 1
            continue
        if data[index] == UInt8(ord("}")):
            break
        raise Error(
            "fixture scenario field '" + parsed_key.string_value()
            + "' missing delimiter"
        )

    raise Error("fixture scenario missing field '" + key + "'")


def load_fixture_manifest() raises -> Value:
    return load_fixture_json_file(fixture_manifest_path())


def load_fixture_scenario(relative_path: String) raises -> Value:
    return load_fixture_json_file(fixture_root_path() / String(relative_path))


def load_fixture_scenario_request(relative_path: String) raises -> Value:
    return load_fixture_top_level_field_from_path(
        fixture_root_path() / String(relative_path), "request"
    )


def load_fixture_scenario_expected(relative_path: String) raises -> Value:
    return load_fixture_top_level_field_from_path(
        fixture_root_path() / String(relative_path), "expected"
    )
