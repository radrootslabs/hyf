from std.collections import List

from hyf_assist.evaluator import TypedAnswer


def answer_by_id(answers: List[TypedAnswer], question_id: String) raises -> TypedAnswer:
    for answer in answers:
        if answer.question_id == question_id:
            return answer.copy()
    raise Error("missing provider answer: " + question_id)


def project_choice(answers: List[TypedAnswer], question_id: String) raises -> String:
    var answer = answer_by_id(answers, question_id)
    if answer.kind != "choice":
        raise Error("expected a choice answer for " + question_id)
    return answer.choice


def provider_cannot_supply_trusted_identity() -> Bool:
    return True
