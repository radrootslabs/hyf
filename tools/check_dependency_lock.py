#!/usr/bin/env -S uv run --locked --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Check the current Pixi v7 baseline without solving or installing its graph.

Run from the repository root with ``uv run --locked --script
tools/check_dependency_lock.py --mode baseline``. Baseline checks the existing
graph; success does not assert that a future dependency migration has happened.
The adjacent script lock is generated with ``uv lock --script``.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys
import tomllib
from urllib.parse import parse_qsl, urlsplit

import yaml


PLATFORMS = frozenset({"linux-64", "osx-arm64"})
MOJO_VERSION = "1.0.0b1"
MOJO_PACKAGES = frozenset({"mojo", "mojo-compiler", "mojo-python"})
JSON_REVISION = "56025d73631054d7803143fa5e68c5de578e33f5"
SOURCE_REPOSITORIES = {
    "json": "https://github.com/triesap/mojo_json",
    "morph": "https://github.com/triesap/mojo_morph",
    "flare": "https://github.com/triesap/mojo_flare",
}
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
NAME = re.compile(r"[a-z0-9_][a-z0-9_.-]*\Z")
LOCATOR = re.compile(r"([a-z0-9_][a-z0-9_.-]*)\[([0-9a-f]{8})\] @ git\+(.+)\Z")
MAX_INPUT_BYTES = 8 * 1024 * 1024


class InvalidLock(ValueError):
    """An input violates a supported schema or dependency invariant."""


def require(condition: bool, where: str, message: str) -> None:
    if not condition:
        raise InvalidLock(f"{where}: {message}")


def mapping(value: object, where: str) -> dict:
    require(type(value) is dict, where, "expected a mapping")
    require(all(type(key) is str for key in value), where, "expected string keys")
    return value


def shape(value: object, where: str, required: set[str], optional: set[str] = frozenset()) -> dict:
    result = mapping(value, where)
    require(required <= result.keys(), where, "missing required fields; review the supported v7 schema")
    require(result.keys() <= required | optional, where, "unsupported fields; extend the checker explicitly")
    return result


def sequence(value: object, where: str, *, nonempty: bool = True) -> list:
    require(type(value) is list, where, "expected a list")
    require(not nonempty or bool(value), where, "expected a nonempty list")
    return value


def string(value: object, where: str) -> str:
    require(type(value) is str and bool(value) and value == value.strip(), where, "expected a nonblank string without surrounding whitespace")
    require(not any(ord(char) < 32 or ord(char) == 127 for char in value), where, "control characters are forbidden")
    return value


def strings(value: object, where: str, *, nonempty: bool = False) -> list[str]:
    return [string(item, f"{where}[{index}]") for index, item in enumerate(sequence(value, where, nonempty=nonempty))]


class StrictLoader(yaml.SafeLoader):
    """Reject ambiguous mappings, aliases and excessive YAML nesting."""

    def compose_node(self, parent, index):
        event = self.peek_event()
        require(not isinstance(event, yaml.AliasEvent) and getattr(event, "anchor", None) is None, "lock YAML", "anchors and aliases are unsupported")
        require(getattr(event, "tag", None) is None, "lock YAML", "explicit YAML tags are unsupported")
        self._node_count = getattr(self, "_node_count", 0) + 1
        self._depth = getattr(self, "_depth", 0) + 1
        require(self._node_count <= 100_000 and self._depth <= 64, "lock YAML", "document exceeds supported structural limits")
        try:
            return super().compose_node(parent, index)
        finally:
            self._depth -= 1

    def construct_mapping(self, node, deep=False):
        require(isinstance(node, yaml.MappingNode), "lock YAML", "expected a mapping node")
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            require(type(key) is str, "lock YAML", "mapping keys must be strings")
            require(key not in result, "lock YAML", f"duplicate mapping key at line {key_node.start_mark.line + 1}")
            result[key] = self.construct_object(value_node, deep=deep)
        return result


def read_text(path: Path, where: str) -> str:
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_INPUT_BYTES + 1)
        require(len(data) <= MAX_INPUT_BYTES, where, "input exceeds 8 MiB")
        return data.decode("utf-8")
    except (OSError, UnicodeError) as exc:
        raise InvalidLock(f"{where}: cannot read a UTF-8 input") from exc


def web_url(value: object, where: str):
    text = string(value, where)
    require(not any(char.isspace() for char in text) and "\\" not in text, where, "malformed URL")
    try:
        parsed = urlsplit(text)
        require(parsed.scheme == "https" and bool(parsed.hostname), where, "expected an absolute HTTPS URL")
        require(parsed.username is None and parsed.password is None, where, "URL credentials are forbidden")
        require(parsed.port in (None, 443), where, "unsupported URL port")
    except ValueError as exc:
        raise InvalidLock(f"{where}: malformed URL") from exc
    return parsed


def repository(value: object, where: str, *, locked: bool = False) -> tuple[str, str | None]:
    parsed = web_url(value, where)
    path = parsed.path.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    require(bool(path) and not any(part in ("", ".", "..") for part in path[1:].split("/")), where, "malformed repository path")
    require("%" not in path, where, "escaped repository paths are unsupported")
    identity = f"https://{parsed.hostname.lower()}{path}"
    if not locked:
        require(not parsed.query and not parsed.fragment, where, "manifest repository URL must not contain a ref")
        return identity, None
    try:
        query = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True)
    except ValueError as exc:
        raise InvalidLock(f"{where}: malformed Git query") from exc
    require(len(query) == 1 and query[0][0] == "rev", where, "Git source requires only a rev query; branch/tag refs are forbidden")
    revision = query[0][1]
    require(COMMIT.fullmatch(revision) is not None, where, "Git rev must be a full lowercase 40-digit commit")
    require(parsed.fragment == revision, where, "resolved Git commit must exactly match rev")
    return identity, revision


@dataclass(frozen=True)
class Package:
    kind: str
    locator: str
    name: str
    version: str
    platform: str
    source: tuple[str, str] | None = None


def conda_identity(value: object, where: str) -> tuple[str, str, str]:
    parsed = web_url(value, where)
    require(not parsed.query and not parsed.fragment and "%" not in parsed.path, where, "Conda URL must identify a package without query, fragment or escapes")
    parts = parsed.path.split("/")
    require(len(parts) >= 3 and parts[-2] in PLATFORMS | {"noarch"}, where, "unsupported or missing Conda subdir")
    filename = parts[-1]
    suffix = next((item for item in (".conda", ".tar.bz2") if filename.endswith(item)), None)
    require(suffix is not None, where, "expected a Conda package archive")
    fields = filename[:-len(suffix)].rsplit("-", 2)
    require(len(fields) == 3 and NAME.fullmatch(fields[0]) is not None and bool(fields[1]) and bool(fields[2]), where, "malformed Conda package filename")
    return fields[0], fields[1], parts[-2]


def source_identity(value: object, where: str) -> tuple[str, tuple[str, str]]:
    match = LOCATOR.fullmatch(string(value, where))
    require(match is not None, where, "expected a v7 name[variant] @ git+HTTPS locator")
    name = match.group(1)
    identity, revision = repository(match.group(3), where, locked=True)
    return name, (identity, revision)


def manifest_policy(value: object) -> dict[str, tuple[str, str]]:
    manifest = shape(value, "manifest", {"workspace", "dependencies", "tasks"})
    workspace = shape(manifest["workspace"], "manifest.workspace", {"name", "version", "description", "authors", "channels", "platforms", "preview"})
    for field in ("name", "version", "description"):
        string(workspace[field], f"manifest.workspace.{field}")
    for field in ("authors", "channels", "preview"):
        strings(workspace[field], f"manifest.workspace.{field}", nonempty=True)
    platforms = strings(workspace["platforms"], "manifest.workspace.platforms", nonempty=True)
    require(len(platforms) == len(PLATFORMS) and set(platforms) == PLATFORMS, "manifest.workspace.platforms", "baseline requires exactly linux-64 and osx-arm64")
    mapping(manifest["tasks"], "manifest.tasks")
    dependencies = shape(manifest["dependencies"], "manifest.dependencies", {"mojo", *SOURCE_REPOSITORIES})
    require(dependencies["mojo"] == f"=={MOJO_VERSION}", "manifest.dependencies.mojo", "baseline requires exact Mojo ==1.0.0b1; migration needs a separate explicit policy")
    sources = {}
    for index, name in enumerate(sorted(SOURCE_REPOSITORIES)):
        where = f"manifest source[{index}]"
        spec = shape(dependencies[name], where, {"git", "rev"})
        identity, _ = repository(spec["git"], where)
        revision = string(spec["rev"], where)
        require(COMMIT.fullmatch(revision) is not None, where, "Git rev must be a full lowercase 40-digit commit; branch/tag refs are forbidden")
        require(identity == SOURCE_REPOSITORIES[name], where, "repository differs from the independently defined baseline source")
        if name == "json":
            require(revision == JSON_REVISION, where, "JSON revision differs from the independently defined baseline revision")
        sources[name] = (identity, revision)
    return sources


def requirements(value: object, where: str) -> list[str]:
    values = strings(value, where)
    mojo_names = set()
    for index, value in enumerate(values):
        item_where = f"{where}[{index}]"
        match = re.fullmatch(r"([a-z0-9_][a-z0-9_.-]*)(?: ([A-Za-z0-9*<>=!~.,+_| -]+))?", value)
        require(match is not None, item_where, "unsupported dependency match specification")
        name = match.group(1)
        if name in MOJO_PACKAGES:
            require(match.group(2) == f"=={MOJO_VERSION}", item_where, "Mojo dependency must exactly match the baseline root pin")
            require(name not in mojo_names, item_where, "duplicate Mojo dependency")
            mojo_names.add(name)
        require(name != "uuid", item_where, "runtime UUID is outside the baseline; native libuuid is distinct")
    return values


def metadata(record: dict, where: str) -> None:
    for field in ("depends", "constrains"):
        if field in record:
            requirements(record[field], f"{where}.{field}")
    for field in ("license", "license_family", "python_site_packages_path"):
        if field in record:
            string(record[field], f"{where}.{field}")
    for field in ("build_number", "size", "timestamp"):
        if field in record:
            require(type(record[field]) is int and record[field] >= 0, f"{where}.{field}", "expected a nonnegative integer")
    if "noarch" in record:
        require(record["noarch"] in ("python", "generic"), f"{where}.noarch", "unsupported noarch type")
    if "run_exports" in record:
        exports = shape(record["run_exports"], f"{where}.run_exports", set(), {"weak", "strong", "noarch", "weak_constrains", "strong_constrains"})
        for index, value in enumerate(exports.values()):
            requirements(value, f"{where}.run_exports[{index}]")


def package_record(value: object, index: int, sources: dict) -> Package:
    where = f"lock.packages[{index}]"
    record = mapping(value, where)
    if "conda" in record:
        record = shape(record, where, {"conda", "sha256", "md5"}, {"depends", "constrains", "build_number", "license", "license_family", "size", "timestamp", "noarch", "run_exports", "python_site_packages_path"})
        for field, length in (("sha256", 64), ("md5", 32)):
            require(type(record[field]) is str and re.fullmatch(rf"[0-9a-f]{{{length}}}", record[field]) is not None, f"{where}.{field}", "expected a lowercase archive digest")
        name, version, platform = conda_identity(record["conda"], where)
        require(name not in SOURCE_REPOSITORIES, where, "a source-owned runtime package must not be replaced by a binary Conda package")
        package = Package("conda", record["conda"], name, version, platform)
    else:
        record = shape(record, where, {"conda_source", "version", "build", "subdir", "variants", "depends"}, {"license", "license_family", "constrains", "build_packages", "host_packages"})
        name, source = source_identity(record["conda_source"], where)
        require(name in sources, where, "unsupported runtime Git source; baseline allows only JSON, Morph and Flare")
        require(source == sources[name], where, "Git source/revision differs from its exact manifest pin")
        platform = string(record["subdir"], f"{where}.subdir")
        require(platform in PLATFORMS, where, "unsupported source platform")
        variants = shape(record["variants"], f"{where}.variants", {"target_platform"})
        require(variants["target_platform"] == platform, where, "source variant and subdir disagree")
        string(record["build"], f"{where}.build")
        package = Package("conda_source", record["conda_source"], name, string(record["version"], f"{where}.version"), platform, source)
        require(f"mojo =={MOJO_VERSION}" in strings(record["depends"], f"{where}.depends", nonempty=True), where, "source package must declare the baseline exact Mojo dependency")
    require(package.name != "uuid", where, "runtime UUID is outside the baseline; native libuuid is a distinct allowed package")
    if package.name in MOJO_PACKAGES:
        require(package.version == MOJO_VERSION, where, "Mojo/compiler/python version differs from the exact baseline root pin")
    metadata(record, where)
    return package


def package_references(value: object, where: str, packages: dict, platform: str) -> list[Package]:
    result = []
    seen = set()
    names = set()
    for index, item in enumerate(sequence(value, where)):
        item_where = f"{where}[{index}]"
        item = mapping(item, item_where)
        require(len(item) == 1 and next(iter(item)) in {"conda", "conda_source"}, item_where, "expected exactly one supported package locator")
        kind, locator = next(iter(item.items()))
        string(locator, item_where)
        key = (kind, locator)
        require(key in packages, item_where, "package reference has no corresponding package record")
        require(key not in seen, item_where, "duplicate package reference")
        package = packages[key]
        require(package.name not in names, item_where, "multiple records select the same package name on one platform")
        require(package.platform in {platform, "noarch"}, item_where, "referenced package belongs to another platform")
        seen.add(key)
        names.add(package.name)
        result.append(package)
    return result


def check_lock(value: object, sources: dict) -> None:
    lock = shape(value, "lock", {"version", "platforms", "environments", "packages"})
    require(type(lock["version"]) is int and lock["version"] == 7, "lock.version", "only actual Pixi YAML v7 is supported")
    platforms = []
    for index, value in enumerate(sequence(lock["platforms"], "lock.platforms")):
        item = shape(value, f"lock.platforms[{index}]", {"name"})
        platforms.append(string(item["name"], f"lock.platforms[{index}].name"))
    require(len(platforms) == len(PLATFORMS) and set(platforms) == PLATFORMS, "lock.platforms", "baseline requires exactly linux-64 and osx-arm64")
    records = sequence(lock["packages"], "lock.packages")
    packages = {}
    source_platforms = set()
    for index, record in enumerate(records):
        package = package_record(record, index, sources)
        key = (package.kind, package.locator)
        require(key not in packages, f"lock.packages[{index}]", "duplicate package record")
        packages[key] = package
        if package.source is not None:
            identity = (package.name, package.platform)
            require(identity not in source_platforms, f"lock.packages[{index}]", "multiple source records for one runtime package/platform")
            source_platforms.add(identity)
    require(source_platforms == {(name, platform) for name in sources for platform in PLATFORMS}, "lock.packages", "missing source package/platform records")
    # Two JSON variant records represent one canonical repository/commit, not
    # two sources. Every source record was compared to the independent policy.
    json_sources = {package.source for package in packages.values() if package.name == "json"}
    require(json_sources == {sources["json"]}, "lock.packages", "expected one canonical JSON repository/revision")
    environments = shape(lock["environments"], "lock.environments", {"default"})
    environment = shape(environments["default"], "lock.environments.default", {"channels", "packages"})
    channels = []
    for index, value in enumerate(sequence(environment["channels"], "lock default channels")):
        item = shape(value, f"lock default channels[{index}]", {"url"})
        parsed = web_url(item["url"], f"lock default channels[{index}]")
        require(not parsed.query and not parsed.fragment, f"lock default channels[{index}]", "channel URL must not contain a query or fragment")
        channels.append(item["url"].rstrip("/"))
    require(len(set(channels)) == len(channels), "lock default channels", "duplicate channel")
    selections = shape(environment["packages"], "lock default packages", set(PLATFORMS))
    selected_sources = set()
    for platform in sorted(PLATFORMS):
        selected = package_references(selections[platform], f"lock default packages.{platform}", packages, platform)
        names = {package.name for package in selected}
        require(MOJO_PACKAGES <= names, f"lock default packages.{platform}", "missing Mojo, mojo-compiler or mojo-python package")
        actual_sources = {package.name for package in selected if package.source is not None}
        require(actual_sources == sources.keys(), f"lock default packages.{platform}", "missing required runtime source selection")
        selected_sources.update((package.name, package.platform) for package in selected if package.source is not None)
    require(selected_sources == source_platforms, "lock default packages", "source records and runtime selections disagree")
    # Inspect every recorded build/host package reference too; unresolved refs,
    # foreign platforms and hidden alternate source records cannot pass here.
    for index, record in enumerate(records):
        package = packages[("conda_source", record["conda_source"])] if "conda_source" in record else None
        for field in ("build_packages", "host_packages"):
            if field in record:
                package_references(record[field], f"lock.packages[{index}].{field}", packages, package.platform)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "dependency lock: invalid command line; use --help\n")


def main(argv: list[str] | None = None) -> int:
    parser = Parser(description=__doc__)
    parser.add_argument("--mode", choices=("baseline",), required=True, help="explicitly select the existing graph policy")
    parser.add_argument("--manifest", type=Path, default=Path("pixi.toml"), help="manifest input (default: pixi.toml)")
    parser.add_argument("--lock", type=Path, default=Path("pixi.lock"), help="lock input (default: pixi.lock)")
    args = parser.parse_args(argv)
    try:
        try:
            manifest = tomllib.loads(read_text(args.manifest, "manifest input"))
        except tomllib.TOMLDecodeError as exc:
            raise InvalidLock("manifest TOML: malformed document") from exc
        try:
            lock = yaml.load(read_text(args.lock, "lock input"), Loader=StrictLoader)
        except yaml.YAMLError as exc:
            mark = getattr(exc, "problem_mark", None)
            location = f" at line {mark.line + 1}, column {mark.column + 1}" if mark is not None else ""
            raise InvalidLock(f"lock YAML: malformed or unsupported document{location}") from exc
        check_lock(lock, manifest_policy(manifest))
    except InvalidLock as exc:
        print(f"dependency lock: FAIL: {exc}", file=sys.stderr)
        return 1
    except (RecursionError, TypeError, ValueError, KeyError, OverflowError):
        print("dependency lock: FAIL: malformed or unsupported input shape", file=sys.stderr)
        return 1
    print("dependency lock: baseline PASS (YAML v7; 2 platforms; one JSON source; immutable runtime Git refs; Mojo 1.0.0b1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
