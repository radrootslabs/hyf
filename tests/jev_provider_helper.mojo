"""Strict scripted Jev provider HTTP fixture (ADR-0012 D29 / ADR-0014 D33).

Same parent-owned lifecycle and phase/case/reason reporting as the MaxLocal
fixture: parent-enforced startup/read/write/wait deadlines (FX06), bounded
reporting (FX07) and exception-safe reaping (FX08).
"""

from std.collections import List

from flare.net import SocketAddr
from flare.tcp import TcpListener
from flare.utils import usleep

from parent_lifecycle import (
    FIXTURE_DEFAULT_DEADLINE_MS,
    TERMINATION_GRACE_MS,
    CleanupGuard,
    PipedChildState,
    PipeFds,
    ProcessStatus,
    child_exit,
    close_fd,
    dup2_fd,
    finalize_owned_failure,
    fork_owned_or_close,
    make_pipe,
    parse_ready_or_cleanup,
    piped_child_state,
    set_alarm,
    sleep_ms,
    write_raw,
)
from strict_fixture import (
    STRICT_MAX_REPORT_BYTES,
    STRICT_COMPLETION_GRACE_MS,
    ConnectionReader,
    ExchangeScript,
    FramedRequest,
    ServeReport,
    authorization_reason,
    exchange_script,
    parse_report,
    render_response,
    report_line,
    report_status_matches_exit,
    serve_scripts,
    validate_convenience,
    verify_exchange,
)


comptime STUB_ALARM_SECONDS = 20
comptime JEV_INTENDED_PATH = "/v1/systemone"


def allowed_jev_paths() -> List[String]:
    var paths = List[String]()
    paths.append(JEV_INTENDED_PATH)
    return paths^


def allowed_jev_methods() -> List[String]:
    var methods = List[String]()
    methods.append("POST")
    return methods^


def require_bearer_for(mode: String) -> Bool:
    return False


def analysis() -> String:
    return (
        '{"model":"jev-1.13.0","answers":{'
        '"supply_status":{"type":"choice","choice":"offered","probabilities":{"offered":1.0,"forecast":0.0,"unclear":0.0},"confidence":1.0},'
        '"seconds_ok":{"type":"noul","noul":0.9},'
        '"culinary_fit":{"type":"score","score":2,"legend":{"0":"u","1":"l","2":"s"},"probabilities":{"0":0.0,"1":0.0,"2":1.0},"confidence":1.0}},'
        '"usage":{"input_tokens":10,"output_tokens":5}}'
    )


def _status(mode: String) -> Int:
    if mode == "rate_limit":
        return 429
    if mode == "server_error":
        return 500
    if mode == "overloaded":
        return 529
    if mode == "auth":
        return 401
    return 200


def _raw_response(mode: String) -> String:
    if mode == "truncated":
        return (
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n"
            "content-length: 999\r\nconnection: close\r\n\r\n"
            '{"model":"jev'
        )
    if mode == "redirect":
        return (
            "HTTP/1.1 302 Found\r\nlocation:"
            " http://127.0.0.1:1/steal\r\ncontent-length:"
            " 0\r\nconnection: close\r\n\r\n"
        )
    return ""


def _delay_ms(mode: String) -> Int:
    if mode == "slow":
        return 2000
    return 0


def _body(mode: String) -> String:
    if mode == "ok" or mode == "slow":
        return analysis()
    if mode == "rate_limit":
        return '{"error":{"message":"slow down"}}'
    if mode == "server_error":
        return '{"error":{"message":"boom"}}'
    if mode == "overloaded":
        return '{"error":{"message":"overloaded"}}'
    if mode == "auth":
        return '{"error":{"message":"bad key"}}'
    if mode == "malformed_json":
        return "not json"
    if mode == "model_mismatch":
        return analysis().replace("jev-1.13.0", "jev-other")
    return '{"error":{"message":"unsupported_mode"}}'


def _build_script(mode: String, framed: FramedRequest) -> ExchangeScript:
    var script = exchange_script(
        mode, framed.method, JEV_INTENDED_PATH, _status(mode), ""
    )
    script.delay_ms = _delay_ms(mode)
    script.close_connection = True
    script.require_bearer = require_bearer_for(mode)
    var raw = _raw_response(mode)
    if raw != "":
        script.raw_response = raw
    elif mode == "echo_authorization":
        var auth = authorization_reason(framed.headers_raw, True)
        if auth != "":
            script.status = 401
            script.response_body = '{"error":{"message":"' + auth + '"}}'
        else:
            script.echo_authorization = True
    else:
        script.response_body = _body(mode)
    return script^


def serve_jev(port: Int, mode: String, requests: Int) raises -> ServeReport:
    var allowed = allowed_jev_paths()
    var methods = allowed_jev_methods()
    var listener = TcpListener.bind(SocketAddr.localhost(UInt16(port)))
    var actual_port = Int(listener.local_addr().port)
    write_raw(1, "ready " + String(actual_port) + "\n")
    var request_count = 0
    var connection_count = 0
    try:
        while request_count < requests:
            var stream = listener.accept()
            connection_count += 1
            var reader = ConnectionReader(stream^)
            while request_count < requests:
                var framed = reader.read()
                if not framed.ok:
                    if framed.error == "empty":
                        if request_count < requests:
                            return ServeReport(
                                False,
                                "accounting",
                                mode,
                                "missing_exchanges",
                                request_count,
                                connection_count,
                            )
                        break
                    return ServeReport(
                        False,
                        "read",
                        mode,
                        framed.error,
                        request_count,
                        connection_count,
                    )
                var reason = validate_convenience(
                    framed, allowed, methods, False
                )
                if reason != "":
                    return ServeReport(
                        False,
                        "exchange",
                        mode,
                        reason,
                        request_count,
                        connection_count,
                    )
                var next_index = request_count + 1
                var script = _build_script(mode, framed)
                var verify = verify_exchange(script, framed)
                if verify != "":
                    return ServeReport(
                        False,
                        "exchange",
                        mode,
                        verify,
                        request_count,
                        connection_count,
                    )
                if next_index == requests:
                    var extra = reader.probe_completion(
                        STRICT_COMPLETION_GRACE_MS
                    )
                    if extra != "":
                        return ServeReport(
                            False,
                            "accounting",
                            mode,
                            extra,
                            request_count,
                            connection_count,
                        )
                request_count = next_index
                if script.delay_ms > 0:
                    usleep(script.delay_ms * 1000)
                reader.write_all(
                    render_response(
                        script,
                        framed.headers_raw,
                        request_count,
                        connection_count,
                    )
                )
                if script.close_connection:
                    break
        if request_count < requests:
            return ServeReport(
                False,
                "accounting",
                mode,
                "missing_exchanges",
                request_count,
                connection_count,
            )
        return ServeReport(
            True, "complete", mode, "ok", request_count, connection_count
        )
    except:
        return ServeReport(
            False, "read", mode, "io_error", request_count, connection_count
        )


# ── Parent side ─────────────────────────────────────────────────────────────


struct SpawnedJevStub(Movable):
    """Single-owner Jev fixture handle; the body receives a view."""

    var pid: Int
    var port: Int
    var state: PipedChildState

    def __init__(out self, pid: Int, port: Int, var state: PipedChildState):
        self.pid = pid
        self.port = port
        self.state = state^

    def __enter__(mut self) -> SpawnedJevStubView:
        return SpawnedJevStubView(self.pid, UnsafePointer(to=self))

    def __exit__(mut self):
        self.cleanup()

    def cleanup(mut self):
        """Fast, non-raising owned cleanup for assertion/error/early return.

        Ownership is released only once the child is provably collected. An
        uncertain wait keeps the handle retryable, records the failure in the
        required caller-held guard and retains the exact pid/report descriptor
        for recovery, instead of being silently marked complete. Never raises,
        so a body/assertion cause is preserved at scope exit.
        """
        if self.state.reaped:
            return
        var report_fd = self.state.report_fd
        var status = self.state.terminate_once(self.pid, TERMINATION_GRACE_MS)
        self.state.status = status.copy()
        if status.cleanup_proved():
            self.state.reaped = True
            self.state.close_reader()
            self.state.guard[].resolve_pid(self.pid)
            return
        self.state.record_unproved(
            self.pid,
            report_fd,
            "owned-child cleanup unproved",
            "unreaped:" + status.describe(),
        )

    def ok(self) -> Bool:
        return self.state.ok

    def phase(self) -> String:
        return String(self.state.phase)

    def failure_case(self) -> String:
        return String(self.state.case_label)

    def reason(self) -> String:
        return String(self.state.reason)

    def request_count(self) -> Int:
        return self.state.requests

    def connection_count(self) -> Int:
        return self.state.connections

    def cleanup_error(self) -> String:
        return String(self.state.cleanup_error)

    def describe(self) -> String:
        return (
            "phase="
            + self.state.phase
            + " case="
            + self.state.case_label
            + " reason="
            + self.state.reason
            + " requests="
            + String(self.state.requests)
            + " connections="
            + String(self.state.connections)
        )

    def status(mut self) -> ProcessStatus:
        """Observe child status without losing ownership or report truth.

        A terminal observation is cached so a later ``reap`` never performs a
        new wait on a stale/reused identity. A transient ``wait_error`` or any
        other nonterminal result is returned but deliberately *not* cached, so
        it stays retryable and cannot overwrite a valid terminal result.
        """
        if self.state.reaped:
            return self.state.status.copy()
        if self.state.observed_valid:
            return self.state.observed.copy()
        var st = self.state.wait_once(self.pid)
        if st.state == "reaped" or st.state == "gone":
            self.state.observed = st.copy()
            self.state.observed_valid = True
        return st^

    def reap(mut self):
        """Reap the owned child within one declared finite work budget.

        Never raises (so ``__exit__`` cannot mask a body error). Startup, wait,
        report line and EOF drain share ``deadline_ms`` measured from spawn: an
        expired budget fails with ``work_budget_expired`` and only the bounded
        cleanup allowance, and no fresh successful interval is granted.
        """
        if self.state.reaped:
            return
        if self.state.faults.wait_delay_ms > 0:
            sleep_ms(self.state.faults.wait_delay_ms)
            self.state.faults.wait_delay_ms = 0
        var remaining = self.state.work_remaining_ms()
        if remaining <= 0:
            self.state.store(
                False, "watchdog", "-", "work_budget_expired", 0, 0
            )
            var expired = self.state.terminate_once(
                self.pid, TERMINATION_GRACE_MS
            )
            self.state.status = expired.copy()
            if expired.cleanup_proved():
                self.state.reaped = True
                self.state.close_reader()
                self.state.guard[].resolve_pid(self.pid)
            else:
                self.state.reason = "work_budget_expired_unreaped"
                self.state.record_unproved(
                    self.pid,
                    self.state.report_fd,
                    "owned-child cleanup unproved",
                    "unreaped:" + expired.describe(),
                )
            return
        var status = ProcessStatus("pending", False, -1, 0, 0, "")
        if self.state.observed_valid:
            status = self.state.observed.copy()
        else:
            status = self.state.wait_until(self.pid, remaining)
        self.state.status = status.copy()
        if status.state == "running" or status.state == "interrupted":
            var term = self.state.terminate_once(self.pid, TERMINATION_GRACE_MS)
            self.state.status = term.copy()
            self.state.store(False, "watchdog", "-", "timeout", 0, 0)
            if term.cleanup_proved():
                self.state.reaped = True
                self.state.close_reader()
                self.state.guard[].resolve_pid(self.pid)
            else:
                self.state.reason = "timeout_unreaped"
                self.state.record_unproved(
                    self.pid,
                    self.state.report_fd,
                    "owned-child cleanup unproved",
                    "unreaped:" + term.describe(),
                )
            return
        if status.state == "gone":
            # No waitable owned child remains: cleanup is proved without a
            # signal and the report cannot be trusted, but ownership is done.
            self.state.store(False, "watchdog", "-", "gone", 0, 0)
            self.state.reaped = True
            self.state.close_reader()
            self.state.guard[].resolve_pid(self.pid)
            return
        if status.state == "wait_error":
            # Identity/ownership is unproved: retain it for a retry and record
            # the uncertainty instead of claiming the child was collected.
            self.state.store(False, "watchdog", "-", "wait_error", 0, 0)
            self.state.record_unproved(
                self.pid,
                self.state.report_fd,
                "owned-child wait unproved",
                "wait_error:" + status.error,
            )
            return
        if status.state != "reaped":
            # Unexpected nonterminal/unknown taxonomy: fail closed and keep the
            # exact ownership so a later retry can still collect it.
            self.state.store(False, "watchdog", "-", "unexpected_status", 0, 0)
            self.state.record_unproved(
                self.pid,
                self.state.report_fd,
                "owned-child unexpected status",
                "unexpected:" + status.describe(),
            )
            return
        var report_text = ""
        var report_error = ""
        var report_remaining = self.state.work_remaining_ms()
        if report_remaining <= 0:
            report_error = "report_budget_expired"
        else:
            try:
                report_text = self.state.read_line(
                    STRICT_MAX_REPORT_BYTES, report_remaining
                )
                if self.state.last_terminated:
                    var drain_remaining = self.state.work_remaining_ms()
                    if drain_remaining <= 0:
                        report_error = "drain_deadline_expired"
                    else:
                        var surplus = self.state.drain_surplus(
                            STRICT_MAX_REPORT_BYTES, drain_remaining
                        )
                        if surplus > 0:
                            report_error = "duplicate_report"
                elif report_text.byte_length() > 0:
                    # Bytes at EOF without a terminating newline are a
                    # truncated report, never a complete one.
                    report_error = "unterminated_report"
            except e:
                report_error = String(e)
        self.state.close_reader()
        if report_text == "" and report_error == "":
            if status.exited and status.exit_code == 0:
                self.state.store(False, "startup", "-", "missing_report", 0, 0)
            elif status.exited:
                self.state.store(
                    False,
                    "startup",
                    "-",
                    "exit_" + String(status.exit_code),
                    0,
                    0,
                )
            else:
                self.state.store(
                    False,
                    "watchdog",
                    "-",
                    "signal_" + String(status.signal),
                    0,
                    0,
                )
            self.state.reaped = True
            self.state.guard[].resolve_pid(self.pid)
            return
        if report_error != "":
            self.state.store(False, "parse", "-", report_error, -1, -1)
            self.state.reaped = True
            self.state.guard[].resolve_pid(self.pid)
            return
        var parsed = parse_report(report_text)
        if parsed.phase == "parse":
            self.state.store(False, "parse", "-", parsed.reason, -1, -1)
            self.state.reaped = True
            self.state.guard[].resolve_pid(self.pid)
            return
        self.state.store(
            parsed.ok,
            parsed.phase,
            parsed.case_label,
            parsed.reason,
            parsed.requests,
            parsed.connections,
        )
        if not report_status_matches_exit(
            status.exited, status.exit_code, parsed.ok
        ):
            self.state.ok = False
            self.state.phase = "startup"
            self.state.reason = "report_status_mismatch_" + status.describe()
        elif parsed.ok and parsed.requests != self.state.expected_requests:
            self.state.ok = False
            self.state.phase = "accounting"
            self.state.reason = "request_count_mismatch"
        elif parsed.ok and (
            parsed.connections < 1
            or parsed.connections > self.state.expected_requests
        ):
            self.state.ok = False
            self.state.phase = "accounting"
            self.state.reason = "connection_count_invalid"
        self.state.reaped = True
        self.state.guard[].resolve_pid(self.pid)

    def wait(mut self) raises:
        self.reap()
        if not self.state.ok:
            raise Error("fixture-failure " + self.describe())

    def terminate(mut self) raises:
        if self.state.reaped:
            return
        var report_fd = self.state.report_fd
        var status = self.state.terminate_once(self.pid, TERMINATION_GRACE_MS)
        self.state.status = status.copy()
        if status.cleanup_proved():
            self.state.reaped = True
            self.state.close_reader()
            self.state.guard[].resolve_pid(self.pid)
            return
        self.state.record_unproved(
            self.pid,
            report_fd,
            "owned-child cleanup unproved",
            "unreaped:" + status.describe(),
        )
        raise Error("lifecycle: owned child not reaped: " + status.describe())


struct SpawnedJevStubView(Movable):
    """Body-scope view of an owned Jev fixture handle."""

    var pid: Int
    var target: UnsafePointer[SpawnedJevStub, MutAnyOrigin]

    def __init__(
        out self, pid: Int, target: UnsafePointer[SpawnedJevStub, MutAnyOrigin]
    ):
        self.pid = pid
        self.target = target

    def ok(self) -> Bool:
        return self.target[].ok()

    def phase(self) -> String:
        return self.target[].phase()

    def failure_case(self) -> String:
        return self.target[].failure_case()

    def reason(self) -> String:
        return self.target[].reason()

    def request_count(self) -> Int:
        return self.target[].request_count()

    def connection_count(self) -> Int:
        return self.target[].connection_count()

    def cleanup_error(self) -> String:
        return self.target[].cleanup_error()

    def describe(self) -> String:
        return self.target[].describe()

    def status(mut self) -> ProcessStatus:
        return self.target[].status()

    def reap(mut self):
        self.target[].reap()

    def wait(mut self) raises:
        self.target[].wait()

    def terminate(mut self) raises:
        self.target[].terminate()

    def inject_cleanup_failure(mut self):
        """Test-only bounded fault: force one unproved cleanup attempt.

        The exact-owned child keeps running, so the follow-up retry exercises
        the real recoverable ownership path rather than a synthetic identity.
        """
        self.target[].state.faults.cleanup_failures += 1

    def inject_wait_error(mut self):
        """Test-only bounded fault: force one transient wait error."""
        self.target[].state.faults.wait_errors += 1

    def inject_nonterminal_status(mut self):
        """Test-only bounded fault: force one unexpected nonterminal status."""
        self.target[].state.faults.nonterminal += 1

    def inject_wait_delay_ms(mut self, ms: Int):
        """Test-only bounded fault: consume work-budget time in the wait phase.
        """
        self.target[].state.faults.wait_delay_ms = ms


@fieldwise_init
struct SpawnedJevStubAuto(Movable):
    var port: Int
    var stub: SpawnedJevStub

    def __enter__(mut self) -> SpawnedJevStubAutoView:
        return SpawnedJevStubAutoView(
            self.port,
            SpawnedJevStubView(self.stub.pid, UnsafePointer(to=self.stub)),
        )

    def __exit__(mut self):
        self.stub.cleanup()


struct SpawnedJevStubAutoView(Movable):
    """Body-scope view of an auto-port Jev fixture handle."""

    var port: Int
    var stub: SpawnedJevStubView

    def __init__(out self, port: Int, var stub: SpawnedJevStubView):
        self.port = port
        self.stub = stub^


def reserve_jev_port() raises -> Int:
    var listener = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(listener.local_addr().port)
    listener.close()
    return port


def spawn_jev_stub_auto(
    mode: String,
    requests: Int,
    mut guard: CleanupGuard,
    deadline_ms: Int = FIXTURE_DEFAULT_DEADLINE_MS,
) raises -> SpawnedJevStubAuto:
    var stub = _spawn_jev_stub(0, mode, requests, deadline_ms, guard)
    return SpawnedJevStubAuto(port=stub.port, stub=stub^)


def spawn_jev_stub(
    port: Int,
    mode: String,
    requests: Int,
    mut guard: CleanupGuard,
    deadline_ms: Int = FIXTURE_DEFAULT_DEADLINE_MS,
) raises -> SpawnedJevStub:
    return _spawn_jev_stub(port, mode, requests, deadline_ms, guard)


def serve_jev_scripted(
    port: Int, var scripts: List[ExchangeScript]
) raises -> ServeReport:
    var listener = TcpListener.bind(SocketAddr.localhost(UInt16(port)))
    var actual_port = Int(listener.local_addr().port)
    write_raw(1, "ready " + String(actual_port) + "\n")
    return serve_scripts(listener, scripts^, "scripted")


def spawn_jev_scripted_auto(
    var scripts: List[ExchangeScript],
    mut guard: CleanupGuard,
    deadline_ms: Int = FIXTURE_DEFAULT_DEADLINE_MS,
) raises -> SpawnedJevStubAuto:
    return _spawn_jev_scripted(0, scripts^, deadline_ms, guard)


def _spawn_child_or_cleanup(
    pipe: PipeFds,
    pid: Int,
    mode: String,
    deadline_ms: Int,
    requests: Int,
    guard: UnsafePointer[CleanupGuard, MutAnyOrigin],
) raises -> SpawnedJevStub:
    """Build the owned state, read exact readiness, or clean up and raise."""
    var state = piped_child_state(
        pid, pipe.read_fd, deadline_ms, requests, guard
    )
    var ready_line = ""
    try:
        ready_line = state.read_line(STRICT_MAX_REPORT_BYTES, deadline_ms)
    except e:
        var st = finalize_owned_failure(
            state, pid, "jev startup readiness cleanup unproved"
        )
        raise Error(
            "jev stub readiness failed ("
            + String(e)
            + " pid="
            + String(pid)
            + " / "
            + st.describe()
            + " cleanup="
            + ("proved" if st.cleanup_proved() else "unreaped")
            + ")"
        )
    var reported_port = 0
    try:
        reported_port = parse_ready_or_cleanup(pid, ready_line, 256)
    except e:
        var st = finalize_owned_failure(
            state, pid, "jev startup malformed-readiness cleanup unproved"
        )
        raise Error(
            "jev stub malformed readiness ("
            + String(e)
            + " pid="
            + String(pid)
            + " cleanup="
            + ("proved" if st.cleanup_proved() else "unreaped")
            + ")"
        )
    _ = mode
    return SpawnedJevStub(pid, reported_port, state^)


def _spawn_jev_scripted(
    port: Int,
    var scripts: List[ExchangeScript],
    deadline_ms: Int,
    mut guard: CleanupGuard,
) raises -> SpawnedJevStubAuto:
    var total = len(scripts)
    var pipe = make_pipe()
    var pid = fork_owned_or_close(pipe.copy())
    if pid == 0:
        if dup2_fd(pipe.write_fd, 1) < 0:
            child_exit(126)
        close_fd(pipe.read_fd)
        close_fd(pipe.write_fd)
        _ = set_alarm(STUB_ALARM_SECONDS)
        try:
            var report = serve_jev_scripted(port, scripts^)
            _ = write_raw(1, report_line(report) + "\n")
            child_exit(0 if report.ok else 125)
        except:
            var failed = ServeReport(
                False, "startup", "scripted", "serve_failed", 0, 0
            )
            _ = write_raw(1, report_line(failed) + "\n")
            child_exit(125)
    close_fd(pipe.write_fd)
    var stub = _spawn_child_or_cleanup(
        pipe, pid, "scripted", deadline_ms, total, UnsafePointer(to=guard)
    )
    return SpawnedJevStubAuto(port=stub.port, stub=stub^)


def _spawn_jev_stub(
    port: Int,
    mode: String,
    requests: Int,
    deadline_ms: Int,
    mut guard: CleanupGuard,
) raises -> SpawnedJevStub:
    var pipe = make_pipe()
    var pid = fork_owned_or_close(pipe.copy())
    if pid == 0:
        if dup2_fd(pipe.write_fd, 1) < 0:
            child_exit(126)
        close_fd(pipe.read_fd)
        close_fd(pipe.write_fd)
        _ = set_alarm(STUB_ALARM_SECONDS)
        try:
            var report = serve_jev(port, mode, requests)
            _ = write_raw(1, report_line(report) + "\n")
            child_exit(0 if report.ok else 125)
        except:
            var failed = ServeReport(
                False, "startup", mode, "serve_failed", 0, 0
            )
            _ = write_raw(1, report_line(failed) + "\n")
            child_exit(125)
    close_fd(pipe.write_fd)
    return _spawn_child_or_cleanup(
        pipe, pid, mode, deadline_ms, requests, UnsafePointer(to=guard)
    )
