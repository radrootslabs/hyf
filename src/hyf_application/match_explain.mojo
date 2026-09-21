from std.collections import List


def match_explanation(
    supplier_id: String, lines_covered: List[String], scope: String
) -> String:
    var covered = ""
    var first = True
    for line in lines_covered:
        if not first:
            covered += ", "
        covered += line
        first = False
    return (
        "Supplier "
        + supplier_id
        + " covers lines ["
        + covered
        + "] within scope "
        + scope
        + ". This is a suggestion within the supplied records, not a reservation."
    )


def explanation_reveals_private_source() -> Bool:
    return False


def explanation_claims_reservation() -> Bool:
    return False


def explanation_claims_global_availability() -> Bool:
    return False
