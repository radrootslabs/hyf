from std.pathlib import Path, _dir_of_current_file

from mojson import Value, loads


def fixture_root_path() raises -> Path:
    return _dir_of_current_file() / "fixtures" / "v1"


def fixture_manifest_path() raises -> Path:
    return fixture_root_path() / "manifest.json"


def load_fixture_manifest() raises -> Value:
    return loads(fixture_manifest_path().read_text())


def load_fixture_scenario(relative_path: String) raises -> Value:
    return loads((fixture_root_path() / String(relative_path)).read_text())


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
                        return String(
                            raw[
                                byte=start_index : index + 1
                            ]
                        )
            index += 1
        raise Error("unterminated fixture object or array field")

    if first == UInt8(ord('"')):
        var in_string = True
        var escaped = False
        var index = start_index + 1
        while index < len(data):
            var byte = data[index]
            if escaped:
                escaped = False
            elif byte == UInt8(ord("\\")):
                escaped = True
            elif byte == UInt8(ord('"')) and in_string:
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


def load_fixture_scenario_field(relative_path: String, key: String) raises -> Value:
    var raw = (fixture_root_path() / String(relative_path)).read_text()
    var pattern = "\"" + key + "\""
    var key_index = raw.find(pattern)
    if key_index < 0:
        raise Error("fixture scenario missing field '" + key + "'")

    var data = raw.as_bytes()
    var index = key_index + pattern.byte_length()
    while index < len(data) and data[index] != UInt8(ord(":")):
        index += 1

    if index >= len(data):
        raise Error("fixture scenario field '" + key + "' missing colon")

    var value_start = _skip_whitespace(raw, index + 1)
    return loads(_extract_json_value(raw, value_start))
