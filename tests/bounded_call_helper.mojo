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
    TERMINATION_GRACE_MS,
    CleanupGuard,
    ProcessStatus,
    child_exit,
    close_fd,
    fork_owned_or_close,
    make_pipe,
    now_ms,
    piped_child_state,
    read_fd,
    set_alarm,
    sleep_ms,
    write_raw,
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
    return key == "body_bytes" or key == "body_match"


def _field_numeric(key: String) -> Bool:
    if key == "status" or key == "correlation" or key == "latency_ms":
        return True
    if key == "head_ms" or key == "total_ms":
        return True
    return key == "body_bytes"


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


def _child_raw_head_body(
    head: String, port: Int, path: String, expect: String
) raises -> String:
    """Owned raw client: record head/body arrival timing for a scripted peer.

    The observation is independent of the product caller, which exposes only a
    parsed response, so a headers-before-body-stall claim can be proved from the
    wire while still running under the parent's finite deadline.
    """
    var client = TcpStream.connect(SocketAddr.localhost(UInt16(port)))
    var start = now_ms()
    client.write_all(Span[UInt8, _](_raw_request_text(path).as_bytes()))
    var head_text = String("")
    var buffer = InlineArray[Byte, 1024](fill=0)
    while head_text.find("\r\n\r\n") < 0:
        var n = client.read(buffer.unsafe_ptr(), 1024)
        if n <= 0:
            client.close()
            return head + "outcome=fail cause=raw_eof reason=head_eof"
        head_text += String(
            unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n))
        )
    var head_ms = now_ms() - start
    var body = String("")
    while True:
        var n2 = client.read(buffer.unsafe_ptr(), 1024)
        if n2 <= 0:
            break
        body += String(
            unsafe_from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(n2))
        )
    var total_ms = now_ms() - start
    client.close()
    var body_match = "unknown"
    if expect != "":
        body_match = "yes" if body.find(expect) >= 0 else "no"
    return (
        head
        + "outcome=ok status="
        + String(_raw_status_code(head_text))
        + " head_ms="
        + String(head_ms)
        + " total_ms="
        + String(total_ms)
        + " body_bytes="
        + String(body.byte_length())
        + " body_match="
        + body_match
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
        problem=problem,
        report=String(report_text.strip()),
        elapsed_ms=elapsed_ms,
        child_status=status.describe(),
        cleanup_proved=cleanup_proved,
    )
