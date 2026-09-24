"""Frozen semantic resource envelope (ADR-0010 D21; policy table
``docs/spec/hyf_http_v1/policy/hyf_http_v1_policy.v1.toml``).

These are Codex-selected local regression bounds, not production SLOs. The
values are frozen here as named constants and applied by
:func:`default_resource_envelope`; dependent slices (H093 and the operation
pipelines) consume them and may not enlarge or weaken them.
"""

comptime RESOURCE_ENVELOPE_MAX_CANDIDATES: Int = 64
comptime RESOURCE_ENVELOPE_MAX_PLANS: Int = 8
comptime RESOURCE_ENVELOPE_MAX_STATE_BYTES: Int = 4096
comptime RESOURCE_ENVELOPE_MAX_QUESTIONS: Int = 32
comptime RESOURCE_ENVELOPE_MAX_PROVIDER_CALLS: Int = 4


@fieldwise_init
struct ResourceEnvelope(Copyable, Movable):
    var max_candidates: Int
    var max_plans: Int
    var max_state_bytes: Int
    var max_questions: Int
    var max_provider_calls: Int


def default_resource_envelope() -> ResourceEnvelope:
    return ResourceEnvelope(
        max_candidates=RESOURCE_ENVELOPE_MAX_CANDIDATES,
        max_plans=RESOURCE_ENVELOPE_MAX_PLANS,
        max_state_bytes=RESOURCE_ENVELOPE_MAX_STATE_BYTES,
        max_questions=RESOURCE_ENVELOPE_MAX_QUESTIONS,
        max_provider_calls=RESOURCE_ENVELOPE_MAX_PROVIDER_CALLS,
    )


def within_envelope(
    envelope: ResourceEnvelope,
    candidates: Int,
    plans: Int,
    state_bytes: Int,
    questions: Int,
    provider_calls: Int,
) -> Bool:
    """True when every dimension is at or below its inclusive cap."""
    return (
        candidates <= envelope.max_candidates
        and plans <= envelope.max_plans
        and state_bytes <= envelope.max_state_bytes
        and questions <= envelope.max_questions
        and provider_calls <= envelope.max_provider_calls
    )
