from std.collections import List


@fieldwise_init
struct Candidate(Copyable, Movable):
    var kind: String
    var text: String
    var start: Int
    var end: Int


def _is_digit_byte(byte: UInt8) -> Bool:
    return byte >= UInt8(ord("0")) and byte <= UInt8(ord("9"))


def _backward_number_start(text: String, unit_start: Int) -> Int:
    var bytes = text.as_bytes()
    var index = unit_start - 1
    while index >= 0:
        var byte = bytes[index]
        if byte == UInt8(ord(" ")) or byte == UInt8(ord("\t")):
            index -= 1
            continue
        break
    var end = index
    while index >= 0 and _is_digit_byte(bytes[index]):
        index -= 1
    if index == end:
        return -1
    return index + 1


def discover_candidates(
    text: String,
    known_products: List[String],
    known_units: List[String],
    known_dates: List[String],
) -> List[Candidate]:
    var candidates = List[Candidate]()
    var lowered = text.lower()

    for product in known_products:
        if product.strip() == "":
            continue
        var index = lowered.find(product.lower())
        if index >= 0:
            candidates.append(
                Candidate(
                    kind="product",
                    text=String(product),
                    start=index,
                    end=index + product.byte_length(),
                )
            )

    for unit in known_units:
        if unit.strip() == "":
            continue
        var index = lowered.find(unit.lower())
        if index >= 0:
            var number_start = _backward_number_start(text, index)
            if number_start >= 0:
                candidates.append(
                    Candidate(
                        kind="quantity",
                        text=String(
                            text[
                                byte = number_start : index + unit.byte_length()
                            ]
                        ),
                        start=number_start,
                        end=index + unit.byte_length(),
                    )
                )

    for date_word in known_dates:
        if date_word.strip() == "":
            continue
        var index = lowered.find(date_word.lower())
        if index >= 0:
            candidates.append(
                Candidate(
                    kind="date",
                    text=String(date_word),
                    start=index,
                    end=index + date_word.byte_length(),
                )
            )
    return candidates^


def candidate_kinds(candidates: List[Candidate]) -> List[String]:
    var kinds = List[String]()
    for candidate in candidates:
        var seen = False
        for kind in kinds:
            if kind == candidate.kind:
                seen = True
        if not seen:
            kinds.append(String(candidate.kind))
    return kinds^
