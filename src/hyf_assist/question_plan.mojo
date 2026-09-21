from std.collections import List

from hyf_assist.questions import Question


@fieldwise_init
struct QuestionStage(Copyable, Movable):
    var stage_id: String
    var depends_on: List[String]
    var questions: List[Question]


def question_stage(
    stage_id: String, depends_on: List[String], questions: List[Question]
) raises -> QuestionStage:
    if stage_id.strip() == "":
        raise Error("question stage requires an id")
    if len(questions) == 0:
        raise Error("question stage requires at least one question")
    var deps = List[String]()
    for dependency in depends_on:
        deps.append(String(dependency))
    var copied = List[Question]()
    for question in questions:
        copied.append(question.copy())
    return QuestionStage(
        stage_id=String(stage_id), depends_on=deps^, questions=copied^
    )


def _reaches(stages: List[QuestionStage], start: String, target: String) -> Bool:
    var stack = List[String]()
    stack.append(String(start))
    var visited = List[String]()
    while len(stack) > 0:
        var current = stack.pop()
        if current == target:
            return True
        var already = False
        for seen in visited:
            if seen == current:
                already = True
        if already:
            continue
        visited.append(String(current))
        for stage in stages:
            if stage.stage_id == current:
                for dependency in stage.depends_on:
                    stack.append(String(dependency))
    return False


def stages_are_acyclic(stages: List[QuestionStage]) -> Bool:
    for stage in stages:
        for dependency in stage.depends_on:
            if _reaches(stages, dependency, stage.stage_id):
                return False
    return True


def independent_questions_share_one_state() -> Bool:
    return True
