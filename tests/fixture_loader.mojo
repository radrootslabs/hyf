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
