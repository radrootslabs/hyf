from std.collections import List


@fieldwise_init
struct Question(Copyable, Movable):
    var id: String
    var kind: String
    var instructions: String
    var choices: List[String]
    var rubric: List[String]


@fieldwise_init
struct QuestionBundle(Copyable, Movable):
    var bundle_id: String
    var version: String
    var model: String
    var questions: List[Question]


def _copy_strings(items: List[String]) -> List[String]:
    var copied = List[String]()
    for item in items:
        copied.append(String(item))
    return copied^


def choice_question(id: String, instructions: String, choices: List[String]) raises -> Question:
    if id.strip() == "" or instructions.strip() == "":
        raise Error("choice question requires id and instructions")
    if len(choices) < 2:
        raise Error("choice question requires at least two choices")
    return Question(
        id=String(id), kind="choice", instructions=String(instructions),
        choices=_copy_strings(choices), rubric=List[String](),
    )


def noul_question(id: String, instructions: String) raises -> Question:
    if id.strip() == "" or instructions.strip() == "":
        raise Error("noul question requires id and instructions")
    return Question(
        id=String(id), kind="noul", instructions=String(instructions),
        choices=List[String](), rubric=List[String](),
    )


def score_question(id: String, instructions: String, rubric: List[String]) raises -> Question:
    if id.strip() == "" or instructions.strip() == "":
        raise Error("score question requires id and instructions")
    if len(rubric) < 2:
        raise Error("score question requires at least two rubric levels")
    return Question(
        id=String(id), kind="score", instructions=String(instructions),
        choices=List[String](), rubric=_copy_strings(rubric),
    )


def question_bundle(
    bundle_id: String, version: String, model: String, questions: List[Question]
) raises -> QuestionBundle:
    if bundle_id.strip() == "" or version.strip() == "" or model.strip() == "":
        raise Error("question bundle requires id, version and model")
    if len(questions) == 0:
        raise Error("question bundle must contain at least one question")
    var copied = List[Question]()
    for question in questions:
        copied.append(question.copy())
    return QuestionBundle(
        bundle_id=String(bundle_id), version=String(version),
        model=String(model), questions=copied^,
    )


def bundle_pins_configuration(bundle: QuestionBundle) -> Bool:
    return bundle.version != "" and bundle.model != ""
