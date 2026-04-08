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
    var latency_ms: Int
    var provenance: Optional[ExecutionProvenance]


def deterministic_response_meta() -> CoreResponseMeta:
    return CoreResponseMeta(
        execution_mode="deterministic",
        backend="heuristic",
        latency_ms=0,
        provenance=None,
    )
