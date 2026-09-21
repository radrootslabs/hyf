from std.collections import List


@fieldwise_init
struct TypedAnswer(Copyable, Movable):
    var question_id: String
    var kind: String
    var choice: String
    var score: Int
    var noul: Float64
    var confidence: Float64


@fieldwise_init
struct SemanticEvaluatorRequest(Copyable, Movable):
    var state: String
    var question_bundle: String


@fieldwise_init
struct SemanticEvaluatorResponse(Copyable, Movable):
    var model: String
    var answers: List[TypedAnswer]


@fieldwise_init
struct DisabledSemanticEvaluator(Copyable, Movable):
    def evaluate(
        self, request: SemanticEvaluatorRequest
    ) raises -> SemanticEvaluatorResponse:
        raise Error("semantic evaluator is disabled")


def typed_choice(
    question_id: String, choice: String, confidence: Float64
) raises -> TypedAnswer:
    if question_id.strip() == "" or choice.strip() == "":
        raise Error("choice answer requires question id and choice")
    if confidence < 0.0 or confidence > 1.0:
        raise Error("choice confidence must be within [0, 1]")
    return TypedAnswer(
        question_id=String(question_id),
        kind="choice",
        choice=String(choice),
        score=0,
        noul=0.0,
        confidence=confidence,
    )


def typed_noul(question_id: String, noul: Float64) raises -> TypedAnswer:
    if noul < 0.0 or noul > 1.0:
        raise Error("noul probability must be within [0, 1]")
    return TypedAnswer(
        question_id=String(question_id),
        kind="noul",
        choice="",
        score=0,
        noul=noul,
        confidence=noul,
    )


def typed_score(
    question_id: String, score: Int, levels: Int, confidence: Float64
) raises -> TypedAnswer:
    if levels < 2:
        raise Error("score rubric requires at least two levels")
    if score < 0 or score >= levels:
        raise Error("score is out of rubric range")
    if confidence < 0.0 or confidence > 1.0:
        raise Error("score confidence must be within [0, 1]")
    return TypedAnswer(
        question_id=String(question_id),
        kind="score",
        choice="",
        score=score,
        noul=0.0,
        confidence=confidence,
    )


def normalize_score(answer: TypedAnswer, levels: Int) raises -> Float64:
    if answer.kind != "score":
        raise Error("normalize_score requires a score answer")
    if levels < 2:
        raise Error("score rubric requires at least two levels")
    if answer.score < 0 or answer.score >= levels:
        raise Error("score is out of rubric range")
    return Float64(answer.score) / Float64(levels - 1)
