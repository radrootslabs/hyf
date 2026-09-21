from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from hyf_core.domain.evidence import EvidenceRef
from hyf_core.domain.source import (
    actor_id,
    farm_id,
    lot_id,
    need_id,
    revision,
    source_id,
    trusted_source,
)


def test_source_identity_accepts_valid_and_rejects_empty() raises:
    assert_equal(source_id("s1").value, "s1")
    assert_equal(actor_id("a1").value, "a1")
    assert_equal(farm_id("f1").value, "f1")
    assert_equal(need_id("n1").value, "n1")
    assert_equal(lot_id("l1").value, "l1")
    assert_equal(revision("r1").value, "r1")
    with assert_raises():
        _ = source_id("")
    with assert_raises():
        _ = revision(" r1")
    with assert_raises():
        _ = actor_id("a1 ")


def test_trusted_source_preserves_revision() raises:
    var source = trusted_source("s1", "r1", "a1", "f1")
    assert_equal(source.source_id.value, "s1")
    assert_equal(source.revision.value, "r1")
    assert_equal(source.actor_id.value, "a1")
    assert_equal(source.farm_id.value, "f1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_core.domain.evidence import (
    record_field_evidence,
    selected_text,
    span_evidence,
    span_is_valid,
    validate_span_against_revision,
)


def test_evidence_span_byte_offsets_and_revision() raises:
    var text = "caf\u00e9: 80 lb"
    var evidence = span_evidence("s1", "r1", 7, 12, "span")
    assert_equal(evidence.kind, "span")
    assert_equal(selected_text(text, evidence), "80 lb")
    validate_span_against_revision(text, "r1", evidence)
    assert_true(span_is_valid(text, evidence))

    with assert_raises():
        _ = span_evidence("s1", "r1", 5, 4, "span")


def test_evidence_rejects_out_of_range_and_revision_mismatch() raises:
    var text = "short"
    with assert_raises():
        _ = span_evidence("s1", "r1", -1, 2, "span")
    var beyond = span_evidence("s1", "r1", 0, 99, "span")
    with assert_raises():
        validate_span_against_revision(text, "r1", beyond)
    var good = span_evidence("s1", "r1", 0, 3, "span")
    with assert_raises():
        validate_span_against_revision(text, "r2", good)
    var field = record_field_evidence("s1", "r1", "lot-1", "unreserved_quantity")
    assert_equal(field.kind, "record_field")
    assert_equal(field.record_id.value(), "lot-1")


from hyf_core.domain.field import (
    DecodedField,
    field_is_known,
    field_known_or,
    known_approximate_field,
    known_field,
    unresolved_field,
    validate_field_consistency,
)


def test_field_known_zero_distinct_from_unknown_and_false() raises:
    var zero = known_field("0", "span")
    assert_true(field_is_known(zero))
    assert_equal(field_known_or(zero, "?"), "0")
    var false_value = known_field("false", "model")
    assert_true(field_is_known(false_value))
    var unknown = unresolved_field("span")
    assert_true(not field_is_known(unknown))
    assert_equal(field_known_or(unknown, "?"), "?")
    validate_field_consistency(zero)
    validate_field_consistency(unknown)
    var approximate = known_approximate_field("80", "span")
    assert_equal(approximate.qualifier, "approximate")


from hyf_core.domain.quantity import (
    new_quantity,
    quantity_add,
    quantity_compare,
    quantity_is_negative,
    quantity_rescale,
)


def test_quantity_exact_compare_and_scale() raises:
    var a = new_quantity(8000, 2, "kg", "mass", "exact")
    var b = new_quantity(80, 0, "kg", "mass", "exact")
    assert_equal(quantity_compare(a, b), 0)
    var c = new_quantity(50, 0, "kg", "mass", "exact")
    assert_equal(quantity_compare(c, b), -1)
    assert_equal(quantity_rescale(b, 2).value, 8000)


def test_quantity_add_overflow_and_approximation() raises:
    var approx = new_quantity(80, 0, "lb", "mass", "approximate")
    var exact = new_quantity(5, 0, "lb", "mass", "exact")
    var total = quantity_add(approx, exact)
    assert_equal(total.value, 85)
    assert_equal(total.qualifier, "approximate")
    var huge = new_quantity(9223372036854775807, 0, "kg", "mass", "exact")
    with assert_raises():
        _ = quantity_add(huge, exact)
    var adjustment = new_quantity(-5, 0, "kg", "mass", "exact")
    assert_true(quantity_is_negative(adjustment))


from hyf_core.domain.units import (
    apply_conversion,
    conversion_rule,
    unit_dimension,
)


def test_unit_dimensions_and_exact_mass_conversion() raises:
    assert_equal(unit_dimension("lb"), "mass")
    assert_equal(unit_dimension("ml"), "volume")
    assert_equal(unit_dimension("widget"), "unknown")

    var pounds = new_quantity(80, 0, "lb", "mass", "exact")
    var rule = conversion_rule("lb", "kg", 45359237, 100000000, "test-1")
    var kilograms = apply_conversion(pounds, rule)
    assert_equal(kilograms.unit, "kg")
    assert_equal(kilograms.dimension, "mass")
    assert_equal(kilograms.value, 3628738960)
    assert_equal(kilograms.scale, 8)


def test_unit_conversion_rejects_dimension_mismatch_and_unknown_denominator() raises:
    with assert_raises():
        _ = conversion_rule("lb", "l", 1, 1, "v1")
    with assert_raises():
        _ = conversion_rule("lb", "kg", 1, 3, "v1")
    var pounds = new_quantity(1, 0, "lb", "mass", "exact")
    var kg_rule = conversion_rule("lb", "kg", 45359237, 100000000, "test-1")
    with assert_raises():
        _ = apply_conversion(new_quantity(1, 0, "kg", "mass", "exact"), kg_rule)
    _ = pounds


from hyf_core.domain.pack import apply_pack_conversion, pack_rule


def test_pack_conversion_known_and_rejections() raises:
    var boxes = new_quantity(20, 0, "box", "count", "exact")
    var rule = pack_rule("tomato.roma", "box", "kg", 5, 0, "pack-1")
    var mass = apply_pack_conversion("tomato.roma", boxes, rule)
    assert_equal(mass.value, 100)
    assert_equal(mass.unit, "kg")
    assert_equal(mass.dimension, "mass")

    with assert_raises():
        _ = apply_pack_conversion("carrot", boxes, rule)
    with assert_raises():
        _ = apply_pack_conversion(
            "tomato.roma", new_quantity(1, 0, "kg", "mass", "exact"), rule
        )
    with assert_raises():
        _ = pack_rule("tomato.roma", "box", "mystery", 5, 0, "pack-1")


from hyf_core.domain.units import normalize_quantity_with_rule


def test_normalization_preserves_approximation() raises:
    var approximate = new_quantity(80, 0, "lb", "mass", "approximate")
    var rule = conversion_rule("lb", "kg", 45359237, 100000000, "test-1")
    var normalized = normalize_quantity_with_rule(approximate, rule)
    assert_equal(normalized.qualifier, "approximate")
    assert_equal(normalized.unit, "kg")
    var exact = new_quantity(80, 0, "lb", "mass", "exact")
    assert_equal(normalize_quantity_with_rule(exact, rule).qualifier, "exact")


from hyf_core.domain.price import (
    known_price,
    price_compare,
    price_is_known,
    unknown_price,
)


def test_price_unknown_distinct_from_zero_and_no_fx() raises:
    var unknown = unknown_price()
    assert_true(not price_is_known(unknown))
    assert_equal(unknown.amount, 0)
    var zero = known_price(0, 2, "CAD", "per_unit")
    assert_true(price_is_known(zero))
    var five = known_price(500, 2, "CAD", "per_unit")
    assert_equal(price_compare(five, zero), 1)
    with assert_raises():
        _ = price_compare(five, unknown)
    var usd = known_price(500, 2, "USD", "per_unit")
    with assert_raises():
        _ = price_compare(five, usd)
    with assert_raises():
        _ = known_price(1, 2, "", "per_unit")
    with assert_raises():
        _ = known_price(1, 2, "CAD", "per_kg_approx")


from hyf_core.domain.time import (
    date_only,
    time_context,
    timestamp,
    timestamp_has_zone,
    zoneless_timestamp,
)


def test_time_types_distinguish_source_and_evaluation() raises:
    var source = timestamp(1789000000, "America/Vancouver")
    var ingestion = timestamp(1789000100, "America/Vancouver")
    var replay_later = timestamp(1789900000, "America/Vancouver")
    var context = time_context(source, ingestion, replay_later)
    assert_true(timestamp_has_zone(context.source_time))
    assert_true(timestamp_has_zone(context.evaluation_time))
    assert_true(context.evaluation_time.epoch_seconds > context.source_time.epoch_seconds)
    var d = date_only(2026, 9, 25)
    assert_equal(d.year, 2026)
    assert_equal(d.month, 9)
    assert_equal(d.day, 25)
    var zoneless = zoneless_timestamp(1789000000)
    assert_true(not timestamp_has_zone(zoneless))
    with assert_raises():
        _ = time_context(zoneless, ingestion, replay_later)
    with assert_raises():
        _ = date_only(2026, 13, 1)
    with assert_raises():
        _ = timestamp(1, "")


from hyf_core.normalization.dates import (
    resolve_relative_expression,
    resolve_weekday,
    weekday_index,
)


def test_source_anchored_relative_date_replay() raises:
    var monday = date_only(2026, 9, 21)
    assert_equal(weekday_index(monday), 0)
    var friday = resolve_relative_expression("Friday", monday)
    assert_equal(friday.resolution, "resolved")
    assert_equal(friday.date.year, 2026)
    assert_equal(friday.date.month, 9)
    assert_equal(friday.date.day, 25)
    var same = resolve_weekday(monday, "Monday", "on_or_after")
    assert_equal(same.date.day, 21)
    var next = resolve_weekday(monday, "Monday", "next")
    assert_equal(next.date.day, 28)
    # Replay at a later evaluation time uses the same source reference.
    assert_equal(resolve_relative_expression("Friday", monday).date.day, 25)


from hyf_core.normalization.dates import (
    LocalTimeResolution,
    resolve_local_time,
    window_contains,
)


def test_local_time_ambiguity_and_window_boundaries() raises:
    var offsets = List[Int]()
    offsets.append(-420)
    offsets.append(-480)
    var ambiguous = resolve_local_time(offsets)
    assert_equal(ambiguous.resolution, "unresolved")
    assert_equal(ambiguous.ambiguity, "ambiguous_local")

    var empty = List[Int]()
    assert_equal(resolve_local_time(empty).ambiguity, "missing_zone")

    var single = List[Int]()
    single.append(-420)
    assert_equal(resolve_local_time(single).resolution, "resolved")

    assert_true(window_contains(20717, 20721, "exclusive", 20721) == False)
    assert_true(window_contains(20717, 20721, "inclusive", 20721))
    assert_true(window_contains(20717, 20721, "exclusive", 20720))
    with assert_raises():
        _ = window_contains(1, 2, "half-open", 1)


from hyf_core.domain.freshness import (
    freshness,
    record_recency_implies_harvest_age,
)


def test_freshness_separates_record_harvest_and_verification() raises:
    var value = freshness(5, 240, 60)
    assert_equal(value.record_age_minutes, 5)
    assert_equal(value.harvest_age_minutes, 240)
    assert_equal(value.verification_age_minutes, 60)
    assert_true(not record_recency_implies_harvest_age())
    with assert_raises():
        _ = freshness(-1, 0, 0)


from hyf_core.domain.product import (
    product_is_resolved,
    product_matches,
    resolved_product,
    unresolved_product,
)


def test_product_reference_resolution_and_unknown() raises:
    var tomato = resolved_product("Roma tomatoes", "tomato.roma")
    var other = resolved_product("Roma tomato", "tomato.roma")
    assert_true(product_is_resolved(tomato))
    assert_true(product_matches(tomato, other))
    var unknown = unresolved_product("mystery greens")
    assert_true(not product_is_resolved(unknown))
    assert_true(not product_matches(tomato, unknown))
    with assert_raises():
        _ = resolved_product("x", "")


from hyf_core.domain.supply_claim import (
    claim_confirms_inventory,
    claim_is_forecast,
    supply_claim,
)


def test_supply_claims_are_per_product_and_not_inventory() raises:
    var tomatoes = resolved_product("Roma tomatoes", "tomato.roma")
    var basil = resolved_product("Basil", "basil")
    var tomato_claim = supply_claim("c1", tomatoes, "offered", "known", 80, 0, "lb", "approximate")
    var basil_claim = supply_claim("c2", basil, "unavailable", "unknown", 0, 0, "", "unknown")
    assert_equal(tomato_claim.status, "offered")
    assert_equal(basil_claim.status, "unavailable")
    assert_true(not claim_confirms_inventory(tomato_claim))
    var forecast = supply_claim("c3", basil, "forecast", "unknown", 0, 0, "", "unknown")
    assert_true(claim_is_forecast(forecast))
    assert_true(not claim_is_forecast(tomato_claim))
    with assert_raises():
        _ = supply_claim("c4", tomatoes, "probably", "known", 1, 0, "kg", "exact")


from hyf_core.domain.supply_change import (
    change_expands_to_farm,
    proposed_change,
)


def test_supply_change_operations_and_scoped_withdrawal() raises:
    var addition = proposed_change("listing", Optional[String]("b1"), "addition", None)
    assert_equal(addition.operation, "addition")
    var remaining = proposed_change("listing", Optional[String]("b1"), "remaining", None)
    assert_equal(remaining.operation, "remaining")
    var replacement = proposed_change("listing", Optional[String]("b1"), "replacement", None)
    assert_equal(replacement.operation, "replacement")
    # Ambiguous withdrawal target must not expand to whole-farm stock.
    var ambiguous = proposed_change("listing", None, "withdrawal", None)
    assert_equal(ambiguous.operation, "unresolved")
    assert_true(ambiguous.unresolved)
    assert_true(not change_expands_to_farm(ambiguous))
    var correction = proposed_change("product", None, "correction", None)
    assert_equal(correction.operation, "unresolved")
    with assert_raises():
        _ = proposed_change("galaxy", Optional[String]("x"), "addition", None)


from hyf_core.domain.review import review_add, review_clear, review_required


def test_review_state_optional_price_does_not_block_withdrawal_does() raises:
    var clear = review_clear()
    assert_true(not clear.required)
    var blocked = review_required("withdrawal.target", "ambiguous_target")
    assert_true(blocked.required)
    assert_equal(len(blocked.clarifications), 1)
    var extended = review_add(blocked, "quantity.unreserved", "stock_unknown")
    assert_equal(len(extended.clarifications), 2)


from hyf_core.domain.clarification import (
    apply_clarification,
    clarification_evidence,
    clarification_is_stale,
)


def test_clarification_refines_without_overwriting_original() raises:
    var original = known_field("80", "span")
    var evidence = clarification_evidence(
        "quantity.unreserved", "farm-source-1", "r2", "60 lb unreserved"
    )
    var refined = apply_clarification(original, evidence, "60")
    assert_equal(original.value.value(), "80")
    assert_equal(refined.value.value(), "60")
    assert_true(not clarification_is_stale(evidence, "r2"))
    assert_true(clarification_is_stale(evidence, "r3"))


from hyf_core.domain.demand import (
    Condition,
    DemandLine,
    condition,
    condition_is_exclusion,
    demand_line,
    missing_information_is_prohibition,
)


def test_demand_lines_and_condition_strength() raises:
    var tomatoes = resolved_product("tomatoes", "tomato")
    var lines = List[DemandLine]()
    var conditions_a = List[Condition]()
    conditions_a.append(condition("fulfillment", "mandatory", Optional[String]("delivery")))
    conditions_a.append(condition("fulfillment_excluded", "excluded", Optional[String]("pickup")))
    lines.append(demand_line("l1", tomatoes, "known", 25, 0, conditions_a))
    var conditions_b = List[Condition]()
    conditions_b.append(condition("grade", "permitted", Optional[String]("seconds")))
    lines.append(demand_line("l2", tomatoes, "unknown", 0, 0, conditions_b))
    assert_equal(len(lines), 2)
    assert_true(condition_is_exclusion(lines[0].conditions[1]))
    assert_true(not condition_is_exclusion(lines[0].conditions[0]))
    assert_true(not missing_information_is_prohibition())
    with assert_raises():
        _ = condition("grade", "maybe", Optional[String]("x"))


from hyf_core.domain.snapshot import (
    SupplySnapshot,
    snapshot_identity,
    snapshot_unreserved_known,
    supply_snapshot,
)


def test_supply_snapshot_revisions_and_unknown_unreserved() raises:
    var tomatoes = resolved_product("Roma tomatoes", "tomato.roma")
    var known = supply_snapshot("lot-1", "l1", "farm-1", tomatoes, "known", 50, 0, "kg")
    var other_revision = supply_snapshot("lot-1", "l2", "farm-1", tomatoes, "known", 30, 0, "kg")
    assert_true(snapshot_unreserved_known(known))
    assert_true(snapshot_identity(known) != snapshot_identity(other_revision))
    var unknown = supply_snapshot("lot-2", "l1", "farm-1", tomatoes, "unknown", 0, 0, "kg")
    assert_true(not snapshot_unreserved_known(unknown))
