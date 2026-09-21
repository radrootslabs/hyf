import std.os
from std.collections import List
from std.pathlib import Path, _dir_of_current_file
from std.tempfile import TemporaryDirectory
from std.testing import TestSuite, assert_equal, assert_true

from fixture_validator import (
    FixtureValidationIssue,
    validate_requirement_traceability,
)


def _write(path: Path, text: String) raises:
    std.os.makedirs(path.__fspath__(), exist_ok=True)
    path.write_text(text)


def _make_corpus(base: Path, mutation: String) raises:
    var manifest = '{"cases":[{"case_id":"T001"}]}'
    var steps = '{"steps":[{"id":"S001","dependencies":[]}]}'
    var registry = (
        '{"requirements":[{"id":"HYF-TEST-001",'
        '"verification_method":"fixture-schema and traceability checks",'
        '"implementation_steps":["S001"],"fixture_ids":["T001"]}]}'
    )
    if mutation == "duplicate_requirement":
        registry = registry.replace(
            ']}]}',
            ']},{"id":"HYF-TEST-001","verification_method":"x",'
            '"implementation_steps":["S001"],"fixture_ids":["T001"]}]}',
        )
    elif mutation == "unknown_step":
        registry = registry.replace('["S001"]', '["S999"]')
    elif mutation == "dangling_fixture":
        registry = registry.replace('["T001"]', '["MISSING"]')
    elif mutation == "uncovered_requirement":
        registry = registry.replace('"implementation_steps":["S001"]', '"implementation_steps":[]')
    elif mutation == "missing_verification_method":
        registry = registry.replace('"fixture-schema and traceability checks"', '""')
    elif mutation == "dangling_dependency":
        steps = '{"steps":[{"id":"S001","dependencies":["S404"]}]}'
    elif mutation == "duplicate_step":
        steps = (
            '{"steps":[{"id":"S001","dependencies":[]},'
            '{"id":"S001","dependencies":[]}]}'
        )
    _write(base / "manifest.json", manifest)
    _write(base / "steps.json", steps)
    _write(base / "registry.json", registry)


def _validate(base: Path) raises -> List[FixtureValidationIssue]:
    return validate_requirement_traceability(
        (base / "registry.json").__fspath__(),
        (base / "manifest.json").__fspath__(),
        (base / "steps.json").__fspath__(),
    )


def test_requirement_traceability_accepts_registry_and_rejects_dangling() raises:
    var root = _dir_of_current_file()
    assert_equal(
        len(
            validate_requirement_traceability(
                (root / "requirements" / "hyf_v1_jev.requirements.json")
                .__fspath__(),
                (root / "fixtures" / "hyf_v1_jev" / "manifest.json")
                .__fspath__(),
                (root / "requirements" / "hyf_v1_jev.steps.json")
                .__fspath__(),
            )
        ),
        0,
    )

    var mutations = List[String]()
    mutations.append("duplicate_requirement")
    mutations.append("unknown_step")
    mutations.append("dangling_fixture")
    mutations.append("uncovered_requirement")
    mutations.append("missing_verification_method")
    mutations.append("dangling_dependency")
    mutations.append("duplicate_step")
    for mutation in mutations:
        with TemporaryDirectory() as temp_dir:
            var base = Path(temp_dir)
            _make_corpus(base, mutation)
            assert_true(
                len(_validate(base)) > 0,
                "traceability accepted corruption: " + mutation,
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
