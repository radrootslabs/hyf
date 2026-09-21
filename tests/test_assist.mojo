from std.collections import List
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from hyf_assist.evaluator import (
    DisabledSemanticEvaluator,
    SemanticEvaluatorRequest,
    SemanticEvaluatorResponse,
    TypedAnswer,
    normalize_score,
    typed_choice,
    typed_noul,
    typed_score,
)


def test_evaluator_boundary_is_typed_and_scriptable() raises:
    var answers = List[TypedAnswer]()
    answers.append(typed_choice("supply_status", "offered", 1.0))
    var response = SemanticEvaluatorResponse(model="test-model", answers=answers^)
    assert_equal(response.model, "test-model")
    assert_equal(len(response.answers), 1)
    assert_equal(response.answers[0].kind, "choice")
    assert_equal(response.answers[0].choice, "offered")

    var disabled = DisabledSemanticEvaluator()
    with assert_raises():
        _ = disabled.evaluate(
            SemanticEvaluatorRequest(state="s", question_bundle="q")
        )


def test_typed_answers_and_score_normalization() raises:
    assert_equal(typed_noul("q", 0.5).kind, "noul")
    assert_equal(typed_score("s", 2, 3, 1.0).score, 2)
    assert_equal(normalize_score(typed_score("s", 2, 3, 1.0), 3), 1.0)
    assert_equal(normalize_score(typed_score("s", 1, 3, 1.0), 3), 0.5)
    with assert_raises():
        _ = typed_choice("q", "x", 1.5)
    with assert_raises():
        _ = typed_noul("q", -0.1)
    with assert_raises():
        _ = typed_score("s", 5, 3, 1.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
