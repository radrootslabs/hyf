from json import Value, loads

from hyf_assist.questions import Question, QuestionBundle


def _choice_criteria(question: Question) raises -> Value:
    var criteria = loads("{}")
    for choice in question.choices:
        criteria.set(String(choice), Value(None))
    return criteria^


def _score_criteria(question: Question) raises -> Value:
    var criteria = loads("[]")
    for level in question.rubric:
        criteria.append(Value(String(level)))
    return criteria^


def build_jev_request_body(bundle: QuestionBundle, state: String) raises -> Value:
    if state.strip() == "":
        raise Error("jev request requires non-empty state")
    var body = loads("{}")
    body.set("model", Value(String(bundle.model)))
    body.set("state", Value(String(state)))
    var questions = loads("{}")
    for question in bundle.questions:
        var value = loads("{}")
        value.set("type", Value(String(question.kind)))
        value.set("instructions", Value(String(question.instructions)))
        if question.kind == "choice":
            value.set("criteria", _choice_criteria(question))
        elif question.kind == "score":
            value.set("criteria", _score_criteria(question))
        questions.set(String(question.id), value)
    body.set("questions", questions)
    return body^
