from std.collections import List

from hyf_core.domain.eligibility import ConstraintAssessment, constraint_assessment
from hyf_core.domain.price import Price, price_compare, price_is_known
from hyf_core.domain.product import ProductRef, product_is_resolved, product_matches
from hyf_core.domain.quantity import Quantity, quantity_compare


def check_product(
    need_product: ProductRef, lot_product: ProductRef, substitution_permitted: Bool
) raises -> ConstraintAssessment:
    if not product_is_resolved(need_product) or not product_is_resolved(lot_product):
        return constraint_assessment(
            "product", "unknown", True, "product_unresolved"
        )
    if product_matches(need_product, lot_product):
        return constraint_assessment("product", "pass", True, "product_match")
    if substitution_permitted:
        return constraint_assessment(
            "product", "unknown", True, "substitution_not_permitted"
        )
    return constraint_assessment("product", "fail", True, "product_mismatch")


def semantic_score_can_rescue_product() -> Bool:
    return False


def check_required_attributes(
    required: List[String], verified: List[String]
) raises -> ConstraintAssessment:
    if len(required) == 0:
        return constraint_assessment(
            "attribute", "pass", True, "attribute_optional"
        )
    for attribute in required:
        var found = False
        for known in verified:
            if known == attribute:
                found = True
        if not found:
            return constraint_assessment(
                "attribute", "unknown", True, "attribute_unverified"
            )
    return constraint_assessment("attribute", "pass", True, "attribute_verified")


def model_confidence_verifies_certification() -> Bool:
    return False


def check_fulfillment(
    required_method: String, offered_method: String
) raises -> ConstraintAssessment:
    if String(required_method).strip().byte_length() == 0:
        return constraint_assessment(
            "fulfillment", "pass", True, "fulfillment_optional"
        )
    if String(offered_method).strip().byte_length() == 0:
        return constraint_assessment(
            "fulfillment", "unknown", True, "fulfillment_unknown"
        )
    if required_method == offered_method:
        return constraint_assessment(
            "fulfillment", "pass", True, "fulfillment_match"
        )
    return constraint_assessment(
        "fulfillment", "fail", True, "fulfillment_mismatch"
    )


def check_area(area_required: String, area_known: String) raises -> ConstraintAssessment:
    if String(area_required).strip().byte_length() == 0:
        return constraint_assessment("area", "pass", True, "area_optional")
    if String(area_known).strip().byte_length() == 0:
        return constraint_assessment("area", "unknown", True, "area_unknown")
    return constraint_assessment("area", "pass", True, "area_verified")


def delivery_mention_verifies_area() -> Bool:
    return False


def check_availability(available_state: String) raises -> ConstraintAssessment:
    if available_state == "known":
        return constraint_assessment(
            "availability", "pass", True, "availability_known"
        )
    return constraint_assessment(
        "availability", "unknown", True, "stock_unknown"
    )


def check_window(
    required_start: String,
    required_end: String,
    offered_start: String,
    offered_end: String,
) raises -> ConstraintAssessment:
    if String(required_start).strip().byte_length() == 0:
        return constraint_assessment("window", "pass", True, "window_optional")
    if String(offered_start).strip().byte_length() == 0:
        return constraint_assessment("window", "unknown", True, "window_mismatch")
    if offered_start <= required_end and required_start <= offered_end:
        return constraint_assessment("window", "pass", True, "window_overlap")
    return constraint_assessment("window", "fail", True, "window_mismatch")


def weekend_similarity_satisfies_specific_window() -> Bool:
    return False


def check_price(ceiling: Price, offered: Price) raises -> ConstraintAssessment:
    if not price_is_known(ceiling):
        return constraint_assessment("price", "pass", True, "price_optional")
    if not price_is_known(offered):
        return constraint_assessment("price", "unknown", True, "price_unknown")
    if price_compare(offered, ceiling) <= 0:
        return constraint_assessment("price", "pass", True, "price_within_ceiling")
    return constraint_assessment("price", "fail", True, "price_above_ceiling")


def check_quantity(
    required: Quantity,
    available: Quantity,
    available_known: Bool,
    partial_allowed: Bool,
) raises -> ConstraintAssessment:
    if not available_known:
        return constraint_assessment("quantity", "unknown", True, "stock_unknown")
    if quantity_compare(available, required) >= 0:
        return constraint_assessment("quantity", "pass", True, "quantity_sufficient")
    if partial_allowed:
        return constraint_assessment(
            "quantity", "pass", True, "partial_permitted"
        )
    return constraint_assessment("quantity", "fail", True, "quantity_insufficient")


from hyf_core.domain.eligibility import compose_eligibility


def compose_applicable_checks(checks: List[ConstraintAssessment]) -> String:
    return compose_eligibility(checks)


def scores_affect_feasibility() -> Bool:
    return False
