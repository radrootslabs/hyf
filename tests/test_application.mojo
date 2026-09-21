from std.testing import TestSuite, assert_true, assert_equal, assert_raises

from hyf_application.orchestration import (
    application_layer_owns_business_state,
    application_layer_uses_transport_types,
    operation_is_supported,
    supported_operations,
)


def test_application_layer_is_transport_independent() raises:
    assert_equal(len(supported_operations()), 3)
    assert_true(operation_is_supported("farm_update.interpret"))
    assert_true(operation_is_supported("buyer_request.match"))
    assert_true(not operation_is_supported("query_rewrite"))
    assert_true(not application_layer_uses_transport_types())
    assert_true(not application_layer_owns_business_state())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_application.context import (
    context_is_trusted_host_supplied,
    interpretation_source,
    source_text_is_data_not_instruction,
)


def test_interpretation_source_context_validation() raises:
    var source = interpretation_source(
        "farm-source-1", "r1", "Got about 80 lb of Roma tomatoes.",
        "2026-09-21T09:00:00-07:00", "America/Vancouver", "farm-1", "farm-1",
    )
    assert_equal(source.revision, "r1")
    assert_true(context_is_trusted_host_supplied())
    assert_true(source_text_is_data_not_instruction())
    with assert_raises():
        _ = interpretation_source("", "r1", "x", "t", "z", "a", "f")
    with assert_raises():
        _ = interpretation_source("s", "r1", "x", "t", "", "a", "f")


from hyf_application.farm_status import (
    interpret_product_statuses,
    status_is_confirmed_inventory,
    status_is_forecast,
)


def test_product_specific_supply_status_per_crop() raises:
    var products = List[String]()
    products.append("roma tomatoes")
    products.append("basil")
    var statuses = interpret_product_statuses(products, "offered")
    assert_equal(len(statuses), 2)
    assert_equal(statuses[0].product_phrase, "roma tomatoes")
    assert_equal(statuses[1].product_phrase, "basil")
    assert_true(not status_is_confirmed_inventory(statuses[0].status))
    var forecast = interpret_product_statuses(products, "forecast")
    assert_true(status_is_forecast(forecast[0].status))
    var unknown = interpret_product_statuses(products, "probably")
    assert_equal(unknown[0].status, "unclear")


from hyf_application.farm_quantity import (
    ProductQuantityAssociation,
    associate_quantity,
    reported_quantity_is_unreserved_stock,
)


def test_quantity_association_per_product_without_swap() raises:
    var tomatoes = associate_quantity("roma tomatoes", 80, 0, "lb", "approximate")
    var basil = associate_quantity("basil", 0, 0, "bunch", "exact")
    assert_equal(tomatoes.product_phrase, "roma tomatoes")
    assert_equal(tomatoes.quantity_value, 80)
    assert_equal(tomatoes.qualifier, "approximate")
    assert_equal(basil.product_phrase, "basil")
    assert_true(tomatoes.quantity_value != basil.quantity_value)
    assert_true(not reported_quantity_is_unreserved_stock())
    with assert_raises():
        _ = associate_quantity("", 1, 0, "kg", "exact")


from hyf_application.farm_changes import (
    interpret_update_change,
    interpret_update_operation,
    operation_is_proposal,
)


def test_supply_update_operation_semantics() raises:
    assert_equal(interpret_update_operation("another"), "addition")
    assert_equal(interpret_update_operation("left"), "remaining")
    assert_equal(interpret_update_operation("total"), "replacement")
    assert_equal(interpret_update_operation("sold out"), "withdrawal")
    assert_equal(interpret_update_operation("actually"), "correction")
    assert_equal(interpret_update_operation("maybe"), "unresolved")
    var addition = interpret_update_change("another", "listing", Optional[String]("b1"))
    assert_equal(addition.operation, "addition")
    var ambiguous = interpret_update_change("sold out", "listing", None)
    assert_equal(ambiguous.operation, "unresolved")
    assert_true(operation_is_proposal())


from hyf_application.farm_targets import resolve_change_target


def test_authorized_change_target_resolution() raises:
    var authorized = List[String]()
    authorized.append("b1")
    var resolved = resolve_change_target("withdrawal", Optional[String]("b1"), authorized)
    assert_equal(resolved.operation, "withdrawal")
    assert_equal(resolved.target_id.value(), "b1")
    var unauthorized = resolve_change_target("withdrawal", Optional[String]("b9"), authorized)
    assert_equal(unauthorized.operation, "unresolved")
    assert_true(unauthorized.unresolved)
    var ambiguous = resolve_change_target("withdrawal", None, authorized)
    assert_equal(ambiguous.operation, "unresolved")


from hyf_application.farm_fulfillment import interpret_fulfillment
from hyf_core.domain.price import price_is_known
from hyf_core.domain.supply_change import ProposedSupplyChange
from hyf_core.domain.time import date_only


def test_farm_fulfillment_and_timing_claims() raises:
    var monday = date_only(2026, 9, 21)
    var delivery = interpret_fulfillment("delivery", "Friday", monday, "America/Vancouver")
    assert_equal(delivery.resolved_date, "2026-9-25")
    assert_equal(delivery.ambiguity, "none")
    assert_true(not delivery.area_verified)
    var no_zone = interpret_fulfillment("delivery", "Friday", monday, "")
    assert_equal(no_zone.ambiguity, "missing_zone")
    var none = interpret_fulfillment("pickup", "", monday, "America/Vancouver")
    assert_equal(none.window_expression, "")


from hyf_application.farm_review_output import (
    ambiguous_withdrawal_blocks_apply,
    assemble_farm_output,
    missing_optional_price_blocks_draft,
)
from hyf_core.domain.execution import execution_meta
from hyf_core.domain.review import review_required


def test_farm_review_output_is_proposal_only() raises:
    var products = List[String]()
    products.append("roma tomatoes")
    var statuses = interpret_product_statuses(products, "offered")
    var changes = List[ProposedSupplyChange]()
    var review = review_required("withdrawal.target", "ambiguous_target")
    var execution = execution_meta("complete", 0, None, None, None)
    var output = assemble_farm_output(statuses, changes, review, execution)
    assert_equal(len(output.claims), 1)
    assert_true(output.review.required)
    assert_true(output.original_source_preserved)
    assert_equal(output.hyf_business_writes, 0)
    assert_true(not missing_optional_price_blocks_draft())
    assert_true(ambiguous_withdrawal_blocks_apply())


from hyf_application.farm_clarification import (
    apply_farm_clarification,
    clarification_overwrites_original,
    farm_clarification_is_stale,
)


def test_farm_clarification_is_revisioned_new_evidence() raises:
    var refined = apply_farm_clarification(
        "80", "quantity.unreserved", "farm-source-1", "r2",
        "60 lb unreserved", "60",
    )
    assert_equal(refined.value.value(), "60")
    assert_equal(refined.method, "clarification")
    assert_true(not clarification_overwrites_original())
    assert_true(
        not farm_clarification_is_stale(
            "quantity.unreserved", "farm-source-1", "r2", "60 lb", "r2"
        )
    )
    assert_true(
        farm_clarification_is_stale(
            "quantity.unreserved", "farm-source-1", "r2", "60 lb", "r3"
        )
    )


from hyf_application.farm_failure import (
    farm_inference_degraded,
    farm_inference_failure,
    inference_failure_confirms_stock,
)


def test_farm_inference_failure_never_confirms_stock() raises:
    var failed = farm_inference_failure("provider_timeout")
    assert_equal(failed.status, "failed")
    assert_equal(failed.confirmed_claims, 0)
    assert_equal(failed.unresolved_claims, 1)
    var degraded = farm_inference_degraded("provider_degraded")
    assert_equal(degraded.status, "degraded")
    assert_true(not inference_failure_confirms_stock())
    with assert_raises():
        _ = farm_inference_failure("")


from hyf_application.buyer_lines import DemandLineDraft, discover_demand_lines


def test_buyer_discovers_multiple_demand_lines() raises:
    var phrases = List[String]()
    phrases.append("tomatoes")
    phrases.append("basil")
    var lines = discover_demand_lines(phrases)
    assert_equal(len(lines), 2)
    assert_equal(lines[0].product_phrase, "tomatoes")
    assert_equal(lines[1].product_phrase, "basil")
    assert_equal(lines[0].line_id, "line-1")


from hyf_application.buyer_conditions import (
    delivery_exclusion_means_pickup,
    interpret_buyer_condition,
    interpret_condition_strength,
    missing_information_is_prohibition,
)
from std.collections import Optional


def test_buyer_condition_strength_and_negation() raises:
    assert_equal(interpret_condition_strength("required"), "mandatory")
    assert_equal(interpret_condition_strength("ideally"), "preferred")
    assert_equal(interpret_condition_strength("not"), "excluded")
    assert_equal(interpret_condition_strength("fine"), "permitted")
    var required = interpret_buyer_condition("fulfillment", "required", Optional[String]("delivery"))
    assert_equal(required.strength, "mandatory")
    var excluded = interpret_buyer_condition("fulfillment", "not", Optional[String]("pickup"))
    assert_equal(excluded.strength, "excluded")
    assert_true(not delivery_exclusion_means_pickup())
    assert_true(not missing_information_is_prohibition())


from hyf_application.buyer_normalization import (
    normalize_buyer_price,
    normalize_buyer_quantity,
    unknown_price_is_free,
    unsupported_conversion_is_zero,
)


def test_buyer_quantity_and_price_normalization() raises:
    var quantity = normalize_buyer_quantity(25, 0, "kg", "exact")
    assert_equal(quantity.value, 25)
    assert_equal(quantity.dimension, "mass")
    var price = normalize_buyer_price(0, 2, "", "per_unit")
    assert_true(not price_is_known(price))
    assert_true(not unknown_price_is_free())
    assert_true(not unsupported_conversion_is_zero())


from hyf_application.buyer_contradictions import (
    contradictions_are_visible,
    detect_contradictions,
)
from hyf_core.domain.demand import Condition, condition


def test_buyer_contradiction_detection() raises:
    var conditions = List[Condition]()
    conditions.append(condition("fulfillment", "mandatory", Optional[String]("delivery")))
    conditions.append(condition("fulfillment", "excluded", Optional[String]("delivery")))
    var contradictions = detect_contradictions(conditions)
    assert_equal(len(contradictions), 1)
    assert_true(contradictions_are_visible())

    var clean = List[Condition]()
    clean.append(condition("fulfillment", "mandatory", Optional[String]("delivery")))
    clean.append(condition("fulfillment", "excluded", Optional[String]("pickup")))
    assert_equal(len(detect_contradictions(clean)), 0)


from hyf_application.buyer_needs import (
    BuyerNeedOutput,
    assemble_buyer_need,
    buyer_need_creates_order,
    needs_reparse_rewritten_text,
)
from hyf_core.domain.demand import DemandLine, demand_line
from hyf_core.domain.execution import execution_meta
from hyf_core.domain.product import resolved_product
from hyf_core.domain.review import review_clear


def test_assemble_reviewable_typed_buyer_need() raises:
    var tomatoes = resolved_product("tomatoes", "tomato")
    var conditions = List[Condition]()
    conditions.append(condition("fulfillment", "mandatory", Optional[String]("delivery")))
    var lines = List[DemandLine]()
    lines.append(demand_line("l1", tomatoes, "known", 25, 0, conditions))
    var output = assemble_buyer_need(
        lines, review_clear(), execution_meta("complete", 0, None, None, None)
    )
    assert_equal(len(output.demand_lines), 1)
    assert_true(not needs_reparse_rewritten_text())
    assert_true(not buyer_need_creates_order())
    with assert_raises():
        _ = assemble_buyer_need(
            List[DemandLine](), review_clear(), execution_meta("complete", 0, None, None, None)
        )


from hyf_application.buyer_failure import (
    buyer_failure_means_unavailable_supply,
    buyer_inference_degraded,
    buyer_inference_failure,
)


def test_buyer_inference_failure_is_not_market_absence() raises:
    var failed = buyer_inference_failure("provider_timeout")
    assert_equal(failed.status, "failed")
    assert_equal(failed.resolved_lines, 0)
    var degraded = buyer_inference_degraded("provider_degraded")
    assert_equal(degraded.status, "degraded")
    assert_true(not buyer_failure_means_unavailable_supply())


from hyf_application.match_input import (
    caller_name_is_authentication,
    validate_match_scope,
    validate_supplied_lots,
)


def test_match_input_scope_and_lot_validation() raises:
    validate_match_scope("tenant-1", "tenant-1")
    with assert_raises():
        validate_match_scope("tenant-1", "tenant-2")
    with assert_raises():
        validate_match_scope("", "tenant-1")
    var keys = List[String]()
    keys.append("lot-1@l1")
    keys.append("lot-2@l1")
    assert_equal(len(validate_supplied_lots(keys)), 2)
    var dupes = List[String]()
    dupes.append("lot-1@l1")
    dupes.append("lot-1@l1")
    with assert_raises():
        _ = validate_supplied_lots(dupes)
    assert_true(not caller_name_is_authentication())


from hyf_application.match_index import (
    duplicate_records_double_stock,
    index_supplied_lots,
)


def test_index_supplied_lots_rejects_duplicates_and_conflicts() raises:
    var ids = List[String]()
    ids.append("lot-1")
    ids.append("lot-2")
    var revisions = List[String]()
    revisions.append("l1")
    revisions.append("l1")
    assert_equal(len(index_supplied_lots(ids, revisions)), 2)

    var dup_ids = List[String]()
    dup_ids.append("lot-1")
    dup_ids.append("lot-1")
    var dup_revs = List[String]()
    dup_revs.append("l1")
    dup_revs.append("l1")
    with assert_raises():
        _ = index_supplied_lots(dup_ids, dup_revs)

    var conflict_ids = List[String]()
    conflict_ids.append("lot-1")
    conflict_ids.append("lot-1")
    var conflict_revs = List[String]()
    conflict_revs.append("l1")
    conflict_revs.append("l2")
    with assert_raises():
        _ = index_supplied_lots(conflict_ids, conflict_revs)
    assert_true(not duplicate_records_double_stock())


from hyf_application.match_checks import (
    check_product,
    semantic_score_can_rescue_product,
)
from hyf_core.domain.product import resolved_product, unresolved_product


def test_product_and_substitution_check() raises:
    var tomato = resolved_product("tomatoes", "tomato")
    var roma = resolved_product("roma tomatoes", "tomato")
    pass_check = check_product(tomato, roma, False)
    assert_equal(pass_check.result, "pass")
    var carrot = resolved_product("carrots", "carrot")
    fail_check = check_product(tomato, carrot, False)
    assert_equal(fail_check.result, "fail")
    assert_equal(fail_check.reason, "product_mismatch")
    var substitution = check_product(tomato, carrot, True)
    assert_equal(substitution.result, "unknown")
    var unknown = check_product(unresolved_product("mystery"), roma, False)
    assert_equal(unknown.result, "unknown")
    assert_true(not semantic_score_can_rescue_product())


from hyf_application.match_checks import (
    check_required_attributes,
    model_confidence_verifies_certification,
)


def test_grade_and_required_attribute_checks() raises:
    var required = List[String]()
    required.append("organic")
    var verified = List[String]()
    verified.append("organic")
    assert_equal(check_required_attributes(required, verified).result, "pass")
    assert_equal(check_required_attributes(required, List[String]()).result, "unknown")
    assert_equal(check_required_attributes(List[String](), verified).result, "pass")
    assert_true(not model_confidence_verifies_certification())


from hyf_application.match_checks import (
    check_area,
    check_fulfillment,
    delivery_mention_verifies_area,
)


def test_fulfillment_method_and_area_checks() raises:
    assert_equal(check_fulfillment("delivery", "delivery").result, "pass")
    assert_equal(check_fulfillment("delivery", "pickup").result, "fail")
    assert_equal(check_fulfillment("delivery", "").result, "unknown")
    assert_equal(check_fulfillment("", "pickup").result, "pass")
    assert_equal(check_area("Vancouver", "").result, "unknown")
    assert_equal(check_area("", "").result, "pass")
    assert_true(not delivery_mention_verifies_area())


from hyf_application.match_checks import (
    check_availability,
    check_window,
    weekend_similarity_satisfies_specific_window,
)


def test_availability_and_window_checks() raises:
    assert_equal(check_availability("known").result, "pass")
    assert_equal(check_availability("unknown").result, "unknown")
    assert_equal(check_window("2026-09-25", "2026-09-25", "2026-09-25", "2026-09-25").result, "pass")
    assert_equal(check_window("2026-09-25", "2026-09-25", "2026-09-27", "2026-09-27").result, "fail")
    assert_equal(check_window("2026-09-25", "2026-09-25", "", "").result, "unknown")
    assert_equal(check_window("", "", "", "").result, "pass")
    assert_true(not weekend_similarity_satisfies_specific_window())


from hyf_application.match_checks import check_price
from hyf_core.domain.price import known_price as _known_price, unknown_price as _unknown_price


def test_applicable_price_and_minimum_order_checks() raises:
    var ceiling = _known_price(500, 2, "CAD", "per_unit")
    assert_equal(check_price(ceiling, _known_price(450, 2, "CAD", "per_unit")).result, "pass")
    assert_equal(check_price(ceiling, _known_price(550, 2, "CAD", "per_unit")).result, "fail")
    assert_equal(check_price(ceiling, _unknown_price()).result, "unknown")
    assert_equal(check_price(_unknown_price(), _known_price(1, 2, "CAD", "per_unit")).result, "pass")


from hyf_application.match_checks import check_quantity
from hyf_core.domain.quantity import new_quantity


def test_per_lot_quantity_feasibility() raises:
    var required = new_quantity(50, 0, "kg", "mass", "exact")
    var enough = new_quantity(50, 0, "kg", "mass", "exact")
    var short = new_quantity(30, 0, "kg", "mass", "exact")
    assert_equal(check_quantity(required, enough, True, False).result, "pass")
    assert_equal(check_quantity(required, short, True, False).result, "fail")
    assert_equal(check_quantity(required, short, True, True).result, "pass")
    assert_equal(check_quantity(required, short, False, False).result, "unknown")


from hyf_application.match_checks import (
    compose_applicable_checks,
    scores_affect_feasibility,
)
from hyf_core.domain.eligibility import ConstraintAssessment, constraint_assessment


def test_compose_applicable_checks_before_ranking() raises:
    var checks = List[ConstraintAssessment]()
    checks.append(constraint_assessment("product", "pass", True, "product_match"))
    checks.append(constraint_assessment("quantity", "fail", True, "quantity_insufficient"))
    checks.append(constraint_assessment("window", "unknown", True, "window_mismatch"))
    assert_equal(compose_applicable_checks(checks), "ineligible")
    var only_unknown = List[ConstraintAssessment]()
    only_unknown.append(constraint_assessment("quantity", "unknown", True, "stock_unknown"))
    assert_equal(compose_applicable_checks(only_unknown), "conditional")
    assert_true(not scores_affect_feasibility())


from hyf_application.match_plan import (
    allocate_single_line,
    group_lots_by_supplier,
    multi_supplier_is_supported,
)
from hyf_core.domain.plan import LotCapacity, MatchPlan, plan_conservation_violations


def test_supplier_grouping_and_bounded_allocation() raises:
    var lots = List[String]()
    lots.append("lot-1")
    lots.append("lot-2")
    var suppliers = List[String]()
    suppliers.append("farm-1")
    suppliers.append("farm-1")
    var grouped = group_lots_by_supplier(lots, suppliers)
    assert_equal(len(grouped), 1)
    assert_equal(grouped[0], "farm-1")

    var capacities = List[LotCapacity]()
    capacities.append(LotCapacity(lot_id="lot-1", revision="l1", value=30, scale=0))
    capacities.append(LotCapacity(lot_id="lot-2", revision="l1", value=40, scale=0))
    var plan = allocate_single_line("p1", "line-1", "farm-1", 50, 0, capacities)
    assert_equal(len(plan.allocations), 2)
    assert_equal(len(plan_conservation_violations(plan, capacities)), 0)
    assert_true(not multi_supplier_is_supported())


from hyf_application.match_plan import PlannerBounds, enforce_plan_bound, planner_bounds


def test_bounded_single_line_allocation() raises:
    var bounds = planner_bounds(10, 3)
    assert_equal(bounds.max_plans, 3)
    enforce_plan_bound(2, bounds)
    with assert_raises():
        enforce_plan_bound(4, bounds)
    with assert_raises():
        _ = planner_bounds(0, 3)


from hyf_application.match_plan import (
    allocate_multiple_lines,
    shared_lot_allows_concurrent_over_allocation,
)


def test_conservation_across_multiple_demand_lines() raises:
    var capacities = List[LotCapacity]()
    capacities.append(LotCapacity(lot_id="lot-1", revision="l1", value=50, scale=0))
    var lines = List[String]()
    lines.append("line-1")
    lines.append("line-2")
    var required = List[Int]()
    required.append(30)
    required.append(30)
    var plan = allocate_multiple_lines("p1", "farm-1", lines, required, capacities)
    # 50 kg lot cannot satisfy two 30 kg lines: total allocated is capped at 50.
    var total = 0
    for entry in plan.allocations:
        total += entry.value
    assert_equal(total, 50)
    assert_equal(len(plan_conservation_violations(plan, capacities)), 0)
    assert_true(not shared_lot_allows_concurrent_over_allocation())


from hyf_application.match_plan import partial_outcome, partial_discloses_deficit


def test_explicit_partial_fulfillment_outcome() raises:
    var full = partial_outcome(50, 50, False)
    assert_true(full.fulfilled)
    assert_equal(full.uncovered_value, 0)
    var partial = partial_outcome(50, 30, True)
    assert_true(not partial.fulfilled)
    assert_equal(partial.uncovered_value, 20)
    assert_true(partial.permitted)
    var disallowed = partial_outcome(50, 30, False)
    assert_true(not disallowed.permitted)
    assert_true(partial_discloses_deficit())


from hyf_application.match_plan import (
    alternative_plans,
    unsupported_mode_means_no_supply,
)


def test_alternative_plans_and_planner_limitations() raises:
    var capacities = List[LotCapacity]()
    capacities.append(LotCapacity(lot_id="lot-1", revision="l1", value=50, scale=0))
    var plans = List[MatchPlan]()
    plans.append(allocate_single_line("p1", "line-1", "farm-1", 25, 0, capacities))
    plans.append(allocate_single_line("p2", "line-1", "farm-1", 30, 0, capacities))
    var unsupported = List[String]()
    unsupported.append("multi_supplier")
    var offer = alternative_plans(plans, unsupported)
    assert_equal(len(offer.plans), 2)
    assert_true(not offer.alternatives_are_simultaneous)
    assert_equal(len(offer.unsupported), 1)
    assert_true(not unsupported_mode_means_no_supply())


from hyf_application.match_semantic import (
    evidence_sufficient,
    gated_semantic_suitability,
    unknown_evidence_is_midpoint_score,
)


def test_semantic_suitability_gated_on_evidence() raises:
    assert_true(evidence_sufficient(2, 1))
    assert_equal(gated_semantic_suitability(3, 2, 1).result, "pass")
    assert_equal(gated_semantic_suitability(3, 0, 1).result, "unknown")
    assert_equal(gated_semantic_suitability(3, 0, 1).reason, "evidence_insufficient")
    assert_true(not unknown_evidence_is_midpoint_score())


from hyf_application.match_semantic import (
    culinary_score_affects_feasibility,
    culinary_use_score,
)
from hyf_assist.evaluator import typed_score


def test_culinary_use_semantic_scoring_gated() raises:
    var answer = typed_score("culinary_fit", 2, 3, 1.0)
    assert_equal(culinary_use_score(answer, 3, 1, 1), 1.0)
    assert_equal(culinary_use_score(typed_score("culinary_fit", 1, 3, 1.0), 3, 1, 1), 0.5)
    with assert_raises():
        _ = culinary_use_score(answer, 3, 0, 1)
    assert_true(not culinary_score_affects_feasibility())


from hyf_application.match_ranking import (
    PreferenceComponent,
    compose_preference,
    preference_component,
    preference_is_success_probability,
    rank_by_preference,
)


def test_versioned_preference_composition_and_stable_ties() raises:
    var components = List[PreferenceComponent]()
    components.append(preference_component("culinary", 1.0, 1.0))
    components.append(preference_component("distance", 0.5, 1.0))
    assert_equal(compose_preference(components), 75)
    assert_true(not preference_is_success_probability())
    var ids = List[String]()
    ids.append("plan-b")
    ids.append("plan-a")
    ids.append("plan-c")
    var scores = List[Int]()
    scores.append(50)
    scores.append(50)
    scores.append(70)
    var ranked = rank_by_preference(ids, scores)
    assert_equal(ranked[0], "plan-c")
    assert_equal(ranked[1], "plan-a")
    assert_equal(ranked[2], "plan-b")


from hyf_application.match_ranking import (
    rank_match_plans,
    ranking_is_order_independent,
)


def test_deterministic_ranking_and_tie_breaks() raises:
    var capacities = List[LotCapacity]()
    capacities.append(LotCapacity(lot_id="lot-1", revision="l1", value=50, scale=0))
    var plans = List[MatchPlan]()
    plans.append(allocate_single_line("plan-b", "line-1", "farm-1", 25, 0, capacities))
    plans.append(allocate_single_line("plan-a", "line-1", "farm-1", 25, 0, capacities))
    var scores = List[Int]()
    scores.append(50)
    scores.append(50)
    var ranked = rank_match_plans(plans, scores)
    assert_equal(ranked[0].plan_id, "plan-a")
    assert_equal(ranked[1].plan_id, "plan-b")
    assert_true(ranking_is_order_independent())


from hyf_application.match_explain import (
    explanation_claims_global_availability,
    explanation_claims_reservation,
    explanation_reveals_private_source,
    match_explanation,
)


def test_evidence_backed_match_explanations() raises:
    var lines = List[String]()
    lines.append("line-1")
    var text = match_explanation("farm-1", lines, "supplied_only")
    assert_true(text.find("farm-1") >= 0)
    assert_true(text.find("line-1") >= 0)
    assert_true(text.find("not a reservation") >= 0)
    assert_true(not explanation_reveals_private_source())
    assert_true(not explanation_claims_reservation())
    assert_true(not explanation_claims_global_availability())


from hyf_application.match_outage import (
    RankingOutcome,
    outage_changes_feasibility,
    ranking_outage,
)


def test_semantic_ranking_failure_preserves_feasibility() raises:
    var outcome = ranking_outage("eligible", "provider_degraded")
    assert_equal(outcome.feasibility, "eligible")
    assert_equal(outcome.advisory, "degraded")
    var conditional = ranking_outage("conditional", "provider_unavailable")
    assert_equal(conditional.feasibility, "conditional")
    assert_true(not outage_changes_feasibility())
    with assert_raises():
        _ = ranking_outage("eligible", "")


from hyf_application.farm_operation import execute_farm_update_interpret
from json import loads as _json_loads


def test_farm_update_operation_returns_proposal_output() raises:
    var input = _json_loads(
        '{"source":{"source_id":"s1","revision":"r1","text":"Got about 80 lb of Roma tomatoes.",'
        '"source_time":"2026-09-21T09:00:00-07:00","timezone":"America/Vancouver",'
        '"actor_id":"farm-1","farm_id":"farm-1"}}'
    )
    var output = execute_farm_update_interpret(input)
    assert_true(output["review"]["required"].bool_value())
    assert_equal(output["execution"]["status"].string_value(), "complete")
    assert_true(output["original_source_preserved"].bool_value())
    with assert_raises():
        _ = execute_farm_update_interpret(_json_loads("{}"))
