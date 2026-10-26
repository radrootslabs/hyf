# D57 — hyf_ops_v3 context; v2 is retained as pre-activation characterization.
#
# This module owns the strict operation context selected by hyf_ops_v3 and
# the historical v2 pre-activation compatibility controls. It does not implement
# operation pipelines (C008/C009), typed semantic consistency (C023) or
# activation (C042-C046). A recognized versioned request is parsed, then refused in
# hyf_stdio.server; it must never reach the legacy shortcut handlers.

from std.collections import Dict, List, Optional

from json import Value
from json.deserialize import get_bool, get_int, get_string


comptime OPERATION_CONTRACT_SCHEMA_V2: String = "hyf_ops_v2"
comptime OPERATION_CONTRACT_SCHEMA_V3: String = "hyf_ops_v3"
comptime OPERATION_CONTEXT_DEFAULT_DEADLINE_MS: Int = 2500


def corrected_operation_selector() -> String:
    return OPERATION_CONTRACT_SCHEMA_V3


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
    # ADR-0026 D46 CR04: bounded linear seen-key admission. The previous
    # all-pairs scan was quadratic in the decoded key count; this visits each
    # entry once and rejects the first repeated decoded key.
    var seen = Dict[String, Bool]()
    for item in value.object_items():
        var key = String(item[0])
        if key in seen:
            raise Error(context + " contains duplicate field '" + key + "'")
        seen[key] = True


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
    if (
        schema != OPERATION_CONTRACT_SCHEMA_V2
        and schema != OPERATION_CONTRACT_SCHEMA_V3
    ):
        raise Error(
            context
            + " selects unsupported operation contract schema '"
            + schema
            + "'"
        )

    var model = _required_string(json, "model", context + " model")
    if schema == OPERATION_CONTRACT_SCHEMA_V3 and model != "jev-1.14.0":
        raise Error(context + " requires exact Jev model jev-1.14.0")

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
        model=model,
    )


@fieldwise_init
struct OperationActor(Copyable, Movable):
    # This is an untrusted public ActorRef descriptor, never an authenticated
    # CommandContext. The host retains and revalidates its SDK context.
    var participant: String
    var role: String
    var organization: Optional[String]
    var grant_id: Optional[String]


def _canonical_identity(value: String, context: String) raises -> String:
    if value.byte_length() != 64:
        raise Error(context + " must be a 64-character lowercase hex identity")
    for i in range(value.byte_length()):
        var byte = value.unsafe_ptr()[i]
        if not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)):
            raise Error(context + " must use lowercase ASCII hex")
    return value


def _nullable_identity(
    value: Value, key: String, context: String
) raises -> Optional[String]:
    if not _has_key(value, key):
        raise Error(context + " is required (explicit null is permitted)")
    var raw = value[key]
    if raw.is_null():
        return None
    return _canonical_identity(get_string(value, key), context)


def _parse_operation_actor(value: Value) raises -> OperationActor:
    _require_object(value, "operation context actor")
    _require_no_duplicate_keys(value, "operation context actor")
    var keys = List[String]()
    for key in ["participant", "role", "organization", "grant_id"]:
        keys.append(key)
    _require_allowed_keys(value, keys, "operation context actor")
    var participant = _canonical_identity(
        _required_string(value, "participant", "actor participant"),
        "actor participant",
    )
    var role = _required_string(value, "role", "actor role")
    if role != "seller" and role != "buyer" and role != "coordinator":
        raise Error("actor role must be seller, buyer or coordinator")
    return OperationActor(
        participant=participant,
        role=role,
        organization=_nullable_identity(
            value, "organization", "actor organization"
        ),
        grant_id=_nullable_identity(value, "grant_id", "actor grant_id"),
    )


def _canonical_unix_seconds(value: String) raises:
    # Representation parity with public radroots_domain::UnixSeconds. Time
    # interpretation and source eligibility remain with the shared SDK owner.
    var size = value.byte_length()
    if size == 0 or size > 12:
        raise Error("evaluation_time must be canonical bounded UnixSeconds")
    if size > 1 and value.unsafe_ptr()[0] == 48:
        raise Error("evaluation_time must not have leading zeros")
    var seconds = 0
    for i in range(size):
        var byte = value.unsafe_ptr()[i]
        if byte < 48 or byte > 57:
            raise Error("evaluation_time must use unsigned ASCII seconds")
        seconds = seconds * 10 + Int(byte) - 48
    if seconds > 253402300799:
        raise Error("evaluation_time exceeds the shared UnixSeconds bound")


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
    var actor: Optional[OperationActor]
    var workspace_id: Optional[String]


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
        actor=None,
        workspace_id=None,
    )


def operation_context_selects_v3(context_json: Value) raises -> Bool:
    if not context_json.is_object() or not _has_key(context_json, "versions"):
        return False
    var versions = context_json["versions"]
    if not versions.is_object() or not _has_key(versions, "schema"):
        return False
    var schema = versions["schema"]
    return (
        schema.is_string()
        and String(schema.string_value()) == OPERATION_CONTRACT_SCHEMA_V3
    )


def operation_context_selects_v2(context_json: Value) raises -> Bool:
    """True only for a well-typed ``context.versions.schema == hyf_ops_v2``.

    Missing, null, wrong-type and unknown selectors are not recognized here;
    they fall through to the unchanged legacy parser, which rejects
    ``versions`` for unrelated capabilities and returns invalid_request.

    ADR-0026 D46 CR04: this first-wins lookup is only used after the envelope
    root duplicate gate has rejected any ambiguous v2-targeting envelope; use
    ``context_selects_versioned_any`` for duplicate-aware inspection.
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


def context_selects_versioned_any(context_json: Value) raises -> Bool:
    """Duplicate-aware v2/v3 inspection for the envelope admission gate.

    Scans every decoded ``versions`` member and every decoded ``schema`` entry
    instead of the first match, so a duplicate key cannot hide a v2 selector
    behind an earlier legacy value. Not a substitute for unambiguous parsing:
    the caller rejects the whole envelope when duplicate root keys are found.
    """
    if not context_json.is_object():
        return False
    for item in context_json.object_items():
        if item[0] != "versions":
            continue
        var versions = item[1].copy()
        if not versions.is_object():
            continue
        for member in versions.object_items():
            if member[0] == "schema" and member[1].is_string():
                if (
                    String(member[1].string_value())
                    == OPERATION_CONTRACT_SCHEMA_V2
                    or String(member[1].string_value())
                    == OPERATION_CONTRACT_SCHEMA_V3
                ):
                    return True
    return False


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

    var is_v3 = operation_context_selects_v3(json)
    var requires_farm = not is_v3 and corrected_operation_requires_farm_id(
        capability
    )
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
    ]:
        allowed_keys.append(key)
    if is_v3:
        allowed_keys.append("actor")
        allowed_keys.append("workspace_id")
    else:
        allowed_keys.append("actor_id")
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
        if context.deadline_ms <= 0 or (
            is_v3 and context.deadline_ms > 2147483647
        ):
            raise Error(
                "operation context deadline_ms must be greater than zero"
            )

    context.evaluation_time = _required_string(
        json, "evaluation_time", "operation context evaluation_time"
    )
    if is_v3:
        _canonical_unix_seconds(context.evaluation_time)

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

    if is_v3:
        if not _has_key(json, "actor"):
            raise Error("operation context actor is required")
        context.actor = _parse_operation_actor(json["actor"].clone())
        context.workspace_id = _canonical_identity(
            _required_string(
                json, "workspace_id", "operation context workspace_id"
            ),
            "operation context workspace_id",
        )
        # Never turn this descriptor into an authorization token or a business
        # write. It remains behind the pre-activation guard until later owners.
    else:
        context.actor_id = _required_string(
            json, "actor_id", "operation context actor_id"
        )

    if requires_farm:
        context.farm_id = _required_string(
            json, "farm_id", "operation context farm_id"
        )

    return context^
