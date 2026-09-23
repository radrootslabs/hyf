"""Minimal test-only parent-bounded in-process call runner (H007 TC02).

An elapsed-time assertion after a synchronous provider call is not a parent
deadline: if the call never returns, the owning test hangs and the observed
behavior cannot be characterized. This helper forks one exact-owned child that
performs the risky provider call and writes a single bounded report line; the
parent enforces one finite deadline, drains that report and, on expiry,
terminates and reaps the exact owned child through the shared lifecycle
primitives. A deliberate never-returning control therefore becomes a bounded,
cause-specific parent observation ("stopped") instead of a hang.

It is test-only tooling: no product policy, schema, dependency or lock change.
"""

from std.collections import List

from json import Value, loads

from parent_lifecycle import (
    IO_DEADLINE_EXPIRED,
    POLLIN,
    TERMINATION_GRACE_MS,
    CleanupGuard,
    bytes_to_string,
    child_exit,
    close_fd,
    fork_owned_or_close,
    make_pipe,
    now_ms,
    poll_fd,
    read_fd,
    set_alarm,
    sleep_ms,
    terminate_owned,
    write_raw,
)

from hyf_core.request_context import default_request_context
from hyf_provider.client import post_max_local_chat_completion
from hyf_provider.config import MaxLocalProviderConfig
from hyf_provider.jev_client import post_jev_systemone
from hyf_provider.schema import build_query_rewrite_request_body


comptime BOUNDED_CALL_MAX_REPORT_BYTES = 4096
comptime BOUNDED_CALL_CHILD_ALARM_SECONDS = 120
comptime BOUNDED_CALL_POLL_SLICE_MS = 25


@fieldwise_init
struct BoundedCallReport(Movable):
    """Bounded parent observation of one risky provider call.

    ``completed`` means the child returned and reported inside the parent
    deadline; ``stopped`` means the parent deadline expired first and the parent
    terminated and reaped the exact owned child. ``report`` is the child's
    bounded single-line outcome, and ``cleanup_proved`` records that no waitable
    owned child remains.
    """

    var completed: Bool
    var stopped: Bool
    var report: String
    var elapsed_ms: Int
    var child_status: String
    var cleanup_proved: Bool

    def describe(self) -> String:
        return (
            "completed="
            + String(self.completed)
            + " stopped="
            + String(self.stopped)
            + " elapsed_ms="
            + String(self.elapsed_ms)
            + " child="
            + self.child_status
            + " cleanup="
            + ("proved" if self.cleanup_proved else "unproved")
            + " report="
            + self.report
        )


def _child_report(kind: String, port: Int, timeout_ms: Int) raises -> String:
    """One bounded report line from inside the forked provider-call child."""
    if kind == "never_return":
        # A deliberately non-returning control: it cannot complete within any
        # parent deadline, so the parent must stop and reap it.
        while True:
            sleep_ms(1000)
        return "never_returned"
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
                "fail max_local "
                + outcome.failure.value().kind
                + " "
                + outcome.failure.value().reason
            )
        return "ok max_local " + String(outcome.response.value().status)
    if kind == "jev":
        var payload = loads('{"model":"jev-1.13.0","state":"s","questions":{}}')
        var response = post_jev_systemone(
            "http://127.0.0.1:" + String(port), payload, timeout_ms
        )
        return "ok jev " + String(response.status)
    return "fail unknown_kind"


def _has_report_line(bytes: List[UInt8]) -> Bool:
    for index in range(len(bytes)):
        if Int(bytes[index]) == 10:
            return True
    return False


def run_bounded_call(
    kind: String,
    port: Int,
    timeout_ms: Int,
    deadline_ms: Int,
    mut guard: CleanupGuard,
) raises -> BoundedCallReport:
    """Run one risky provider call under a parent-enforced finite deadline.

    The child is exact-owned: the parent drains its bounded report and then
    always collects it (reaping a returned child, terminating a stopping one).
    Cleanup is reported through the caller-held guard, so an unproved collection
    cannot be silently discarded.
    """
    if deadline_ms <= 0:
        raise Error("bounded call: invalid deadline")
    var pipe = make_pipe()
    var pid = fork_owned_or_close(pipe.copy())
    var start = now_ms()
    if pid == 0:
        close_fd(pipe.read_fd)
        _ = set_alarm(BOUNDED_CALL_CHILD_ALARM_SECONDS)
        try:
            var report = _child_report(kind, port, timeout_ms)
            _ = write_raw(pipe.write_fd, report + "\n")
        except e:
            _ = write_raw(pipe.write_fd, "fail raised\n")
        close_fd(pipe.write_fd)
        child_exit(0)

    close_fd(pipe.write_fd)
    var pending = List[UInt8]()
    var eof = False
    var timed_out = False
    var buffer = InlineArray[Byte, 1024](fill=0)
    while not eof:
        var remaining = deadline_ms - (now_ms() - start)
        if remaining <= 0:
            timed_out = True
            break
        var slice = min(BOUNDED_CALL_POLL_SLICE_MS, remaining)
        if slice < 1:
            slice = 1
        var events = poll_fd(pipe.read_fd, POLLIN, slice)
        if events < 0:
            timed_out = True
            break
        if events == 0:
            if _has_report_line(pending):
                break
            continue
        var n = read_fd(pipe.read_fd, buffer.unsafe_ptr(), 1024, remaining)
        if n == IO_DEADLINE_EXPIRED or n < 0:
            timed_out = True
            break
        if n == 0:
            eof = True
            continue
        if len(pending) + n > BOUNDED_CALL_MAX_REPORT_BYTES:
            timed_out = True
            break
        for index in range(n):
            pending.append(UInt8(Int(buffer[index])))
        if _has_report_line(pending):
            break
    var report = bytes_to_string(pending)
    # Always collect the exact owned child: a returned child is reaped and a
    # never-returning child is stopped here by the parent.
    var status = terminate_owned(pid, TERMINATION_GRACE_MS)
    var cleanup_proved = status.cleanup_proved()
    if cleanup_proved:
        guard.resolve_pid(pid)
    else:
        guard.retain(
            pid,
            pipe.read_fd,
            "bounded call cleanup unproved " + status.describe(),
        )
    close_fd(pipe.read_fd)
    var elapsed_ms = now_ms() - start
    return BoundedCallReport(
        completed=(not timed_out) and report.byte_length() > 0,
        stopped=timed_out,
        report=String(report.strip()),
        elapsed_ms=elapsed_ms,
        child_status=status.describe(),
        cleanup_proved=cleanup_proved,
    )
