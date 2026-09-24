"""Minimal test-only parent-bounded in-process call runner (H007 BC01-BC03).

An elapsed-time assertion after a synchronous provider call is not a parent
deadline: if the call never returns, the owning test hangs and the observed
behavior cannot be characterized. This helper forks one exact-owned child that
performs the risky provider call or raw header/body observation and writes a
single bounded report line; the parent enforces one spawn-relative work budget,
validates the complete report through EOF, verifies a natural child exit zero,
and, when the budget expires, terminates and reaps the exact owned child
through the shared lifecycle primitives.

Ownership and cleanup reuse the qualified ``PipedChildState``/``CleanupGuard``
primitives rather than a private lifecycle: the exact child and its report
descriptor are scope-owned immediately after spawn, each owned descriptor is
closed at most once, and an unproved cleanup retains the usable ownership
handle so the caller can recover it.

The report grammar is one line of ``key=value`` fields validated by the parent:

``report kind=<kind> correlation=<n> outcome=ok status=<code> [timing fields]``
``report kind=<kind> correlation=<n> outcome=fail cause=<token> reason=<token>``

A wrong kind/correlation, an unknown/duplicate/missing field, a malformed or
unterminated/duplicated report, surplus bytes through EOF, a read/poll error or
a non-zero/signaled child exit is a harness failure and can never be reported as
a completed call. A well-formed ``outcome=fail`` report is a characterized
domain/provider failure, which is distinct from a harness failure.

It is test-only tooling: no product policy, schema, dependency or lock change.
"""

from std.collections import List

from json import Value, loads

from flare.net import SocketAddr
from flare.tcp import TcpStream

from parent_lifecycle import (
    SIGKILL,
    TERMINATION_GRACE_MS,
    CleanupGuard,
    ProcessStatus,
    child_exit,
    close_fd,
    fork_owned_or_close,
    kill_pid,
    make_pipe,
    now_ms,
    owned_pid,
    piped_child_state,
    read_fd,
    set_alarm,
    sleep_ms,
    write_raw,
    write_raw_bytes,
)

from hyf_core.request_context import default_request_context
from hyf_provider.client import post_max_local_chat_completion
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.jev_client import post_jev_systemone
from hyf_provider.schema import build_query_rewrite_request_body


comptime BOUNDED_CALL_MAX_REPORT_BYTES = 4096
comptime BOUNDED_CALL_CHILD_ALARM_SECONDS = 120


def _field_allowed(key: String) -> Bool:
    if key == "kind" or key == "correlation" or key == "outcome":
        return True
    if key == "status" or key == "cause" or key == "reason":
        return True
    if key == "latency_ms" or key == "head_ms" or key == "total_ms":
        return True
    if key == "body_bytes" or key == "body_match":
        return True
    return key == "declared_bytes" or key == "length_match"


def _field_numeric(key: String) -> Bool:
    if key == "status" or key == "correlation" or key == "latency_ms":
        return True
    if key == "head_ms" or key == "total_ms":
        return True
    return key == "body_bytes" or key == "declared_bytes"


def _all_digits(text: String) -> Bool:
    if text.byte_length() == 0:
        return False
    for byte in text.as_bytes():
        var b = Int(byte)
        if b < 48 or b > 57:
            return False
    return True


@fieldwise_init
struct BoundedCallOutcome(Movable):
    """Validated fields of one bounded report line.

    ``ok``/``problem`` describe the validation result; ``outcome`` plus the
    call-specific fields describe the declared call outcome.
    """

    var ok: Bool
    var problem: String
    var kind: String
    var correlation: Int
    var outcome: String
    var status: Int
    var cause: String
    var reason: String
    var latency_ms: Int
    var head_ms: Int
    var total_ms: Int
    var body_bytes: Int
    var body_match: String
    var declared_bytes: Int
    var length_match: String

    def domain_failure(self) -> Bool:
        return self.ok and self.outcome == "fail"

    def describe(self) -> String:
        return (
            "kind="
            + self.kind
            + " correlation="
            + String(self.correlation)
            + " outcome="
            + self.outcome
            + " status="
            + String(self.status)
            + " cause="
            + self.cause
            + " reason="
            + self.reason
            + " latency_ms="
            + String(self.latency_ms)
            + " head_ms="
            + String(self.head_ms)
            + " total_ms="
            + String(self.total_ms)
            + " body_bytes="
            + String(self.body_bytes)
            + " body_match="
            + self.body_match
            + " declared_bytes="
            + String(self.declared_bytes)
            + " length_match="
            + self.length_match
        )


def _empty_outcome(problem: String) -> BoundedCallOutcome:
    return BoundedCallOutcome(
        ok=False,
        problem=problem,
        kind="",
        correlation=-1,
        outcome="",
        status=0,
        cause="",
        reason="",
        latency_ms=-1,
        head_ms=-1,
        total_ms=-1,
        body_bytes=-1,
        body_match="",
        declared_bytes=-1,
        length_match="",
    )


def parse_bounded_report(
    text: String, expected_kind: String, correlation: Int
) raises -> BoundedCallOutcome:
    """Validate one complete bounded report line for the declared call.

    Rejects a wrong kind or correlation, an unknown/duplicate/missing field, a
    malformed token and an incompatible outcome (a status on a failure, or a
    cause/reason on a success). Every rejection is a bounded problem token, so
    a harness failure is never mistaken for a characterized call outcome.
    """
    var tokens = text.strip().split(" ")
    if len(tokens) < 1 or String(tokens[0]) != "report":
        return _empty_outcome("report_prefix")
    var keys = List[String]()
    var values = List[String]()
    for index in range(1, len(tokens)):
        var token = String(tokens[index])
        var split = token.find("=")
        if split <= 0 or split == token.byte_length() - 1:
            return _empty_outcome("report_token_grammar")
        var key = String(token[byte=0:split])
        if not _field_allowed(key):
            return _empty_outcome("report_unknown_field_" + key)
        for seen in range(len(keys)):
            if keys[seen] == key:
                return _empty_outcome("report_duplicate_field_" + key)
        keys.append(key)
        values.append(String(token[byte = split + 1 :]))
    var kind = ""
    var correlation_text = ""
    var outcome = ""
    var status_text = ""
    var cause = ""
    var reason = ""
    var latency_text = ""
    var head_text = ""
    var total_text = ""
    var bytes_text = ""
    var match_text = ""
    var declared_text = ""
    var length_text = ""
    for index in range(len(keys)):
        var key = keys[index]
        var value = values[index]
        if key == "kind":
            kind = value
        elif key == "correlation":
            correlation_text = value
        elif key == "outcome":
            outcome = value
        elif key == "status":
            status_text = value
        elif key == "cause":
            cause = value
        elif key == "reason":
            reason = value
        elif key == "latency_ms":
            latency_text = value
        elif key == "head_ms":
            head_text = value
        elif key == "total_ms":
            total_text = value
        elif key == "body_bytes":
            bytes_text = value
        elif key == "body_match":
            match_text = value
        elif key == "declared_bytes":
            declared_text = value
        elif key == "length_match":
            length_text = value
        if _field_numeric(key) and not _all_digits(value):
            return _empty_outcome("report_non_numeric_" + key)
    if kind == "" or correlation_text == "" or outcome == "":
        return _empty_outcome("report_missing_field")
    if kind != expected_kind:
        return _empty_outcome("report_kind_mismatch")
    if Int(correlation_text) != correlation:
        return _empty_outcome("report_correlation_mismatch")
    if outcome != "ok" and outcome != "fail":
        return _empty_outcome("report_outcome_unknown_" + outcome)
    if outcome == "ok":
        if status_text == "":
            return _empty_outcome("report_status_missing")
        var code = Int(status_text)
        if code < 100 or code > 599:
            return _empty_outcome("report_status_invalid")
        if cause != "" or reason != "":
            return _empty_outcome("report_incompatible_outcome")
    else:
        if cause == "" or reason == "":
            return _empty_outcome("report_cause_missing")
        if status_text != "":
            return _empty_outcome("report_incompatible_outcome")
    return BoundedCallOutcome(
        ok=True,
        problem="",
        kind=kind,
        correlation=Int(correlation_text),
        outcome=outcome,
        status=Int(status_text) if status_text != "" else 0,
        cause=cause,
        reason=reason,
        latency_ms=Int(latency_text) if latency_text != "" else -1,
        head_ms=Int(head_text) if head_text != "" else -1,
        total_ms=Int(total_text) if total_text != "" else -1,
        body_bytes=Int(bytes_text) if bytes_text != "" else -1,
        body_match=match_text,
        declared_bytes=Int(declared_text) if declared_text != "" else -1,
        length_match=length_text,
    )


def _classify_child_raise(text: String) -> String:
    """Bounded cause token for a raise observed inside the bounded child.

    The classification is derived from the rendered error text, never from a
    caller-supplied string, and is reported as a domain outcome — never as a
    peer close or as a harness success.
    """
    if text.find("refused") >= 0 or text.find("Refused") >= 0:
        return "connection_refused"
    if text.find("Timeout") >= 0 or text.find("timeout") >= 0:
        return "timeout"
    if text.find("descriptor") >= 0 or text.find("EBADF") >= 0:
        return "invalid_descriptor"
    return "raised"


def _report_prefix(kind: String, correlation: Int) -> String:
    return "report kind=" + kind + " correlation=" + String(correlation) + " "


def _long_token(count: Int) -> String:
    var text = ""
    for _ in range(count):
        text += "x"
    return text^


def _mutant_payload(copies: Int) -> String:
    """Deliberately misleading child report for the parent-consumer controls.

    This is a *child-producer* mutation only (ADR-0021 BC02): it changes what
    the forked child writes and never the parent consumer under test, which is
    the same consumer every real bounded call uses.
    """
    var line = "report kind=mutant correlation=0 outcome=ok status=200"
    var payload = line
    for index in range(1, copies):
        payload += "\n" + line
    return payload^


def _raw_request_text(path: String) -> String:
    return (
        "POST "
        + path
        + " HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 2\r\n"
        "connection: close\r\n\r\n{}"
    )


def _raw_status_code(head: String) raises -> Int:
    var prefix = "HTTP/1.1 "
    var start = head.find(prefix)
    if start < 0:
        return 0
    var base = start + prefix.byte_length()
    var length = 0
    var bytes = head.as_bytes()
    while base + length < len(bytes):
        var b = Int(bytes[base + length])
        if b < 48 or b > 57:
            break
        length += 1
    if length == 0:
        return 0
    return Int(String(head[byte = base : base + length]))


comptime RAW_MAX_HEADER_BYTES: Int = 65536
comptime RAW_MAX_BODY_BYTES: Int = 1048576
comptime RAW_READ_CHUNK_BYTES: Int = 1024


def _find_header_terminator(bytes: List[UInt8]) -> Int:
    """Index just past the first CRLFCRLF, or -1 while the head is incomplete.
    """
    var n = len(bytes)
    if n < 4:
        return -1
    for index in range(0, n - 3):
        if (
            Int(bytes[index]) == 13
            and Int(bytes[index + 1]) == 10
            and Int(bytes[index + 2]) == 13
            and Int(bytes[index + 3]) == 10
        ):
            return index + 4
    return -1


def _declared_content_length(head_text: String) raises -> Int:
    """Lexical Content-Length from a decoded head, or -1 when absent.

    Case-insensitive header name, ASCII digits only, with an explicit length
    guard. A malformed or oversized value is reported as absent rather than
    silently truncated; the caller treats that as an unknown declared size.
    """
    var marker = "content-length"
    var m = marker.byte_length()
    var bytes = head_text.as_bytes()
    var n = len(bytes)
    var base = 0
    while base + m <= n:
        var matched = True
        for k in range(m):
            var hb = Int(bytes[base + k])
            if hb >= 65 and hb <= 90:
                hb += 32
            if hb != Int(marker.as_bytes()[k]):
                matched = False
                break
        if matched:
            var i = base + m
            while i < n and (Int(bytes[i]) == 32 or Int(bytes[i]) == 9):
                i += 1
            if i < n and Int(bytes[i]) == 58:
                i += 1
                while i < n and (Int(bytes[i]) == 32 or Int(bytes[i]) == 9):
                    i += 1
                var j = i
                while j < n and Int(bytes[j]) >= 48 and Int(bytes[j]) <= 57:
                    j += 1
                if j == i or j - i > 9:
                    return -1
                return Int(String(head_text[byte=i:j]))
        base += 1
    return -1


def _bytes_contain_from(bytes: List[UInt8], start: Int, needle: String) -> Bool:
    """Byte-level substring search over an undecoded body buffer.

    Searching raw bytes (not a decoded String) keeps an invalid UTF-8 body or
    a multi-byte character split across reader chunks from corrupting the
    observation.
    """
    var nlen = needle.byte_length()
    if nlen == 0:
        return True
    var limit = len(bytes) - nlen
    if limit < start:
        return False
    var nb = needle.as_bytes()
    for base in range(start, limit + 1):
        var matched = True
        for k in range(nlen):
            if Int(bytes[base + k]) != Int(nb[k]):
                matched = False
                break
        if matched:
            return True
    return False


@fieldwise_init
struct RawAccounting(Movable):
    """Exact raw-response accounting from one bounded byte buffer.

    A non-empty ``problem`` is a bounded raw-observation failure (incomplete
    head or undecodable ASCII head); otherwise ``status``/``body_bytes``/
    ``body_match``/``declared_bytes``/``length_match`` describe the observation.
    """

    var problem: String
    var status: Int
    var body_bytes: Int
    var body_match: String
    var declared_bytes: Int
    var length_match: String


def account_raw_bytes(raw: List[UInt8], expect: String) raises -> RawAccounting:
    """Account header end, body byte count and length/match from raw bytes.

    The buffer is treated as one byte stream: packet/read boundaries are never
    protocol boundaries, and the body begins exactly after CRLFCRLF. A valid
    declared Content-Length is compared with the observed body byte count.
    """
    var head_end = _find_header_terminator(raw)
    if head_end < 0:
        return RawAccounting(
            "raw_head_incomplete", 0, 0, "unknown", -1, "unknown"
        )
    var head_bytes = List[UInt8]()
    for index in range(head_end):
        head_bytes.append(raw[index])
    var head_text = ""
    var decoded = True
    try:
        head_text = String(
            from_utf8=Span(ptr=head_bytes.unsafe_ptr(), length=len(head_bytes))
        )
    except:
        decoded = False
    if not decoded:
        return RawAccounting("raw_head_decode", 0, 0, "unknown", -1, "unknown")
    var body_bytes = len(raw) - head_end
    var declared = _declared_content_length(head_text)
    var match_text = "unknown"
    if expect != "":
        match_text = "yes" if _bytes_contain_from(
            raw, head_end, expect
        ) else "no"
    var length_match = "unknown"
    if declared >= 0:
        length_match = "yes" if body_bytes == declared else "no"
    var status = _raw_status_code(head_text)
    if status == 0:
        # A header block with no parseable HTTP/1.1 status line is a malformed
        # observation, never a successful call with an invented status.
        return RawAccounting(
            "raw_status_missing",
            0,
            body_bytes,
            match_text,
            declared,
            length_match,
        )
    return RawAccounting(
        "",
        status,
        body_bytes,
        match_text,
        declared,
        length_match,
    )


def _child_raw_head_body(
    head: String, port: Int, path: String, expect: String
) raises -> String:
    """Owned raw client: record head/body arrival timing for a scripted peer.

    The observation is independent of the product caller, which exposes only a
    parsed response, so a headers-before-body-stall claim can be proved from the
    wire while still running under the parent's finite deadline.

    RP01: bytes coalesced with the header terminator stay with the body, the
    accumulation is byte-oriented and bounded, and decode happens once over the
    complete buffer so a split multi-byte character is never misread as a
    packet boundary. A valid declared Content-Length bounds the read; the
    observed body byte count is compared with it and reported truthfully.
    """
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    var start = now_ms()
    client.write_all(Span[UInt8, _](_raw_request_text(path).as_bytes()))
    var raw = List[UInt8]()
    var buffer = InlineArray[Byte, RAW_READ_CHUNK_BYTES](fill=0)
    var head_end = -1
    while head_end < 0:
        var n = client.read(buffer.unsafe_ptr(), RAW_READ_CHUNK_BYTES)
        if n <= 0:
            client.close()
            return head + "outcome=fail cause=raw_eof reason=head_eof"
        for index in range(n):
            raw.append(UInt8(Int(buffer[index])))
        if len(raw) > RAW_MAX_HEADER_BYTES:
            client.close()
            return (
                head
                + "outcome=fail cause=raw_head_overflow reason=head_overflow"
            )
        head_end = _find_header_terminator(raw)
    var head_ms = now_ms() - start
    var declared = -1
    var head_bytes = List[UInt8]()
    for index in range(head_end):
        head_bytes.append(raw[index])
    var decoded = True
    try:
        declared = _declared_content_length(
            String(
                from_utf8=Span(
                    ptr=head_bytes.unsafe_ptr(), length=len(head_bytes)
                )
            )
        )
    except:
        decoded = False
    if not decoded:
        client.close()
        return head + "outcome=fail cause=raw_head_decode reason=head_decode"
    var body_bytes = len(raw) - head_end
    while True:
        if declared >= 0 and body_bytes >= declared:
            break
        if body_bytes >= RAW_MAX_BODY_BYTES:
            break
        var want = min(RAW_READ_CHUNK_BYTES, RAW_MAX_BODY_BYTES - body_bytes)
        var n2 = client.read(buffer.unsafe_ptr(), want)
        if n2 <= 0:
            break
        for index in range(n2):
            raw.append(UInt8(Int(buffer[index])))
        body_bytes += n2
    var total_ms = now_ms() - start
    client.close()
    var accounting = account_raw_bytes(raw^, expect)
    if accounting.problem != "":
        return (
            head
            + "outcome=fail cause="
            + accounting.problem
            + " reason="
            + accounting.problem
        )
    var declared_field = ""
    if accounting.declared_bytes >= 0:
        # A negative declared length is omitted rather than emitted, because the
        # report grammar accepts only non-negative numeric fields.
        declared_field = " declared_bytes=" + String(accounting.declared_bytes)
    return (
        head
        + "outcome=ok status="
        + String(accounting.status)
        + " head_ms="
        + String(head_ms)
        + " total_ms="
        + String(total_ms)
        + " body_bytes="
        + String(accounting.body_bytes)
        + " body_match="
        + accounting.body_match
        + " length_match="
        + accounting.length_match
        + declared_field
    )


def _child_report(
    kind: String,
    port: Int,
    timeout_ms: Int,
    correlation: Int,
    raw_path: String,
    raw_expect: String,
) raises -> String:
    """One bounded report line from inside the forked provider-call child."""
    var head = _report_prefix(kind, correlation)
    if kind == "never_return":
        # A deliberately non-returning control: it cannot complete within any
        # parent deadline, so the parent must stop and reap it.
        while True:
            sleep_ms(1000)
        return head + "outcome=fail cause=never reason=never_return"
    if kind == "max_local":
        var config = MaxLocalProviderConfig(
            base_url="http://127.0.0.1:" + String(port) + "/v1/",
            health_url="http://127.0.0.1:" + String(port) + "/health",
            model="max-local-query-rewrite",
            request_timeout_ms=timeout_ms,
        )
        var context = default_request_context()
        var body = build_query_rewrite_request_body(
            config, "eggs near me", context
        )
        var outcome = post_max_local_chat_completion(config, body)
        if outcome.failure:
            return (
                head
                + "outcome=fail cause="
                + outcome.failure.value().kind
                + " reason="
                + outcome.failure.value().reason
            )
        return (
            head
            + "outcome=ok status="
            + String(outcome.response.value().status)
            + " latency_ms="
            + String(outcome.response.value().latency_ms)
        )
    if kind == "jev":
        var payload = loads('{"model":"jev-1.13.0","state":"s","questions":{}}')
        var response = post_jev_systemone(
            "http://127.0.0.1:" + String(port), payload, timeout_ms
        )
        return head + "outcome=ok status=" + String(response.status)
    if kind == "raw_head_body" or kind == "raw_jev_head_body":
        return _child_raw_head_body(head, port, raw_path, raw_expect)
    return head + "outcome=fail cause=unknown_kind reason=unknown_kind"


@fieldwise_init
struct BoundedCallReport(Movable):
    """Bounded parent observation of one risky provider call.

    ``completed`` means exactly one complete bounded report was validated, no
    surplus byte followed it through EOF, and the child exited naturally with
    status zero inside one spawn-relative work budget. ``outcome`` is the
    declared call outcome (``ok`` or a characterized ``fail``); ``problem`` is
    non-empty only for a harness failure (malformed/duplicate/unterminated
    report, wrong correlation, early EOF, read/poll error, cap overflow,
    non-zero or signaled exit) and can never be reported as a completed call.
    ``stopped`` means the parent work budget expired first and the exact owned
    child was terminated and reaped under the separate bounded cleanup
    allowance.
    """

    var completed: Bool
    var stopped: Bool
    var outcome: String
    var status: Int
    var cause: String
    var reason: String
    var latency_ms: Int
    var head_ms: Int
    var total_ms: Int
    var body_bytes: Int
    var body_match: String
    var declared_bytes: Int
    var length_match: String
    var problem: String
    var report: String
    var elapsed_ms: Int
    var child_status: String
    var cleanup_proved: Bool

    def ok(self) -> Bool:
        return self.completed and self.outcome == "ok"

    def domain_failure(self) -> Bool:
        return self.completed and self.outcome == "fail"

    def describe(self) -> String:
        return (
            "completed="
            + String(self.completed)
            + " stopped="
            + String(self.stopped)
            + " outcome="
            + self.outcome
            + " status="
            + String(self.status)
            + " cause="
            + self.cause
            + " reason="
            + self.reason
            + " latency_ms="
            + String(self.latency_ms)
            + " head_ms="
            + String(self.head_ms)
            + " total_ms="
            + String(self.total_ms)
            + " body_bytes="
            + String(self.body_bytes)
            + " body_match="
            + self.body_match
            + " declared_bytes="
            + String(self.declared_bytes)
            + " length_match="
            + self.length_match
            + " problem="
            + (self.problem if self.problem != "" else "-")
            + " elapsed_ms="
            + String(self.elapsed_ms)
            + " child="
            + self.child_status
            + " cleanup="
            + ("proved" if self.cleanup_proved else "unproved")
            + " report="
            + self.report
        )


def run_bounded_call(
    kind: String,
    port: Int,
    timeout_ms: Int,
    deadline_ms: Int,
    mut guard: CleanupGuard,
    correlation: Int,
    raw_path: String = "/v1/chat/completions",
    raw_expect: String = "",
    fault_cleanup_failures: Int = 0,
    fault_wait_errors: Int = 0,
    fault_poll_eintrs: Int = 0,
    fault_poll_errors: Int = 0,
) raises -> BoundedCallReport:
    """Run one risky provider call under a parent-enforced finite deadline.

    One spawn-relative work budget covers the report read, the surplus drain and
    the natural child exit. Success requires all three plus a validated report;
    a report alone never justifies success, and a child the parent had to stop
    is never reported as completed. Cleanup keeps a bounded allowance separate
    from the work budget and never turns an expired or failed result into
    success.
    """
    if deadline_ms <= 0:
        raise Error("bounded call: invalid deadline")
    var pipe = make_pipe()
    var pid = fork_owned_or_close(pipe.copy())
    var start = now_ms()
    if pid == 0:
        close_fd(pipe.read_fd)
        _ = set_alarm(BOUNDED_CALL_CHILD_ALARM_SECONDS)
        var payload = ""
        var terminator = "\n"
        var exit_code = 0
        var self_signal = 0
        # Child-producer-only controls for the parent consumer: each produces a
        # deliberately incomplete, duplicated, non-zero-exit or over-running
        # child result, and the unchanged parent consumer must reject it.
        if kind == "mutate_exit7":
            payload = _mutant_payload(1)
            exit_code = 7
        elif kind == "mutate_unterminated":
            payload = _mutant_payload(1)
            terminator = ""
        elif kind == "mutate_duplicate":
            payload = _mutant_payload(2)
        elif kind == "mutate_huge":
            # Child-producer-only control: a report line past the bounded cap.
            payload = (
                _report_prefix("mutant", correlation)
                + "outcome=ok status=200 pad="
                + _long_token(5000)
            )
        elif kind == "mutate_valid":
            # A well-formed child report, used to reach the child-exit wait
            # phase with the bounded wait-fault seam.
            payload = (
                _report_prefix(kind, correlation) + "outcome=ok status=200"
            )
        elif kind == "mutate_silent":
            # RP02 child-producer-only control: the child closes its report pipe
            # without writing a byte, so the parent must report an early EOF
            # rather than an empty completed call.
            payload = ""
        elif kind == "mutate_signaled":
            # RP02 child-producer-only control: a valid report followed by a
            # signaled termination of the exact owned child; the parent must
            # report the signal, never a completed call.
            payload = (
                _report_prefix(kind, correlation) + "outcome=ok status=200"
            )
            self_signal = SIGKILL
        elif kind == "mutate_invalid_utf8":
            # RP02 child-producer-only control: a terminated report line whose
            # body contains an invalid UTF-8 byte, so the parent's bounded
            # decode rejects it instead of accepting a corrupted line.
            var bytes = List[UInt8]()
            var prefix = (
                _report_prefix(kind, correlation)
                + "outcome=ok status=200 mark="
            )
            for byte in prefix.as_bytes():
                bytes.append(UInt8(Int(byte)))
            bytes.append(UInt8(0xFF))
            bytes.append(UInt8(10))
            _ = write_raw_bytes(pipe.write_fd, bytes^)
            close_fd(pipe.write_fd)
            child_exit(0)
        elif kind == "mutate_late_exit":
            # RP02 child-producer-only control: the report pipe is closed after
            # one complete report while the child stays alive past the budget,
            # isolating the late-exit wait phase from any report drain.
            _ = write_raw(
                pipe.write_fd,
                _report_prefix(kind, correlation) + "outcome=ok status=200\n",
            )
            close_fd(pipe.write_fd)
            sleep_ms(2000)
            child_exit(0)
        elif kind == "mutate_delayed":
            _ = write_raw(pipe.write_fd, _mutant_payload(1) + "\n")
            sleep_ms(2000)
            close_fd(pipe.write_fd)
            child_exit(0)
        else:
            try:
                payload = _child_report(
                    kind, port, timeout_ms, correlation, raw_path, raw_expect
                )
            except e:
                payload = (
                    _report_prefix(kind, correlation)
                    + "outcome=fail cause=raised reason="
                    + _classify_child_raise(String(e))
                )
        if payload != "":
            _ = write_raw(pipe.write_fd, payload + terminator)
        close_fd(pipe.write_fd)
        if self_signal != 0:
            _ = kill_pid(owned_pid(), self_signal)
        child_exit(exit_code)

    close_fd(pipe.write_fd)
    var state = piped_child_state(
        pid, pipe.read_fd, deadline_ms, 1, UnsafePointer(to=guard)
    )
    # Bounded test-only fault seam: one forced unproved cleanup or transient
    # wait error against the real exact-owned child, so the retained-ownership
    # and recovery path is exercised rather than a synthetic identity.
    state.faults.cleanup_failures = fault_cleanup_failures
    state.faults.wait_errors = fault_wait_errors
    state.faults.poll_eintrs = fault_poll_eintrs
    state.faults.poll_errors = fault_poll_errors
    var deadline_hit = False
    var problem = ""
    var report_text = ""
    # 1. Exactly one complete, newline-terminated bounded report line.
    if state.work_remaining_ms() <= 0:
        deadline_hit = True
    if not deadline_hit:
        try:
            report_text = state.read_line(
                BOUNDED_CALL_MAX_REPORT_BYTES, state.work_remaining_ms()
            )
        except e:
            var cause = String(e)
            if cause == "read_deadline_expired":
                deadline_hit = True
            else:
                problem = cause
    if not deadline_hit and problem == "":
        if not state.last_terminated:
            if report_text.byte_length() == 0:
                problem = "report_early_eof"
            else:
                problem = "report_unterminated"
    # 2. No surplus bytes through EOF.
    if not deadline_hit and problem == "":
        try:
            var surplus = state.drain_surplus(
                BOUNDED_CALL_MAX_REPORT_BYTES, state.work_remaining_ms()
            )
            if surplus > 0:
                problem = "report_duplicate_report"
        except e:
            var cause = String(e)
            if cause == "read_deadline_expired":
                deadline_hit = True
            else:
                problem = cause
    # 3. Natural child exit zero inside the same work budget.
    var status = ProcessStatus("pending", False, -1, 0, 0, "")
    if not deadline_hit and problem == "":
        if state.work_remaining_ms() <= 0:
            deadline_hit = True
        else:
            status = state.wait_until(pid, state.work_remaining_ms())
            if status.state == "running" or status.state == "interrupted":
                deadline_hit = True
            elif status.state == "wait_error":
                problem = "child_wait_error"
            elif not status.exited:
                problem = "child_signal_" + String(status.signal)
            elif status.exit_code != 0:
                problem = "child_exit_" + String(status.exit_code)
    # Cleanup: bounded allowance, separate from the work budget. A terminal
    # status already observed for this exact child is cached and never re-waited
    # (a second wait could only report "gone"), and an unproved cleanup retains
    # the usable ownership handle instead of closing its descriptor.
    if not status.cleanup_proved():
        var terminal = state.terminate_once(pid, TERMINATION_GRACE_MS)
        state.status = terminal.copy()
        status = terminal.copy()
    if status.cleanup_proved():
        state.reaped = True
        state.guard[].resolve_pid(pid)
        state.close_reader()
    else:
        state.record_unproved(
            pid,
            state.report_fd,
            "bounded call cleanup unproved",
            "unreaped:" + status.describe(),
        )
    var cleanup_proved = status.cleanup_proved()
    # 4. Report validation for the declared call.
    var parsed = _empty_outcome("")
    var completed = (not deadline_hit) and problem == ""
    if completed:
        try:
            parsed = parse_bounded_report(report_text, kind, correlation)
        except:
            parsed = _empty_outcome("report_parse_raised")
        if not parsed.ok:
            completed = False
            problem = parsed.problem
    var elapsed_ms = now_ms() - start
    return BoundedCallReport(
        completed=completed,
        stopped=deadline_hit,
        outcome=parsed.outcome,
        status=parsed.status,
        cause=parsed.cause,
        reason=parsed.reason,
        latency_ms=parsed.latency_ms,
        head_ms=parsed.head_ms,
        total_ms=parsed.total_ms,
        body_bytes=parsed.body_bytes,
        body_match=parsed.body_match,
        declared_bytes=parsed.declared_bytes,
        length_match=parsed.length_match,
        problem=problem,
        report=String(report_text.strip()),
        elapsed_ms=elapsed_ms,
        child_status=status.describe(),
        cleanup_proved=cleanup_proved,
    )
