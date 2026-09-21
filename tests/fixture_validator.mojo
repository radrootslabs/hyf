from std.collections import List

from std.os.path import exists
from std.pathlib import Path
from json import Value, loads


@fieldwise_init
struct FixtureValidationIssue(Copyable, Movable):
    var case_id: String
    var rule: String
    var detail: String


def registered_fixture_operators() -> List[String]:
    var operators = List[String]()
    operators.append("equals")
    operators.append("absent")
    operators.append("present")
    operators.append("contains")
    operators.append("not_equals")
    return operators^


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _is_registered_operator(
    operator: String, registered: List[String]
) -> Bool:
    for candidate in registered:
        if candidate == operator:
            return True
    return False


def validate_fixture_corpus(
    directory: String,
) raises -> List[FixtureValidationIssue]:
    var issues = List[FixtureValidationIssue]()
    var base = Path(directory)
    var manifest = loads((base / "manifest.json").read_text())
    if not _has_key(manifest, "cases"):
        issues.append(
            FixtureValidationIssue(
                case_id="", rule="missing_cases", detail="manifest has no cases"
            )
        )
        return issues^

    var cases = manifest["cases"].array_items()
    if len(cases) == 0:
        issues.append(
            FixtureValidationIssue(
                case_id="",
                rule="empty_corpus",
                detail="manifest declares no cases",
            )
        )

    var seen = List[String]()
    var registered = registered_fixture_operators()
    for entry in cases:
        var case_id = entry["case_id"].string_value()

        var duplicate = False
        for prior in seen:
            if prior == case_id:
                duplicate = True
        if duplicate:
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="duplicate_case_id",
                    detail="case_id appears more than once",
                )
            )
        seen.append(String(case_id))

        var relative_path = entry["path"].string_value()
        var case_path = base / relative_path
        if not exists(case_path):
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="dangling_path",
                    detail=relative_path,
                )
            )
            continue

        var doc = loads(case_path.read_text())
        if (
            not _has_key(doc, "case_id")
            or doc["case_id"].string_value() != case_id
        ):
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="case_id_mismatch",
                    detail="case_id does not match manifest",
                )
            )
        if (
            not _has_key(doc, "requirements")
            or len(doc["requirements"].array_items()) == 0
        ):
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="empty_requirements",
                    detail="no requirement references",
                )
            )
        if (
            not _has_key(doc, "required_from_step")
            or doc["required_from_step"].string_value() == ""
        ):
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="missing_activation_step",
                    detail="required_from_step is empty",
                )
            )
        elif _has_key(entry, "required_from_step") and (
            doc["required_from_step"].string_value()
            != entry["required_from_step"].string_value()
        ):
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="activation_step_mismatch",
                    detail="required_from_step does not match manifest",
                )
            )
        if not _has_key(doc, "then") or len(doc["then"].array_items()) == 0:
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="empty_expectations",
                    detail="no expected assertions",
                )
            )
        else:
            for assertion in doc["then"].array_items():
                if not _has_key(assertion, "operator"):
                    issues.append(
                        FixtureValidationIssue(
                            case_id=case_id,
                            rule="missing_operator",
                            detail="assertion has no operator",
                        )
                    )
                    continue
                var operator = assertion["operator"].string_value()
                if not _is_registered_operator(operator, registered):
                    issues.append(
                        FixtureValidationIssue(
                            case_id=case_id,
                            rule="unknown_operator",
                            detail=operator,
                        )
                    )
        if not _has_key(doc, "provenance"):
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="missing_provenance",
                    detail="provenance is required",
                )
            )
        if (
            not _has_key(doc, "implementation_status")
            or doc["implementation_status"].string_value() != "planned"
        ):
            issues.append(
                FixtureValidationIssue(
                    case_id=case_id,
                    rule="unexpected_status",
                    detail="new corpus cases must be planned until activated",
                )
            )

    if _has_key(manifest, "raw_files"):
        for raw in manifest["raw_files"].array_items():
            if not exists(base / raw.string_value()):
                issues.append(
                    FixtureValidationIssue(
                        case_id="",
                        rule="dangling_raw",
                        detail=raw.string_value(),
                    )
                )

    return issues^


def validate_requirement_traceability(
    registry_path: String, manifest_path: String, steps_path: String
) raises -> List[FixtureValidationIssue]:
    var issues = List[FixtureValidationIssue]()
    var registry = loads(Path(registry_path).read_text())
    var manifest = loads(Path(manifest_path).read_text())
    var steps = loads(Path(steps_path).read_text())

    var step_ids = List[String]()
    for step in steps["steps"].array_items():
        step_ids.append(step["id"].string_value())

    var case_ids = List[String]()
    for case_entry in manifest["cases"].array_items():
        case_ids.append(case_entry["case_id"].string_value())

    var requirement_ids = List[String]()
    var requirements = registry["requirements"].array_items()
    if len(requirements) == 0:
        issues.append(
            FixtureValidationIssue(
                case_id="", rule="empty_registry", detail="no requirements"
            )
        )
    for requirement in requirements:
        var rid = requirement["id"].string_value()
        var duplicate = False
        for prior in requirement_ids:
            if prior == rid:
                duplicate = True
        if duplicate:
            issues.append(
                FixtureValidationIssue(
                    case_id=rid,
                    rule="duplicate_requirement",
                    detail="duplicate requirement id",
                )
            )
        requirement_ids.append(String(rid))

        var method = requirement["verification_method"].string_value()
        if method == "":
            issues.append(
                FixtureValidationIssue(
                    case_id=rid,
                    rule="missing_verification_method",
                    detail="verification_method is empty",
                )
            )
        var impl_steps = requirement["implementation_steps"].array_items()
        if len(impl_steps) == 0:
            issues.append(
                FixtureValidationIssue(
                    case_id=rid,
                    rule="uncovered_requirement",
                    detail="no implementation steps",
                )
            )
        else:
            for step in impl_steps:
                var sid = step.string_value()
                var found = False
                for known in step_ids:
                    if known == sid:
                        found = True
                if not found:
                    issues.append(
                        FixtureValidationIssue(
                            case_id=rid,
                            rule="unknown_step",
                            detail=sid,
                        )
                    )
        var fixtures = requirement["fixture_ids"].array_items()
        for fixture in fixtures:
            var fid = fixture.string_value()
            var found = False
            for known in case_ids:
                if known == fid:
                    found = True
            if not found:
                issues.append(
                    FixtureValidationIssue(
                        case_id=rid,
                        rule="dangling_fixture",
                        detail=fid,
                    )
                )

    var step_seen = List[String]()
    for step in steps["steps"].array_items():
        var sid = step["id"].string_value()
        var duplicate = False
        for prior in step_seen:
            if prior == sid:
                duplicate = True
        if duplicate:
            issues.append(
                FixtureValidationIssue(
                    case_id=sid, rule="duplicate_step", detail="duplicate step id"
                )
            )
        step_seen.append(String(sid))
        for dependency in step["dependencies"].array_items():
            var did = dependency.string_value()
            var found = False
            for known in step_ids:
                if known == did:
                    found = True
            if not found:
                issues.append(
                    FixtureValidationIssue(
                        case_id=sid,
                        rule="dangling_dependency",
                        detail=did,
                    )
                )

    return issues^
