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
