# ADR-0025 D45 CB01-CB05 — corrected hyf_ops_v2 capability context.
#
# This module owns only the strict, capability-aware operation context for the
# three corrected operations selected by ``context.versions.schema ==
# "hyf_ops_v2"``. It does not implement the operation pipelines (C008/C009),
# typed semantic consistency (C023) or activation (C042-C046). A recognized v2
# request is parsed here and then refused by the pre-activation guard in
# hyf_stdio.server; it must never reach the legacy shortcut handlers.

from std.collections import List, Optional

from json import Value
from json.deserialize import get_bool, get_int, get_string


comptime OPERATION_CONTRACT_SCHEMA_V2: String = "hyf_ops_v2"
comptime OPERATION_CONTEXT_DEFAULT_DEADLINE_MS: Int = 2500


def corrected_operation_selector() -> String:
    return OPERATION_CONTRACT_SCHEMA_V2


def is_corrected_operation(capability: String) -> Bool:
    return (
        capability == "farm_update.interpret"
        or capability == "buyer_request.interpret"
        or capability == "buyer_request.match"
    )


def corrected_operation_requires_farm_id(capability: String) -> Bool:
    return capability == "farm_update.interpret"


def corrected_operation_activation_enabled() -> Bool:
    """Activation boundary owned by C042-C046; C004 binds but never activates.
    """
    return False


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _require_object(value: Value, context: String) raises:
    if not value.is_object():
        raise Error(context + " must be a JSON object")


def _require_no_duplicate_keys(value: Value, context: String) raises:
    var keys = value.object_keys()
    for left in range(len(keys)):
        for right in range(left + 1, len(keys)):
            if keys[left] == keys[right]:
                raise Error(
                    context + " contains duplicate field '" + keys[left] + "'"
                )


def _require_allowed_keys(
    value: Value, allowed_keys: List[String], context: String
) raises:
    for key in value.object_keys():
        var allowed = False
        for allowed_key in allowed_keys:
            if key == allowed_key:
                allowed = True
                break
        if not allowed:
            raise Error(context + " contains unexpected field '" + key + "'")


def _has_nonblank(value: String) -> Bool:
    return String(value).strip().byte_length() > 0


def _require_nonblank(value: String, context: String) raises:
    if not _has_nonblank(value):
        raise Error(context + " must not be blank")


def _optional_string(
    value: Value, key: String, context: String
) raises -> Optional[String]:
    if not _has_key(value, key):
        return None
    var raw = get_string(value, key)
    _require_nonblank(raw, context)
    return String(raw)


def _required_string(
    value: Value, key: String, context: String
) raises -> String:
    if not _has_key(value, key):
        raise Error(context + " is required")
    var raw = get_string(value, key)
    _require_nonblank(raw, context)
    return String(raw)


@fieldwise_init
struct OperationVersions(Copyable, Movable):
    var schema: String
    var taxonomy: String
    var normalization: String
    var review_policy: String
    var ranking_policy: String
    var question_bundle: String
    var model: String


def _parse_operation_versions(
    json: Value, context: String
) raises -> OperationVersions:
    _require_object(json, context)
    _require_no_duplicate_keys(json, context)

    var allowed_keys = List[String]()
    for key in [
        "schema",
        "taxonomy",
        "normalization",
        "review_policy",
        "ranking_policy",
        "question_bundle",
        "model",
    ]:
        allowed_keys.append(key)
    _require_allowed_keys(json, allowed_keys, context)

    var schema = _required_string(json, "schema", context + " schema")
    if schema != OPERATION_CONTRACT_SCHEMA_V2:
        raise Error(
            context
            + " selects unsupported operation contract schema '"
            + schema
            + "'"
        )

    return OperationVersions(
        schema=schema,
        taxonomy=_required_string(json, "taxonomy", context + " taxonomy"),
        normalization=_required_string(
            json, "normalization", context + " normalization"
        ),
        review_policy=_required_string(
            json, "review_policy", context + " review_policy"
        ),
        ranking_policy=_required_string(
            json, "ranking_policy", context + " ranking_policy"
        ),
        question_bundle=_required_string(
            json, "question_bundle", context + " question_bundle"
        ),
        model=_required_string(json, "model", context + " model"),
    )


@fieldwise_init
struct OperationContext(Copyable, Movable):
    var consumer: String
    var execution_mode_preference: String
    var deadline_ms: Int
    var evaluation_time: String
    var timezone: Optional[String]
    var locale: Optional[String]
    var versions: OperationVersions
    var return_provenance: Bool
    var actor_id: String
    var farm_id: Optional[String]


def default_operation_context() -> OperationContext:
    return OperationContext(
        consumer="unknown",
        execution_mode_preference="deterministic",
        deadline_ms=OPERATION_CONTEXT_DEFAULT_DEADLINE_MS,
        evaluation_time="",
        timezone=None,
        locale=None,
        versions=OperationVersions(
            schema="",
            taxonomy="",
            normalization="",
            review_policy="",
            ranking_policy="",
            question_bundle="",
            model="",
        ),
        return_provenance=False,
        actor_id="",
        farm_id=None,
    )


def operation_context_selects_v2(context_json: Value) raises -> Bool:
    """True only for a well-typed ``context.versions.schema == hyf_ops_v2``.

    Missing, null, wrong-type and unknown selectors are not recognized here;
    they fall through to the unchanged legacy parser, which rejects
    ``versions`` for unrelated capabilities and returns invalid_request.
    """
    if not context_json.is_object():
        return False
    if not _has_key(context_json, "versions"):
        return False
    var versions = context_json["versions"]
    if not versions.is_object():
        return False
    if not _has_key(versions, "schema"):
        return False
    var schema = versions["schema"]
    if not schema.is_string():
        return False
    return String(schema.string_value()) == OPERATION_CONTRACT_SCHEMA_V2


def parse_operation_context(
    json: Value, capability: String
) raises -> OperationContext:
    if not is_corrected_operation(capability):
        raise Error(
            "operation context is only defined for corrected operations, not '"
            + capability
            + "'"
        )

    _require_object(json, "operation context")
    _require_no_duplicate_keys(json, "operation context")

    var requires_farm = corrected_operation_requires_farm_id(capability)
    var allowed_keys = List[String]()
    for key in [
        "consumer",
        "execution_mode_preference",
        "deadline_ms",
        "evaluation_time",
        "timezone",
        "locale",
        "versions",
        "return_provenance",
        "actor_id",
    ]:
        allowed_keys.append(key)
    if requires_farm:
        allowed_keys.append("farm_id")
    _require_allowed_keys(json, allowed_keys, "operation context")

    var context = default_operation_context()

    var consumer = _optional_string(
        json, "consumer", "operation context consumer"
    )
    if consumer:
        context.consumer = consumer.value()

    if _has_key(json, "execution_mode_preference"):
        var preference = get_string(json, "execution_mode_preference")
        if preference != "deterministic" and preference != "assisted":
            raise Error(
                "operation context execution_mode_preference must be"
                " 'deterministic' or 'assisted'"
            )
        context.execution_mode_preference = String(preference)

    if _has_key(json, "deadline_ms"):
        context.deadline_ms = get_int(json, "deadline_ms")
        if context.deadline_ms <= 0:
            raise Error(
                "operation context deadline_ms must be greater than zero"
            )

    context.evaluation_time = _required_string(
        json, "evaluation_time", "operation context evaluation_time"
    )

    context.timezone = _optional_string(
        json, "timezone", "operation context timezone"
    )
    context.locale = _optional_string(
        json, "locale", "operation context locale"
    )

    if not _has_key(json, "versions"):
        raise Error("operation context versions is required")
    context.versions = _parse_operation_versions(
        json["versions"].clone(), "operation context versions"
    )

    if _has_key(json, "return_provenance"):
        context.return_provenance = get_bool(json, "return_provenance")

    context.actor_id = _required_string(
        json, "actor_id", "operation context actor_id"
    )

    if requires_farm:
        context.farm_id = _required_string(
            json, "farm_id", "operation context farm_id"
        )

    return context^
