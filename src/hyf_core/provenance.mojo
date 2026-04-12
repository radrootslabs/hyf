from std.collections import List, Optional


@fieldwise_init
struct ProvenanceSourceRef(Copyable, Movable):
    var source_kind: String
    var source_ref: String


@fieldwise_init
struct ProvenanceFallback(Copyable, Movable):
    var fallback_kind: String
    var reason: String


@fieldwise_init
struct ExecutionProvenance(Copyable, Movable):
    var kind: String
    var signal_tags: List[String]
    var source_refs: List[ProvenanceSourceRef]
    var fallback: Optional[ProvenanceFallback]
    var evidence_set_id: Optional[String]


@fieldwise_init
struct CoreResponseMeta(Copyable, Movable):
    var execution_mode: String
    var backend: String
    var provider: Optional[String]
    var route: Optional[String]
    var model: Optional[String]
    var latency_ms: Optional[Int]
    var schema_version: Optional[Int]
    var prompt_version: Optional[String]
    var provenance: Optional[ExecutionProvenance]


def deterministic_response_meta() -> CoreResponseMeta:
    return CoreResponseMeta(
        execution_mode="deterministic",
        backend="heuristic",
        provider=None,
        route=None,
        model=None,
        latency_ms=None,
        schema_version=None,
        prompt_version=None,
        provenance=None,
    )
