from std.collections import List

from mojson import Value, loads

from hyf_core.provenance import CoreResponseMeta, ExecutionProvenance


def _string_array(items: List[String]) raises -> Value:
    var array = loads("[]")
    for item in items:
        array.append(Value(String(item)))
    return array^


def _serialize_provenance(provenance: ExecutionProvenance) raises -> Value:
    var value = loads("{}")
    value.set("kind", Value(String(provenance.kind)))
    value.set("signal_tags", _string_array(provenance.signal_tags))

    var source_refs = loads("[]")
    for source_ref in provenance.source_refs:
        var ref_value = loads("{}")
        ref_value.set("source_kind", Value(String(source_ref.source_kind)))
        ref_value.set("source_ref", Value(String(source_ref.source_ref)))
        source_refs.append(ref_value)
    value.set("source_refs", source_refs)

    if provenance.fallback:
        var fallback = provenance.fallback.value().copy()
        var fallback_value = loads("{}")
        fallback_value.set(
            "fallback_kind", Value(String(fallback.fallback_kind))
        )
        fallback_value.set("reason", Value(String(fallback.reason)))
        value.set("fallback", fallback_value)
    else:
        value.set("fallback", Value(None))

    if provenance.evidence_set_id:
        value.set(
            "evidence_set_id", Value(String(provenance.evidence_set_id.value()))
        )
    else:
        value.set("evidence_set_id", Value(None))

    return value^


def serialize_core_response_meta(meta: CoreResponseMeta) raises -> Value:
    var value = loads("{}")
    value.set("execution_mode", Value(String(meta.execution_mode)))
    value.set("backend", Value(String(meta.backend)))
    if meta.provider:
        value.set("provider", Value(String(meta.provider.value())))
    if meta.route:
        value.set("route", Value(String(meta.route.value())))
    if meta.model:
        value.set("model", Value(String(meta.model.value())))
    if meta.latency_ms:
        value.set("latency_ms", Value(meta.latency_ms.value()))
    if meta.schema_version:
        value.set("schema_version", Value(meta.schema_version.value()))
    if meta.prompt_version:
        value.set(
            "prompt_version", Value(String(meta.prompt_version.value()))
        )
    if meta.provenance:
        value.set("provenance", _serialize_provenance(meta.provenance.value()))
    return value^
