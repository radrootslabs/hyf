from std.collections import List

from hyf_assist.evaluator import (
    SemanticEvaluatorRequest,
    SemanticEvaluatorResponse,
    TypedAnswer,
)


@fieldwise_init
struct ScriptedEvaluator(Copyable, Movable):
    var model: String
    var answers: List[TypedAnswer]
    var max_calls: Int
    var call_count: Int


def scripted_evaluator(
    model: String, answers: List[TypedAnswer], max_calls: Int
) raises -> ScriptedEvaluator:
    if model.strip() == "":
        raise Error("scripted evaluator requires a model")
    if max_calls <= 0:
        raise Error("scripted evaluator max_calls must be positive")
    var copied = List[TypedAnswer]()
    for answer in answers:
        copied.append(answer.copy())
    return ScriptedEvaluator(
        model=String(model),
        answers=copied^,
        max_calls=max_calls,
        call_count=0,
    )


def scripted_evaluate(
    mut evaluator: ScriptedEvaluator, request: SemanticEvaluatorRequest
) raises -> SemanticEvaluatorResponse:
    if request.state.strip() == "":
        raise Error("scripted evaluator requires non-empty state")
    if request.question_bundle.strip() == "":
        raise Error("scripted evaluator requires a question bundle")
    if evaluator.call_count >= evaluator.max_calls:
        raise Error("unexpected_scripted_call")
    evaluator.call_count += 1
    var answers = List[TypedAnswer]()
    for answer in evaluator.answers:
        answers.append(answer.copy())
    return SemanticEvaluatorResponse(
        model=String(evaluator.model), answers=answers^
    )
