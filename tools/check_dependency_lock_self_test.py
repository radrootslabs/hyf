"""Isolated synthetic regression cases for the dependency lock checker.

Invoke through ``check_dependency_lock.py --mode baseline --self-test`` so the
existing locked script supplies PyYAML. Fixture pins are independent literal
oracles. Example archive URLs/digests are test data, never downloaded artifacts.
All filesystem fixtures belong to temporary directories and no subprocess runs.
"""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
from io import StringIO
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest

import yaml


# Keep these acceptance inputs independent from the checker policy constants.
PLATFORMS = ("linux-64", "osx-arm64")
PINS = {
    "json": (
        "https://github.com/triesap/mojo_json",
        "56025d73631054d7803143fa5e68c5de578e33f5",
    ),
    "morph": (
        "https://github.com/triesap/mojo_morph",
        "ea73f909990f3d3f5d12b786fec2f09e1e09f462",
    ),
    "flare": (
        "https://github.com/triesap/mojo_flare",
        "14aa338d8c4f352ebb2d590cddfde0bde5ea1971",
    ),
}
SECRET_MARKER = "SYNTHETIC_CREDENTIAL_MUST_NOT_APPEAR"


def archive(name: str, platform: str, version: str = "1.0.0b1") -> dict:
    return {
        "conda": f"https://packages.example.invalid/channel/{platform}/{name}-{version}-test_0.conda",
        "sha256": "a" * 64,
        "md5": "b" * 32,
        "depends": [],
    }


def reference(record: dict) -> dict:
    kind = "conda" if "conda" in record else "conda_source"
    return {kind: record[kind]}


def fixture() -> tuple[dict, dict]:
    manifest = {
        "workspace": {
            "name": "dependency_lock_fixture",
            "version": "0.0.0",
            "description": "Synthetic lock checker fixture",
            "authors": ["Fixture Authors"],
            "channels": ["https://packages.example.invalid/channel/"],
            "platforms": ["linux-64", "osx-arm64"],
            "preview": ["pixi-build"],
        },
        "dependencies": {
            "mojo": "==1.0.0b1",
            **{name: {"git": repo + ".git", "rev": rev} for name, (repo, rev) in PINS.items()},
        },
        "tasks": {"fixture": "echo fixture"},
    }
    lock = {
        "version": 7,
        "platforms": [{"name": platform} for platform in PLATFORMS],
        "environments": {
            "default": {
                "channels": [{"url": "https://packages.example.invalid/channel/"}],
                "packages": {platform: [] for platform in PLATFORMS},
            }
        },
        "packages": [],
    }
    python = archive("mojo-python", "noarch")
    python["noarch"] = "python"
    lock["packages"].append(python)
    for platform_index, platform in enumerate(PLATFORMS):
        selected = lock["environments"]["default"]["packages"][platform]
        mojo = archive("mojo", platform)
        mojo["depends"] = ["mojo-compiler ==1.0.0b1"]
        compiler = archive("mojo-compiler", platform)
        compiler["depends"] = ["mojo-python ==1.0.0b1"]
        lock["packages"].extend((mojo, compiler))
        selected.extend(reference(record) for record in (python, mojo, compiler))
        for source_index, (name, (repo, rev)) in enumerate(PINS.items(), start=1):
            variant = f"{source_index * 16 + platform_index:08x}"
            record = {
                "conda_source": f"{name}[{variant}] @ git+{repo}?rev={rev}#{rev}",
                "version": "0.0.0",
                "build": "test_0",
                "subdir": platform,
                "variants": {"target_platform": platform},
                "depends": ["mojo ==1.0.0b1"],
                "build_packages": [reference(compiler)],
                "host_packages": [reference(python), reference(mojo)],
            }
            lock["packages"].append(record)
            selected.append(reference(record))
    native_uuid = archive("libuuid", "linux-64", "2.42")
    lock["packages"].append(native_uuid)
    lock["environments"]["default"]["packages"]["linux-64"].append(reference(native_uuid))
    return manifest, lock


def toml_value(value: object) -> str:
    if type(value) is dict:
        return "{ " + ", ".join(f"{json.dumps(key)} = {toml_value(item)}" for key, item in value.items()) + " }"
    if type(value) is list:
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    return json.dumps(value, ensure_ascii=False)


def manifest_text(manifest: dict) -> str:
    lines = [f"{json.dumps(key)} = {toml_value(value)}" for key, value in manifest.items() if type(value) is not dict]
    for section, table in manifest.items():
        if type(table) is dict:
            lines.append(f"[{json.dumps(section)}]")
            lines.extend(f"{json.dumps(key)} = {toml_value(value)}" for key, value in table.items())
    return "\n".join(lines) + "\n"


def replace_text(value: object, old: str, new: str) -> object:
    """Change a fixture fact consistently in its records and references."""
    if type(value) is str:
        return value.replace(old, new)
    if type(value) is list:
        return [replace_text(item, old, new) for item in value]
    if type(value) is dict:
        return {key: replace_text(item, old, new) for key, item in value.items()}
    return value


class DependencyLockTests(unittest.TestCase):
    checker = None

    def setUp(self):
        temporary = TemporaryDirectory(prefix="dependency-lock-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest_path = self.root / "pixi.toml"
        self.lock_path = self.root / "pixi.lock"
        self.manifest, self.lock = fixture()
        self.write_fixture()

    def write_fixture(self):
        self.manifest_path.write_text(manifest_text(self.manifest), encoding="utf-8")
        self.lock_path.write_text(yaml.safe_dump(self.lock, sort_keys=False), encoding="utf-8")

    def invoke(self, argv=None):
        if argv is None:
            argv = ["--mode", "baseline", "--manifest", str(self.manifest_path), "--lock", str(self.lock_path)]
        stdout = StringIO()
        stderr = StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                code = self.checker.main(argv)
            except SystemExit as exc:
                code = exc.code
        self.assertIs(type(code), int, "CLI exit must be an integer")
        output = stdout.getvalue() + stderr.getvalue()
        self.assertNotIn("Traceback", output)
        self.assertNotIn(SECRET_MARKER, output, "diagnostics leaked synthetic credentials or untrusted data")
        return code, stdout.getvalue(), stderr.getvalue()

    def assert_valid(self, *, rewrite=True):
        if rewrite:
            self.write_fixture()
        code, stdout, stderr = self.invoke()
        self.assertEqual(code, 0, stderr)
        self.assertEqual(stderr, "")
        self.assertIn("baseline PASS (YAML v7; 2 platforms; one JSON source;", stdout)
        self.assertIn("Mojo 1.0.0b1)", stdout)

    def assert_invalid(self, cause: str, *, rewrite=True):
        if rewrite:
            self.write_fixture()
        code, stdout, stderr = self.invoke()
        self.assertEqual(code, 1, (stdout, stderr))
        self.assertTrue(stderr.startswith("dependency lock: FAIL: "), stderr)
        self.assertIn(cause, stderr)
        self.assertNotIn("PASS", stdout)
        return stderr

    def selections(self, platform="linux-64"):
        return self.lock["environments"]["default"]["packages"][platform]

    def source(self, name="json", platform="linux-64"):
        return next(record for record in self.lock["packages"] if record.get("conda_source", "").startswith(name + "[") and record["subdir"] == platform)

    def binary(self, name="mojo", platform="linux-64"):
        prefix = f"https://packages.example.invalid/channel/{platform}/{name}-"
        return next(record for record in self.lock["packages"] if record.get("conda", "").startswith(prefix) and record["conda"].split("/")[-1].rsplit("-", 2)[0] == name)

    def change_source(self, old: str, new: str):
        self.lock = replace_text(self.lock, old, new)

    def test_independent_baseline_valid(self):
        self.assert_valid()

    def test_two_json_platform_variants_are_one_source(self):
        first = self.source(platform="linux-64")["conda_source"]
        second = self.source(platform="osx-arm64")["conda_source"]
        self.assertNotEqual(first, second)
        self.assertIn("56025d73631054d7803143fa5e68c5de578e33f5", first)
        self.assert_valid()

    def test_canonical_repository_spellings(self):
        self.manifest["dependencies"]["json"]["git"] = "https://GITHUB.COM/triesap/mojo_json.git/"
        self.change_source("git+https://github.com/triesap/mojo_json?", "git+https://GITHUB.COM/triesap/mojo_json.git/?")
        self.assert_valid()

    def test_frozen_non_json_commit_is_manifest_driven(self):
        old = self.manifest["dependencies"]["morph"]["rev"]
        self.manifest["dependencies"]["morph"]["rev"] = "c" * 40
        self.change_source(old, "c" * 40)
        self.assert_valid()

    def test_native_libuuid_is_allowed(self):
        self.assertIn(reference(self.binary("libuuid")), self.selections())
        self.assert_valid()

    def test_tar_bz2_package_archive_is_allowed(self):
        old = self.binary()["conda"]
        self.change_source(old, old.removesuffix(".conda") + ".tar.bz2")
        self.assert_valid()

    def test_duplicate_json_record_is_rejected(self):
        extra = deepcopy(self.source())
        extra["conda_source"] = extra["conda_source"].replace("[00000010]", "[000000ff]")
        self.lock["packages"].append(extra)
        self.assert_invalid("multiple source records for one runtime package/platform")

    def test_duplicate_exact_package_record_is_rejected(self):
        self.lock["packages"].append(deepcopy(self.source()))
        self.assert_invalid("duplicate package record")

    def test_duplicate_json_selection_is_rejected(self):
        self.selections().append(reference(self.source()))
        self.assert_invalid("duplicate package reference")

    def test_second_json_repository_is_rejected(self):
        old = self.source()["conda_source"]
        self.change_source(old, old.replace("triesap/mojo_json", "other/mojo_json"))
        self.assert_invalid("Git source/revision differs from its exact manifest pin")

    def test_wrong_json_lock_revision_is_rejected(self):
        old = self.source()["conda_source"]
        self.change_source(old, old.replace("56025d73631054d7803143fa5e68c5de578e33f5", "c" * 40))
        self.assert_invalid("Git source/revision differs from its exact manifest pin")

    def test_joint_manifest_lock_json_revision_drift_is_rejected(self):
        old = self.manifest["dependencies"]["json"]["rev"]
        self.manifest["dependencies"]["json"]["rev"] = "c" * 40
        self.change_source(old, "c" * 40)
        self.assert_invalid("JSON revision differs from the independently defined baseline revision")

    def test_joint_manifest_lock_json_repository_drift_is_rejected(self):
        self.manifest["dependencies"]["json"]["git"] = "https://example.invalid/wrong/json.git"
        self.change_source("https://github.com/triesap/mojo_json", "https://example.invalid/wrong/json")
        self.assert_invalid("repository differs from the independently defined baseline source")

    def test_manifest_branch_revision_is_rejected(self):
        self.manifest["dependencies"]["json"]["rev"] = "main"
        self.assert_invalid("Git rev must be a full lowercase 40-digit commit")

    def test_manifest_branch_without_rev_is_rejected(self):
        self.manifest["dependencies"]["json"].pop("rev")
        self.manifest["dependencies"]["json"]["branch"] = "main"
        self.assert_invalid("missing required fields")

    def test_manifest_extra_branch_selector_is_rejected(self):
        self.manifest["dependencies"]["json"]["branch"] = "main"
        self.assert_invalid("unsupported fields")

    def test_manifest_short_commit_is_rejected(self):
        self.manifest["dependencies"]["morph"]["rev"] = "abcdef0"
        self.assert_invalid("Git rev must be a full lowercase 40-digit commit")

    def test_manifest_uppercase_commit_is_rejected(self):
        self.manifest["dependencies"]["morph"]["rev"] = "A" * 40
        self.assert_invalid("Git rev must be a full lowercase 40-digit commit")

    def test_lock_branch_source_is_rejected(self):
        old = self.source("flare")["conda_source"]
        self.change_source(old, old.replace("?rev=" + PINS["flare"][1], "?branch=main"))
        self.assert_invalid("branch/tag refs are forbidden")

    def test_lock_short_commit_is_rejected(self):
        old = self.source("morph")["conda_source"]
        self.change_source(old, old.replace(PINS["morph"][1], "abcdef0"))
        self.assert_invalid("Git rev must be a full lowercase 40-digit commit")

    def test_lock_resolved_commit_mismatch_is_rejected(self):
        old = self.source()["conda_source"]
        self.change_source(old, old.rsplit("#", 1)[0] + "#" + "c" * 40)
        self.assert_invalid("resolved Git commit must exactly match rev")

    def test_extra_git_query_does_not_echo_secret(self):
        old = self.source()["conda_source"]
        self.change_source(old, old.replace("#", f"&token={SECRET_MARKER}#"))
        self.assert_invalid("Git source requires only a rev query")

    def test_git_url_credentials_do_not_echo(self):
        old = self.source()["conda_source"]
        self.change_source(old, old.replace("https://", f"https://user:{SECRET_MARKER}@"))
        self.assert_invalid("malformed URL")

    def test_manifest_url_credentials_do_not_echo(self):
        self.manifest["dependencies"]["json"]["git"] = f"https://user:{SECRET_MARKER}@example.invalid/json.git"
        self.assert_invalid("malformed URL")

    def test_non_https_git_source_is_rejected(self):
        old = self.source()["conda_source"]
        self.change_source(old, old.replace("git+https://", "git+ssh://"))
        self.assert_invalid("malformed URL")

    def test_source_locator_shape_is_rejected(self):
        old = self.source()["conda_source"]
        self.change_source(old, "json @ " + old.split(" @ ", 1)[1])
        self.assert_invalid("expected a v7 name[variant] @ git+HTTPS locator")

    def test_unknown_runtime_git_source_is_rejected(self):
        extra = deepcopy(self.source())
        extra["conda_source"] = extra["conda_source"].replace("json[", "other[")
        self.lock["packages"].append(extra)
        self.assert_invalid("unsupported runtime Git source")

    def test_runtime_uuid_binary_is_rejected(self):
        record = archive("uuid", "linux-64", "0.0.0")
        self.lock["packages"].append(record)
        self.selections().append(reference(record))
        self.assert_invalid("runtime UUID is outside the baseline; native libuuid is a distinct allowed package")

    def test_runtime_uuid_requirement_is_rejected(self):
        self.source()["depends"].append("uuid >=0.0.0")
        self.assert_invalid("runtime UUID is outside the baseline; native libuuid is distinct")

    def test_binary_json_cannot_replace_source(self):
        self.lock["packages"].append(archive("json", "linux-64", "0.0.0"))
        self.assert_invalid("source-owned runtime package must not be replaced by a binary Conda package")

    def test_manifest_mojo_range_is_rejected(self):
        self.manifest["dependencies"]["mojo"] = ">=1.0.0b1"
        self.assert_invalid("baseline requires exact Mojo ==1.0.0b1")

    def test_joint_manifest_lock_mojo_drift_is_rejected(self):
        self.manifest["dependencies"]["mojo"] = "==9.9.9"
        self.lock = replace_text(self.lock, "1.0.0b1", "9.9.9")
        self.assert_invalid("baseline requires exact Mojo ==1.0.0b1")

    def test_all_three_mojo_archive_versions_are_checked(self):
        for name, platform in (("mojo", "linux-64"), ("mojo-compiler", "osx-arm64"), ("mojo-python", "noarch")):
            with self.subTest(name=name):
                self.manifest, self.lock = fixture()
                old = self.binary(name, platform)["conda"]
                self.change_source(old, old.replace("1.0.0b1", "9.9.9"))
                self.assert_invalid("Mojo/compiler/python version differs from the exact baseline root pin")

    def test_unselected_mixed_mojo_record_is_rejected(self):
        self.lock["packages"].append(archive("mojo", "linux-64", "9.9.9"))
        self.assert_invalid("Mojo/compiler/python version differs from the exact baseline root pin")

    def test_missing_mojo_family_selection_is_rejected(self):
        self.selections().remove(reference(self.binary("mojo-compiler")))
        self.assert_invalid("missing Mojo, mojo-compiler or mojo-python package")

    def test_wrong_source_mojo_dependency_is_rejected(self):
        self.source()["depends"] = ["mojo ==9.9.9"]
        self.assert_invalid("source package must declare the baseline exact Mojo dependency")

    def test_conflicting_source_mojo_dependency_is_rejected(self):
        self.source()["depends"].append("mojo ==9.9.9")
        self.assert_invalid("Mojo dependency must exactly match the baseline root pin")

    def test_compiler_python_dependency_mismatch_is_rejected(self):
        self.binary("mojo-compiler")["depends"] = ["mojo-python ==9.9.9"]
        self.assert_invalid("Mojo dependency must exactly match the baseline root pin")

    def test_duplicate_mojo_dependency_is_rejected(self):
        self.source()["depends"].append("mojo ==1.0.0b1")
        self.assert_invalid("duplicate Mojo dependency")

    def test_missing_source_record_is_rejected(self):
        self.lock["packages"].remove(self.source())
        self.assert_invalid("missing source package/platform records")

    def test_missing_runtime_source_selection_is_rejected(self):
        self.selections().remove(reference(self.source()))
        self.assert_invalid("missing required runtime source selection")

    def test_missing_referenced_binary_record_is_rejected(self):
        self.lock["packages"].remove(self.binary("libuuid"))
        self.assert_invalid("package reference has no corresponding package record")

    def test_missing_host_reference_record_is_rejected(self):
        self.source()["host_packages"].append({"conda": "https://packages.example.invalid/channel/linux-64/missing-0.0.0-test_0.conda"})
        stderr = self.assert_invalid("package reference has no corresponding package record")
        self.assertIn("host_packages", stderr)

    def test_missing_build_reference_record_is_rejected(self):
        self.source()["build_packages"].append({"conda": "https://packages.example.invalid/channel/linux-64/missing-0.0.0-test_0.conda"})
        stderr = self.assert_invalid("package reference has no corresponding package record")
        self.assertIn("build_packages", stderr)

    def test_foreign_platform_reference_is_rejected(self):
        self.selections().remove(reference(self.binary()))
        self.selections().append(reference(self.binary(platform="osx-arm64")))
        self.assert_invalid("referenced package belongs to another platform")

    def test_mixed_reference_kinds_are_rejected(self):
        self.selections()[0]["conda_source"] = self.source()["conda_source"]
        self.assert_invalid("expected exactly one supported package locator")

    def test_source_variant_mismatch_is_rejected(self):
        self.source()["variants"]["target_platform"] = "osx-arm64"
        self.assert_invalid("source variant and subdir disagree")

    def test_missing_source_variants_is_rejected(self):
        self.source().pop("variants")
        self.assert_invalid("missing required fields")

    def test_missing_lock_platform_is_rejected(self):
        self.lock["platforms"].pop()
        self.assert_invalid("baseline requires exactly linux-64 and osx-arm64")

    def test_duplicate_lock_platform_is_rejected(self):
        self.lock["platforms"][1]["name"] = "linux-64"
        self.assert_invalid("baseline requires exactly linux-64 and osx-arm64")

    def test_missing_manifest_platform_is_rejected(self):
        self.manifest["workspace"]["platforms"].pop()
        self.assert_invalid("manifest.workspace.platforms: baseline requires exactly")

    def test_missing_runtime_platform_mapping_is_rejected(self):
        self.lock["environments"]["default"]["packages"].pop("osx-arm64")
        self.assert_invalid("lock default packages: missing required fields")

    def test_extra_environment_is_rejected(self):
        self.lock["environments"]["other"] = {}
        self.assert_invalid("lock.environments: unsupported fields")

    def test_missing_default_environment_is_rejected(self):
        self.lock["environments"] = {}
        self.assert_invalid("lock.environments: missing required fields")

    def test_empty_graph_is_rejected(self):
        self.lock["packages"] = []
        self.assert_invalid("lock.packages: expected a nonempty list")

    def test_empty_runtime_selection_is_rejected(self):
        self.lock["environments"]["default"]["packages"]["linux-64"] = []
        self.assert_invalid("lock default packages.linux-64: expected a nonempty list")

    def test_unsupported_lock_version_is_rejected(self):
        self.lock["version"] = 8
        self.assert_invalid("lock.version: only actual Pixi YAML v7 is supported")

    def test_boolean_lock_version_is_rejected(self):
        self.lock["version"] = True
        self.assert_invalid("lock.version: only actual Pixi YAML v7 is supported")

    def test_unknown_lock_field_is_secret_safe(self):
        self.lock[SECRET_MARKER] = "untrusted value"
        self.assert_invalid("lock: unsupported fields")

    def test_unknown_manifest_section_is_secret_safe(self):
        self.manifest[SECRET_MARKER] = {}
        self.assert_invalid("manifest: unsupported fields")

    def test_unknown_package_field_is_rejected(self):
        self.binary()["new_source_type"] = "unsupported"
        self.assert_invalid("unsupported fields")

    def test_incomplete_conda_record_is_rejected(self):
        self.binary().pop("sha256")
        self.assert_invalid("missing required fields")

    def test_malformed_archive_digest_is_rejected(self):
        self.binary()["sha256"] = "not-a-digest"
        self.assert_invalid("expected a lowercase archive digest")

    def test_conda_url_query_is_secret_safe(self):
        old = self.binary()["conda"]
        self.change_source(old, old + f"?token={SECRET_MARKER}")
        self.assert_invalid("Conda URL must identify a package without query, fragment or escapes")

    def test_duplicate_channel_is_rejected(self):
        self.lock["environments"]["default"]["channels"].append({"url": "https://packages.example.invalid/channel"})
        self.assert_invalid("duplicate channel")

    def test_malformed_yaml_is_secret_safe(self):
        self.lock_path.write_text(f'bad: ["https://user:{SECRET_MARKER}@example.invalid/"\n', encoding="utf-8")
        self.assert_invalid("lock YAML: malformed or unsupported document at line", rewrite=False)

    def test_malformed_toml_is_secret_safe(self):
        self.manifest_path.write_text(f'bad = "https://user:{SECRET_MARKER}@example.invalid/\n', encoding="utf-8")
        self.assert_invalid("manifest TOML: malformed document", rewrite=False)

    def test_duplicate_yaml_key_is_rejected(self):
        self.lock_path.write_text("version: 7\nversion: 7\n", encoding="utf-8")
        self.assert_invalid("lock YAML: duplicate mapping key at line 2", rewrite=False)

    def test_nested_duplicate_yaml_key_is_rejected(self):
        self.lock_path.write_text("outer:\n  nested: 1\n  nested: 2\n", encoding="utf-8")
        self.assert_invalid("duplicate mapping key at line 3", rewrite=False)

    def test_nonstring_yaml_key_is_rejected(self):
        self.lock_path.write_text("1: value\n", encoding="utf-8")
        self.assert_invalid("mapping keys must be strings", rewrite=False)

    def test_yaml_anchor_is_rejected(self):
        self.lock_path.write_text("item: &example {}\n", encoding="utf-8")
        self.assert_invalid("anchors and aliases are unsupported", rewrite=False)

    def test_yaml_alias_is_rejected_before_resolution(self):
        self.lock_path.write_text("*missing\n", encoding="utf-8")
        self.assert_invalid("anchors and aliases are unsupported", rewrite=False)

    def test_explicit_standard_yaml_tag_is_rejected(self):
        self.lock_path.write_text("!!map {}\n", encoding="utf-8")
        self.assert_invalid("explicit YAML tags are unsupported", rewrite=False)

    def test_unknown_yaml_tag_is_secret_safe(self):
        self.lock_path.write_text(f"!{SECRET_MARKER} {{}}\n", encoding="utf-8")
        self.assert_invalid("explicit YAML tags are unsupported", rewrite=False)

    def test_multiple_yaml_documents_are_rejected(self):
        self.lock_path.write_text("---\n{}\n---\n{}\n", encoding="utf-8")
        self.assert_invalid("lock YAML: malformed or unsupported document", rewrite=False)

    def test_scalar_yaml_root_is_rejected(self):
        self.lock_path.write_text("42\n", encoding="utf-8")
        self.assert_invalid("lock: expected a mapping", rewrite=False)

    def test_invalid_utf8_lock_is_rejected(self):
        self.lock_path.write_bytes(b"\xff")
        self.assert_invalid("lock input: cannot read a UTF-8 input", rewrite=False)

    def test_invalid_utf8_manifest_is_rejected(self):
        self.manifest_path.write_bytes(b"\xff")
        self.assert_invalid("manifest input: cannot read a UTF-8 input", rewrite=False)

    def test_missing_manifest_path_is_secret_safe(self):
        self.manifest_path = self.root / SECRET_MARKER
        self.assert_invalid("manifest input: cannot read a UTF-8 input", rewrite=False)

    def test_missing_lock_path_is_secret_safe(self):
        self.lock_path = self.root / SECRET_MARKER
        self.assert_invalid("lock input: cannot read a UTF-8 input", rewrite=False)

    def test_directory_input_is_rejected(self):
        self.lock_path = self.root
        self.assert_invalid("lock input: cannot read a UTF-8 input", rewrite=False)

    def test_cli_requires_explicit_mode(self):
        code, stdout, stderr = self.invoke([])
        self.assertEqual((code, stdout), (2, ""))
        self.assertEqual(stderr, "dependency lock: invalid command line; use --help\n")

    def test_self_test_also_requires_explicit_mode(self):
        code, stdout, stderr = self.invoke(["--self-test"])
        self.assertEqual((code, stdout), (2, ""))
        self.assertEqual(stderr, "dependency lock: invalid command line; use --help\n")

    def test_unknown_cli_mode_is_secret_safe(self):
        code, stdout, stderr = self.invoke(["--mode", SECRET_MARKER])
        self.assertEqual((code, stdout), (2, ""))
        self.assertEqual(stderr, "dependency lock: invalid command line; use --help\n")

    def test_unknown_cli_option_is_secret_safe(self):
        code, stdout, stderr = self.invoke(["--mode", "baseline", "--" + SECRET_MARKER])
        self.assertEqual((code, stdout), (2, ""))
        self.assertEqual(stderr, "dependency lock: invalid command line; use --help\n")

    def test_cli_help_is_successful_and_describes_mode(self):
        code, stdout, stderr = self.invoke(["--help"])
        self.assertEqual((code, stderr), (0, ""))
        self.assertIn("--mode {baseline}", stdout)
        self.assertIn("--self-test", stdout)

    def test_yaml_depth_boundary(self):
        for depth in (63, 64):
            with self.subTest(depth=depth):
                # N-1 sequence containers plus one scalar have depth N.
                data = "[" * (depth - 1) + "0" + "]" * (depth - 1)
                parsed = yaml.load(data, Loader=self.checker.StrictLoader)
                for _ in range(depth - 1):
                    parsed = parsed[0]
                self.assertEqual(parsed, 0)
        self.lock_path.write_text("[" * 64 + "0" + "]" * 64, encoding="utf-8")
        self.assert_invalid("document exceeds supported structural limits", rewrite=False)

    def test_yaml_node_boundary(self):
        for nodes in (99_999, 100_000):
            with self.subTest(nodes=nodes):
                data = "- 0\n" * (nodes - 1)
                parsed = yaml.load(data, Loader=self.checker.StrictLoader)
                self.assertEqual(len(parsed), nodes - 1)
        self.lock_path.write_text("- 0\n" * 100_000, encoding="utf-8")
        self.assert_invalid("document exceeds supported structural limits", rewrite=False)

    def test_input_byte_boundary(self):
        for size in (8 * 1024 * 1024 - 1, 8 * 1024 * 1024):
            with self.subTest(size=size):
                self.lock_path.write_bytes(b"x" * size)
                text = self.checker.read_text(self.lock_path, "lock input")
                self.assertEqual(len(text), size)
        self.lock_path.write_bytes(b"x" * (8 * 1024 * 1024 + 1))
        self.assert_invalid("lock input: input exceeds 8 MiB", rewrite=False)

    def test_manifest_byte_limit_is_enforced(self):
        self.manifest_path.write_bytes(b"x" * (8 * 1024 * 1024 + 1))
        self.assert_invalid("manifest input: input exceeds 8 MiB", rewrite=False)


def run(checker) -> int:
    """Return nonzero for any failure, error, skip or incomplete execution."""
    bound = type("DependencyLockTests", (DependencyLockTests,), {"checker": checker})
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(bound)
    expected = suite.countTestCases()
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
    complete = result.testsRun == expected and expected > 0
    unqualified = result.skipped or result.expectedFailures or result.unexpectedSuccesses
    if not result.wasSuccessful() or not complete or unqualified:
        print("dependency lock self-test: FAIL", file=sys.stderr)
        return 1
    print(f"dependency lock self-test: PASS ({result.testsRun} tests; zero skips)")
    return 0


if __name__ == "__main__":
    raise SystemExit("Run check_dependency_lock.py --mode baseline --self-test")
