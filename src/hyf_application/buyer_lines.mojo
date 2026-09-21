from std.collections import List


@fieldwise_init
struct DemandLineDraft(Copyable, Movable):
    var line_id: String
    var product_phrase: String
    var quantity_state: String


def discover_demand_lines(product_phrases: List[String]) raises -> List[DemandLineDraft]:
    var lines = List[DemandLineDraft]()
    var index = 1
    for phrase in product_phrases:
        if String(phrase).strip().byte_length() == 0:
            continue
        lines.append(
            DemandLineDraft(
                line_id="line-" + String(index),
                product_phrase=String(phrase),
                quantity_state="unknown",
            )
        )
        index += 1
    return lines^
