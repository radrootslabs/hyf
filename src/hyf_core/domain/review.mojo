from std.collections import List


@fieldwise_init
struct Clarification(Copyable, Movable):
    var field: String
    var reason: String


@fieldwise_init
struct ReviewState(Copyable, Movable):
    var required: Bool
    var clarifications: List[Clarification]


def review_clear() -> ReviewState:
    return ReviewState(required=False, clarifications=List[Clarification]())


def review_required(field: String, reason: String) raises -> ReviewState:
    if field.strip() == "" or reason.strip() == "":
        raise Error("clarification requires field and reason")
    var clarifications = List[Clarification]()
    clarifications.append(Clarification(field=String(field), reason=String(reason)))
    return ReviewState(required=True, clarifications=clarifications^)


def review_add(state: ReviewState, field: String, reason: String) raises -> ReviewState:
    if field.strip() == "" or reason.strip() == "":
        raise Error("clarification requires field and reason")
    var clarifications = List[Clarification]()
    for existing in state.clarifications:
        clarifications.append(existing.copy())
    clarifications.append(Clarification(field=String(field), reason=String(reason)))
    return ReviewState(required=True, clarifications=clarifications^)
