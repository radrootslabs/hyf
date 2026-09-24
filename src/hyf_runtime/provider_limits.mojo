"""Codified provider response byte limits (ADR-0026 D46 H093).

These are the existing D21 / policy.v2 provider response bounds transcribed as
capsule constants with inclusive upper caps, nonnegative-count guards and the
stable failure causes/reasons already used by the H007 bounded-response
observer. H093 selects no new threshold: header 65536, raw body 1048576 and
decoded body 4194304 are the frozen values.

This module is a pure boundary surface. It performs no allocation, no
pre-allocation admission and no transport enforcement; C005/C047 and the owned
consumer/exposure slices execute those controls against these exact values.
"""
comptime PROVIDER_MAX_HEADER_BYTES: Int = 65536
comptime PROVIDER_MAX_RAW_BODY_BYTES: Int = 1048576
comptime PROVIDER_MAX_DECODED_BODY_BYTES: Int = 4194304

comptime PROVIDER_HEAD_OVERFLOW_CAUSE: String = "raw_head_overflow"
comptime PROVIDER_HEAD_OVERFLOW_REASON: String = "head_overflow"
comptime PROVIDER_RAW_BODY_OVERFLOW_CAUSE: String = "raw_body_overflow"
comptime PROVIDER_RAW_BODY_OVERFLOW_REASON: String = "body_overflow"
comptime PROVIDER_DECLARED_LENGTH_OVERFLOW_CAUSE: String = (
    "raw_content_length_overflow"
)
comptime PROVIDER_DECLARED_BODY_OVERFLOW_REASON: String = "raw_body_overflow"
# H093 transcription for the decoded bound; the H007 observer is raw-only, so
# this named reason is the codified value C005/NP02 enforces rather than an
# existing observed string.
comptime PROVIDER_DECODED_BODY_OVERFLOW_CAUSE: String = "decoded_body_overflow"
comptime PROVIDER_DECODED_BODY_OVERFLOW_REASON: String = "decoded_body_overflow"


def _require_nonnegative(byte_count: Int, context: String) raises:
    if byte_count < 0:
        raise Error(context + " must be non-negative")


def provider_limit_is_inclusive() -> Bool:
    """Descriptive: the upper cap itself is accepted; only cap+1 overflows."""
    return True


def provider_limit_min_bytes(kind: String) raises -> Int:
    """Policy.v2 lower bound: header min 1, raw body min 0, decoded min 0."""
    if kind == "header":
        return 1
    if kind == "raw_body" or kind == "decoded_body":
        return 0
    raise Error("unknown provider limit kind '" + kind + "'")


def header_byte_count_within_bound(byte_count: Int) raises -> Bool:
    _require_nonnegative(byte_count, "provider header byte count")
    return byte_count >= 1 and byte_count <= PROVIDER_MAX_HEADER_BYTES


def raw_body_byte_count_within_bound(byte_count: Int) raises -> Bool:
    _require_nonnegative(byte_count, "provider raw body byte count")
    return byte_count <= PROVIDER_MAX_RAW_BODY_BYTES


def decoded_body_byte_count_within_bound(byte_count: Int) raises -> Bool:
    _require_nonnegative(byte_count, "provider decoded body byte count")
    return byte_count <= PROVIDER_MAX_DECODED_BODY_BYTES


def provider_limit_bound(kind: String) raises -> Int:
    if kind == "header":
        return PROVIDER_MAX_HEADER_BYTES
    if kind == "raw_body":
        return PROVIDER_MAX_RAW_BODY_BYTES
    if kind == "decoded_body":
        return PROVIDER_MAX_DECODED_BODY_BYTES
    raise Error("unknown provider limit kind '" + kind + "'")


def provider_limit_overflow_cause(kind: String) raises -> String:
    if kind == "header":
        return PROVIDER_HEAD_OVERFLOW_CAUSE
    if kind == "raw_body":
        return PROVIDER_RAW_BODY_OVERFLOW_CAUSE
    if kind == "declared_length":
        return PROVIDER_DECLARED_LENGTH_OVERFLOW_CAUSE
    if kind == "declared_body":
        return PROVIDER_RAW_BODY_OVERFLOW_CAUSE
    if kind == "decoded_body":
        return PROVIDER_DECODED_BODY_OVERFLOW_CAUSE
    raise Error("unknown provider limit kind '" + kind + "'")


def provider_limit_failure_reason(kind: String) raises -> String:
    if kind == "header":
        return PROVIDER_HEAD_OVERFLOW_REASON
    if kind == "raw_body":
        return PROVIDER_RAW_BODY_OVERFLOW_REASON
    if kind == "declared_length":
        return PROVIDER_DECLARED_LENGTH_OVERFLOW_CAUSE
    if kind == "declared_body":
        return PROVIDER_DECLARED_BODY_OVERFLOW_REASON
    if kind == "decoded_body":
        return PROVIDER_DECODED_BODY_OVERFLOW_REASON
    raise Error("unknown provider limit kind '" + kind + "'")
