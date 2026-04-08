from std.collections import List, Optional

from mojson import Value
from mojson.deserialize import get_bool, get_int, get_string


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def _require_object(value: Value, context: String) raises:
    if not value.is_object():
        raise Error(context + " must be a JSON object")


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


def _require_non_empty(value: String, context: String) raises:
    if value == "":
        raise Error(context + " must not be empty")


def _parse_string_list(value: Value, context: String) raises -> List[String]:
    if value.is_null():
        return List[String]()
    if not value.is_array():
        raise Error(context + " must be a JSON array")

    var items = List[String]()
    for item in value.array_items():
        if not item.is_string():
            raise Error(context + " must contain only strings")
        _require_non_empty(item.string_value(), context + " item")
        items.append(item.string_value())
    return items^


@fieldwise_init
struct RequestScope(Copyable, Movable):
    var listing_ids: List[String]
    var farm_ids: List[String]
    var account_ids: List[String]
    var platform_ids: List[String]
    var object_filters: Optional[Value]


@fieldwise_init
struct TimeRange(Copyable, Movable):
    var start: String
    var end: String


@fieldwise_init
struct RequestContext(Copyable, Movable):
    var consumer: String
    var execution_mode_preference: String
    var deadline_ms: Int
    var scope: Optional[RequestScope]
    var time_range: Optional[TimeRange]
    var evidence_limit: Int
    var consistency: String
    var return_provenance: Bool
    var explain_plan: Bool


def request_context_feature_names() -> List[String]:
    var features = List[String]()
    features.append("consumer")
    features.append("execution_mode_preference")
    features.append("deadline_ms")
    features.append("scope")
    features.append("time_range")
    features.append("evidence_limit")
    features.append("consistency")
    features.append("return_provenance")
    features.append("explain_plan")
    return features^


def default_request_context() -> RequestContext:
    return RequestContext(
        consumer="unknown",
        execution_mode_preference="deterministic",
        deadline_ms=2500,
        scope=None,
        time_range=None,
        evidence_limit=10,
        consistency="default",
        return_provenance=False,
        explain_plan=False,
    )


def assisted_execution_requested(context: RequestContext) -> Bool:
    return context.execution_mode_preference == "assisted"


def _parse_scope(json: Value) raises -> RequestScope:
    _require_object(json, "request context scope")

    var allowed_keys = List[String]()
    allowed_keys.append("listing_ids")
    allowed_keys.append("farm_ids")
    allowed_keys.append("account_ids")
    allowed_keys.append("platform_ids")
    allowed_keys.append("object_filters")
    _require_allowed_keys(json, allowed_keys, "request context scope")

    var object_filters: Optional[Value] = None
    if _has_key(json, "object_filters"):
        var raw_filters = json["object_filters"].clone()
        if not raw_filters.is_null():
            object_filters = raw_filters^

    var listing_ids_json = Value(None)
    if _has_key(json, "listing_ids"):
        listing_ids_json = json["listing_ids"].clone()

    var farm_ids_json = Value(None)
    if _has_key(json, "farm_ids"):
        farm_ids_json = json["farm_ids"].clone()

    var account_ids_json = Value(None)
    if _has_key(json, "account_ids"):
        account_ids_json = json["account_ids"].clone()

    var platform_ids_json = Value(None)
    if _has_key(json, "platform_ids"):
        platform_ids_json = json["platform_ids"].clone()

    return RequestScope(
        listing_ids=_parse_string_list(
            listing_ids_json, "request context scope listing_ids"
        ),
        farm_ids=_parse_string_list(
            farm_ids_json, "request context scope farm_ids"
        ),
        account_ids=_parse_string_list(
            account_ids_json, "request context scope account_ids"
        ),
        platform_ids=_parse_string_list(
            platform_ids_json, "request context scope platform_ids"
        ),
        object_filters=object_filters^,
    )


def _parse_time_range(json: Value) raises -> TimeRange:
    _require_object(json, "request context time_range")

    var allowed_keys = List[String]()
    allowed_keys.append("start")
    allowed_keys.append("end")
    _require_allowed_keys(json, allowed_keys, "request context time_range")

    var start = get_string(json, "start")
    _require_non_empty(start, "request context time_range start")

    var end = get_string(json, "end")
    _require_non_empty(end, "request context time_range end")

    return TimeRange(start=start, end=end)


def parse_request_context(json: Value) raises -> RequestContext:
    if json.is_null():
        return default_request_context()

    _require_object(json, "request context")

    var allowed_keys = request_context_feature_names()
    _require_allowed_keys(json, allowed_keys, "request context")

    var context = default_request_context()

    if _has_key(json, "consumer"):
        context.consumer = get_string(json, "consumer")
        _require_non_empty(context.consumer, "request context consumer")

    if _has_key(json, "execution_mode_preference"):
        context.execution_mode_preference = get_string(
            json, "execution_mode_preference"
        )
        if (
            context.execution_mode_preference != "deterministic"
            and context.execution_mode_preference != "assisted"
        ):
            raise Error(
                "request context execution_mode_preference must be 'deterministic' or 'assisted'"
            )

    if _has_key(json, "deadline_ms"):
        context.deadline_ms = get_int(json, "deadline_ms")
        if context.deadline_ms <= 0:
            raise Error("request context deadline_ms must be greater than zero")

    if _has_key(json, "scope"):
        var scope_json = json["scope"].clone()
        if not scope_json.is_null():
            context.scope = _parse_scope(scope_json)

    if _has_key(json, "time_range"):
        var time_range_json = json["time_range"].clone()
        if not time_range_json.is_null():
            context.time_range = _parse_time_range(time_range_json)

    if _has_key(json, "evidence_limit"):
        context.evidence_limit = get_int(json, "evidence_limit")
        if context.evidence_limit <= 0:
            raise Error(
                "request context evidence_limit must be greater than zero"
            )

    if _has_key(json, "consistency"):
        context.consistency = get_string(json, "consistency")
        if (
            context.consistency != "default"
            and context.consistency != "strong"
        ):
            raise Error(
                "request context consistency must be 'default' or 'strong'"
            )

    if _has_key(json, "return_provenance"):
        context.return_provenance = get_bool(json, "return_provenance")

    if _has_key(json, "explain_plan"):
        context.explain_plan = get_bool(json, "explain_plan")

    return context^
