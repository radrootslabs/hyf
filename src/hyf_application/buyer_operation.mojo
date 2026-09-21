from std.collections import List
from json import Value, loads

from hyf_application.context import interpretation_source
from hyf_core.domain.eligibility import (
    ConstraintAssessment,
    compose_eligibility,
    constraint_assessment,
)


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _string_list(value: Value) raises -> List[String]:
    var items = List[String]()
    if not value.is_array():
        return items^
    for entry in value.array_items():
        if entry.is_string():
            items.append(entry.string_value())
    return items^


def _validate_source(input: Value) raises:
    if not input.is_object() or not _has_key(input, "source"):
        raise Error("buyer operation input requires 'source'")
    var source = input["source"]
    _ = interpretation_source(
        source_id=source["source_id"].string_value(),
        revision=source["revision"].string_value(),
        text=source["text"].string_value(),
        source_time=source["source_time"].string_value(),
        timezone=source["timezone"].string_value(),
        actor_id=source["actor_id"].string_value(),
        farm_id=source["farm_id"].string_value(),
    )


def execute_buyer_request_interpret(input: Value) raises -> Value:
    _validate_source(input)
    var phrases = List[String]()
    if _has_key(input, "products"):
        phrases = _string_list(input["products"])

    var lines = loads("[]")
    var index = 1
    for phrase in phrases:
        var line = loads("{}")
        line.set("line_id", Value("line-" + String(index)))
        var product = loads("{}")
        product.set("phrase", Value(String(phrase)))
        product.set("catalogue_id", Value(String(phrase)))
        product.set("resolution", Value("resolved"))
        line.set("product", product)
        var quantity = loads("{}")
        quantity.set("state", Value("unknown"))
        line.set("quantity", quantity)
        line.set("conditions", loads("[]"))
        line.set("evidence", loads("[]"))
        line.set("review_required", Value(True))
        lines.append(line)
        index += 1

    var output = loads("{}")
    output.set("demand_lines", lines)
    var review = loads("{}")
    review.set("required", Value(len(phrases) == 0))
    var clarifications = loads("[]")
    if len(phrases) == 0:
        var clarification = loads("{}")
        clarification.set("field", Value("demand_lines"))
        clarification.set("reason", Value("information_needed"))
        clarifications.append(clarification)
    review.set("clarifications", clarifications)
    output.set("review", review)
    var execution = loads("{}")
    execution.set("status", Value("complete"))
    execution.set("provider_calls", Value(0))
    output.set("execution", execution)
    return output^


def _assessment_value(
    lot_id: String, checks: List[ConstraintAssessment]
) raises -> Value:
    var value = loads("{}")
    value.set("candidate_id", Value(String(lot_id)))
    value.set("eligibility", Value(compose_eligibility(checks)))
    var check_values = loads("[]")
    for check in checks:
        var entry = loads("{}")
        entry.set("kind", Value(String(check.kind)))
        entry.set("result", Value(String(check.result)))
        entry.set("reason", Value(String(check.reason)))
        entry.set("evidence", loads("[]"))
        check_values.append(entry)
    value.set("checks", check_values)
    return value^


def execute_buyer_request_match(input: Value) raises -> Value:
    if not input.is_object() or not _has_key(input, "need"):
        raise Error("buyer_request.match input requires 'need'")
    if not _has_key(input, "snapshots"):
        raise Error("buyer_request.match input requires 'snapshots'")

    var need = input["need"]
    var required_phrase = ""
    if _has_key(need, "product_phrase"):
        required_phrase = need["product_phrase"].string_value()
    var required_value = 0
    var required_scale = 0
    var required_unit = "kg"
    if _has_key(need, "quantity"):
        var quantity = need["quantity"]
        if _has_key(quantity, "value"):
            required_value = Int(quantity["value"].int_value())
        if _has_key(quantity, "scale"):
            required_scale = Int(quantity["scale"].int_value())
        if _has_key(quantity, "unit"):
            required_unit = quantity["unit"].string_value()

    var assessments = loads("[]")
    var plans = loads("[]")
    var plan_index = 1
    for snapshot in input["snapshots"].array_items():
        var lot_id = snapshot["lot_id"].string_value()
        var supplier_id = ""
        if _has_key(snapshot, "supplier_id"):
            supplier_id = snapshot["supplier_id"].string_value()
        var lot_phrase = required_phrase
        if _has_key(snapshot, "product_phrase"):
            lot_phrase = snapshot["product_phrase"].string_value()

        var checks = List[ConstraintAssessment]()
        checks.append(
            constraint_assessment(
                "product",
                "pass" if required_phrase == lot_phrase else "fail",
                True,
                "product_match" if required_phrase == lot_phrase else "product_mismatch",
            )
        )
        var available_state = "unknown"
        if _has_key(snapshot, "unreserved_state"):
            available_state = snapshot["unreserved_state"].string_value()
        checks.append(
            constraint_assessment(
                "availability",
                "pass" if available_state == "known" else "unknown",
                True,
                "availability_known" if available_state == "known" else "stock_unknown",
            )
        )
        if available_state == "known" and required_value > 0:
            var available_value = Int(snapshot["unreserved_value"].int_value())
            var available_scale = Int(snapshot["unreserved_scale"].int_value())
            var comparison = "fail"
            if available_value >= required_value:
                comparison = "pass"
            checks.append(
                constraint_assessment(
                    "quantity",
                    comparison,
                    True,
                    "quantity_sufficient" if comparison == "pass" else "quantity_insufficient",
                )
            )
        assessments.append(_assessment_value(lot_id, checks))

        if compose_eligibility(checks) == "eligible" and supplier_id != "":
            var plan = loads("{}")
            plan.set("plan_id", Value("plan-" + String(plan_index)))
            plan.set("supplier_id", Value(String(supplier_id)))
            var allocations = loads("[]")
            var allocation = loads("{}")
            allocation.set("lot_id", Value(String(lot_id)))
            allocation.set("line_id", Value("line-1"))
            var quantity = loads("{}")
            quantity.set("state", Value("known"))
            quantity.set("value", Value(required_value))
            quantity.set("unit", Value(String(required_unit)))
            quantity.set("qualifier", Value("exact"))
            allocation.set("quantity", quantity)
            allocations.append(allocation)
            plan.set("allocations", allocations)
            var coverage = loads("{}")
            coverage.set("lines_covered", loads('["line-1"]'))
            coverage.set("uncovered", loads("[]"))
            coverage.set("partial", Value(False))
            plan.set("coverage", coverage)
            plan.set("unresolved", loads("[]"))
            plans.append(plan)
            plan_index += 1

    var output = loads("{}")
    output.set("assessments", assessments)
    output.set("plans", plans)
    var limitations = loads("{}")
    limitations.set("scope", Value("supplied_only"))
    limitations.set("truncated", Value(False))
    limitations.set("supported_mode", Value("single_supplier_compatible_lots"))
    limitations.set("unsupported", loads('["multi_supplier"]'))
    output.set("limitations", limitations)
    var execution = loads("{}")
    execution.set("status", Value("complete"))
    execution.set("provider_calls", Value(0))
    output.set("execution", execution)
    return output^
