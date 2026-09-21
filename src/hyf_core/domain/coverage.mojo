from std.collections import List


@fieldwise_init
struct Coverage(Copyable, Movable):
    var scope: String
    var truncated: Bool
    var evaluated: Int
    var excluded: Int
    var supported_mode: String
    var unsupported: List[String]


def coverage(
    truncated: Bool,
    evaluated: Int,
    excluded: Int,
    supported_mode: String,
    unsupported: List[String],
) raises -> Coverage:
    if evaluated < 0 or excluded < 0:
        raise Error("coverage counts must be non-negative")
    if supported_mode.strip() == "":
        raise Error("coverage requires a supported mode")
    var copied = List[String]()
    for entry in unsupported:
        copied.append(String(entry))
    return Coverage(
        scope="supplied_only",
        truncated=truncated,
        evaluated=evaluated,
        excluded=excluded,
        supported_mode=String(supported_mode),
        unsupported=copied^,
    )


def no_match_is_global_absence() -> Bool:
    return False


def unsupported_is_no_supply() -> Bool:
    return False
