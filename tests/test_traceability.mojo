import std.os
from std.collections import List
from std.pathlib import Path, _dir_of_current_file
from std.tempfile import TemporaryDirectory
from std.testing import TestSuite, assert_equal, assert_true
from json import loads

from fixture_validator import (
    FixtureValidationIssue,
    validate_requirement_traceability,
    validate_step_states,
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


def test_step_state_contract_is_valid_and_rejects_corruption() raises:
    var path = _dir_of_current_file() / "requirements" / "hyf_v1_jev.step_states.json"
    assert_equal(len(validate_step_states(path.__fspath__())), 0)

    with TemporaryDirectory() as temp_dir:
        var base = Path(temp_dir)
        _write(
            base / "states.json",
            '{"states":["PASSED","PASSED","NOT_RUN","NOT_APPLICABLE"],'
            '"passed_requires_executed_evidence":true,"rules":["x"]}',
        )
        assert_true(len(validate_step_states((base / "states.json").__fspath__())) > 0)
    with TemporaryDirectory() as temp_dir:
        var base = Path(temp_dir)
        _write(
            base / "states.json",
            '{"states":["PASSED","NOT_RUN","NOT_APPLICABLE"],'
            '"passed_requires_executed_evidence":false,"rules":["x"]}',
        )
        assert_true(len(validate_step_states((base / "states.json").__fspath__())) > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from fixture_validator import validate_requirement_traceability as _vrt


def test_requirement_and_fixture_closure_audit() raises:
    var root = _dir_of_current_file()
    var registry = loads(
        (root / "requirements" / "hyf_v1_jev.requirements.json").read_text()
    )
    var steps = loads(
        (root / "requirements" / "hyf_v1_jev.steps.json").read_text()
    )
    var step_ids = List[String]()
    for step in steps["steps"].array_items():
        step_ids.append(step["id"].string_value())
    assert_equal(len(step_ids), 138)
    var covered = 0
    for requirement in registry["requirements"].array_items():
        assert_true(len(requirement["implementation_steps"].array_items()) > 0)
        covered += 1
    assert_equal(covered, 85)

    var manifest = loads(
        (root / "fixtures" / "hyf_v1_jev" / "manifest.json").read_text()
    )
    var planned = 0
    for entry in manifest["cases"].array_items():
        var doc = loads(
            (root / "fixtures" / "hyf_v1_jev" / entry["path"].string_value())
            .read_text()
        )
        var found_step = False
        for known in step_ids:
            if known == entry["required_from_step"].string_value():
                found_step = True
        assert_true(found_step)
        assert_equal(doc["implementation_status"].string_value(), "planned")
        planned += 1
    assert_equal(planned, 116)
