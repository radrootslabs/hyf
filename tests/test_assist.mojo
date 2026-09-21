from std.collections import List
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from hyf_assist.questions import Question
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


from hyf_assist.questions import (
    bundle_pins_configuration,
    choice_question,
    noul_question,
    question_bundle,
    score_question,
)


def test_question_bundles_are_versioned_and_validated() raises:
    var choices = List[String]()
    choices.append("offered")
    choices.append("forecast")
    choices.append("unavailable")
    choices.append("unclear")
    var questions = List[Question]()
    questions.append(choice_question("supply_status", "status?", choices))
    questions.append(noul_question("seconds_ok", "seconds permitted?"))
    var rubric = List[String]()
    rubric.append("unsuitable")
    rubric.append("limited")
    rubric.append("suitable")
    questions.append(score_question("culinary_fit", "fit?", rubric))
    var bundle = question_bundle("qb1", "1", "jev-1.13.0", questions)
    assert_true(bundle_pins_configuration(bundle))
    assert_equal(len(bundle.questions), 3)
    var too_few = List[String]()
    too_few.append("only")
    with assert_raises():
        _ = choice_question("x", "y", too_few)
    var one = List[String]()
    one.append("only")
    with assert_raises():
        _ = score_question("s", "i", one)


from hyf_assist.question_plan import (
    QuestionStage,
    independent_questions_share_one_state,
    question_stage,
    stages_are_acyclic,
)


def test_question_stage_planning_dependencies() raises:
    var choices = List[String]()
    choices.append("offered")
    choices.append("unclear")
    var base_questions = List[Question]()
    base_questions.append(choice_question("supply_status", "status?", choices))
    var follow_questions = List[Question]()
    follow_questions.append(noul_question("seconds_ok", "seconds?"))
    var stages = List[QuestionStage]()
    stages.append(question_stage("stage-1", List[String](), base_questions))
    var deps = List[String]()
    deps.append("stage-1")
    stages.append(question_stage("stage-2", deps, follow_questions))
    assert_true(stages_are_acyclic(stages))
    assert_true(independent_questions_share_one_state())

    var cyclic = List[QuestionStage]()
    cyclic.append(question_stage("a", List[String](), base_questions))
    var dep_a = List[String]()
    dep_a.append("b")
    cyclic.append(question_stage("b", dep_a, follow_questions))
    var dep_b = List[String]()
    dep_b.append("a")
    # replace first stage's deps to create a cycle: a depends on b, b depends on a
    var cyclic2 = List[QuestionStage]()
    var a_deps = List[String]()
    a_deps.append("b")
    cyclic2.append(question_stage("a", a_deps, base_questions))
    var b_deps = List[String]()
    b_deps.append("a")
    cyclic2.append(question_stage("b", b_deps, follow_questions))
    assert_true(not stages_are_acyclic(cyclic2))
    with assert_raises():
        _ = question_stage("empty", List[String](), List[Question]())
