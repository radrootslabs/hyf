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


from hyf_runtime.clock import (
    Clock,
    advance,
    clock_monotonic_ns,
    clock_wall_epoch_seconds,
    fixed_clock,
    monotonic_elapsed_ns,
    system_monotonic_ns,
    system_wall_epoch_seconds,
)


def test_clock_ports_are_injectable_and_monotonic() raises:
    var start = fixed_clock(1789000000, 1000)
    assert_equal(clock_wall_epoch_seconds(start), 1789000000)
    var end = advance(start, 5000)
    assert_equal(clock_monotonic_ns(end), 6000)
    assert_equal(monotonic_elapsed_ns(start, end), 5000)
    assert_true(system_wall_epoch_seconds() > 1600000000)
    assert_true(system_monotonic_ns() > 0)


from hyf_assist.scripted import scripted_evaluate, scripted_evaluator


def test_scripted_evaluator_is_strict_and_bounded() raises:
    var answers = List[TypedAnswer]()
    answers.append(typed_choice("supply_status", "offered", 1.0))
    var evaluator = scripted_evaluator("jev-1.13.0", answers, 1)
    var response = scripted_evaluate(
        evaluator, SemanticEvaluatorRequest(state="s", question_bundle="qb1")
    )
    assert_equal(response.answers[0].choice, "offered")
    assert_equal(evaluator.call_count, 1)
    with assert_raises():
        _ = scripted_evaluate(
            evaluator, SemanticEvaluatorRequest(state="s", question_bundle="qb1")
        )
    with assert_raises():
        _ = scripted_evaluate(
            evaluator, SemanticEvaluatorRequest(state="", question_bundle="qb1")
        )
