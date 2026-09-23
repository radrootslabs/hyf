"""Strict scripted MaxLocal HTTP fixture (ADR-0012 D29 / ADR-0014 D33).

Owned by the parent test process: startup, read, write and wait all have
parent-enforced deadlines (FX06) and cleanup is exception-safe (FX08). Fixture
verification failures are reported with a bounded phase/case/reason so tests
can distinguish intended rejections from compiler/loader/startup/signal
failures (FX07).
"""

from std.collections import List
from std.memory import ArcPointer

from flare.net import SocketAddr
from flare.tcp import TcpListener
from flare.utils import usleep

from parent_lifecycle import (
    FIXTURE_DEFAULT_DEADLINE_MS,
    TERMINATION_GRACE_MS,
    CleanupLedger,
    PipedChildState,
    ProcessStatus,
    child_exit,
    close_fd,
    dup2_fd,
    fork_owned_or_close,
    make_pipe,
    now_ms,
    parse_ready_or_cleanup,
    piped_child_state,
    set_alarm,
    terminate_owned,
    wait_bounded,
    wait_nohang,
    write_raw,
)
from strict_fixture import (
    STRICT_MAX_REPORT_BYTES,
    json_escape,
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


def allowed_max_local_paths() -> List[String]:
    var paths = List[String]()
    paths.append("/health")
    paths.append("/v1/chat/completions")
    return paths^


def allowed_max_local_methods() -> List[String]:
    var methods = List[String]()
    methods.append("GET")
    methods.append("POST")
    return methods^


def require_bearer_for(mode: String) -> Bool:
    # Convenience modes never bypass route/method validation; the
    # echo_authorization mode validates the exact Authorization header inside
    # its own handler and answers 401 when it is missing/duplicated/spoofed.
    return False


# ── Scripted response bodies ────────────────────────────────────────────────


def _chat_completion(body: String) -> String:
    return '{"choices":[{"message":{"content":' + json_escape(body) + "}}]}"


def query_rewrite_analysis() -> String:
    return (
        '{"original_text":"local apples pickup weekend",'
        '"normalized_text":"local apples pickup weekend",'
        '"rewritten_text":"apples pickup weekend",'
        '"query_terms":["apples","pickup","weekend"],'
        '"normalization_signals":["lowercase","local_intent_detected"],'
        '"ranking_hints":["prefer_local_results","prefer_pickup"],'
        '"extracted_filters":{'
        '"local_intent":true,'
        '"fulfillment":"pickup",'
        '"time_window":"weekend"'
        "}}"
    )


def _schema_invalid_analysis() -> String:
    return (
        '{"original_text":"local apples pickup weekend",'
        '"normalized_text":"local apples pickup weekend",'
        '"query_terms":["apples","pickup","weekend"],'
        '"normalization_signals":["lowercase","local_intent_detected"],'
        '"ranking_hints":["prefer_local_results","prefer_pickup"],'
        '"extracted_filters":{'
        '"local_intent":true,'
        '"fulfillment":"pickup",'
        '"time_window":"weekend"'
        "}}"
    )


def _health_status(mode: String) -> Int:
    if mode == "health_non_2xx":
        return 503
    return 200


def _chat_status(mode: String) -> Int:
    if mode == "query_rewrite_non_2xx":
        return 503
    return 200


def _raw_response(mode: String, path: String) -> String:
    if path == "/health" and mode == "health_malformed_http":
        return "not an http response\r\n\r\n"
    if (
        path == "/v1/chat/completions"
        and mode == "query_rewrite_malformed_http"
    ):
        return "not an http response\r\n\r\n"
    return ""


def _delay_ms(mode: String, path: String) -> Int:
    if path == "/health" and mode == "health_timeout":
        return 1000
    if path == "/health" and mode == "query_rewrite_remaining_deadline_timeout":
        return 200
    if path == "/v1/chat/completions":
        if mode == "query_rewrite_timeout":
            return 2000
        if mode == "query_rewrite_remaining_deadline_timeout":
            return 400
    if mode == "stall":
        return 30000
    return 0


def _chat_body(
    mode: String, request_index: Int, connection_index: Int
) -> String:
    if mode == "count_requests":
        return (
            '{"request_index":'
            + String(request_index)
            + ',"connection_index":'
            + String(connection_index)
            + "}"
        )
    if mode == "query_rewrite_ok":
        return _chat_completion(query_rewrite_analysis())
    if mode == "query_rewrite_non_2xx":
        return '{"error":{"message":"provider unavailable"}}'
    if mode == "query_rewrite_invalid_json":
        return '{"choices":[{"message":{"content":"not json"}}]}'
    if mode == "query_rewrite_schema_invalid":
        return _chat_completion(_schema_invalid_analysis())
    if mode == "query_rewrite_top_level_string":
        return '"not object"'
    if mode == "query_rewrite_top_level_array":
        return "[]"
    if mode == "query_rewrite_top_level_null":
        return "null"
    if mode == "query_rewrite_empty_choices":
        return '{"choices":[]}'
    if mode == "query_rewrite_missing_content":
        return '{"choices":[{"message":{}}]}'
    if mode == "query_rewrite_error_payload":
        return '{"error":{"message":"provider refusal"}}'
    if mode in (
        "query_rewrite_timeout",
        "query_rewrite_remaining_deadline_timeout",
    ):
        return _chat_completion(query_rewrite_analysis())
    return '{"error":"unsupported_mode"}'


def _health_body(mode: String) -> String:
    if mode == "health_non_2xx":
        return '{"status":"unavailable"}'
    return '{"status":"ok"}'


def _build_script(
    mode: String,
    framed: FramedRequest,
    request_index: Int,
    connection_index: Int,
) -> ExchangeScript:
    var path = framed.path
    var status = _chat_status(mode)
    if path == "/health":
        status = _health_status(mode)
    var script = exchange_script(mode, framed.method, path, status, "")
    script.delay_ms = _delay_ms(mode, path)
    script.close_connection = True
    script.require_bearer = require_bearer_for(mode)
    var raw = _raw_response(mode, path)
    if raw != "":
        script.raw_response = raw
    elif mode == "echo_authorization" and path == "/v1/chat/completions":
        var auth = authorization_reason(framed.headers_raw, True)
        if auth != "":
            script.status = 401
            script.response_body = '{"error":"' + auth + '"}'
        else:
            script.echo_authorization = True
    elif mode == "echo_body_bytes" and path == "/v1/chat/completions":
        script.response_body = (
            '{"received_bytes":' + String(framed.body.byte_length()) + "}"
        )
    elif path == "/health":
        script.response_body = _health_body(mode)
    else:
        script.response_body = _chat_body(mode, request_index, connection_index)
    return script^


# ── Child serve loop ────────────────────────────────────────────────────────


def serve_max_local(
    port: Int, mode: String, requests: Int
) raises -> ServeReport:
    var allowed = allowed_max_local_paths()
    var methods = allowed_max_local_methods()
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
                    framed, allowed, methods, require_bearer_for(mode)
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
                var script = _build_script(
                    mode, framed, next_index, connection_count
                )
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


struct SpawnedMaxLocalStub(Movable):
    """Single-owner MaxLocal fixture handle.

    The body receives a :class:`SpawnedMaxLocalView` from ``__enter__`` while
    ``__exit__`` on this manager performs owned cleanup, so parent assertion,
    exception and early-return paths all reap and close the child without any
    shared heap state. Use ``with spawn_max_local_stub(...) as stub:``.
    """

    var pid: Int
    var port: Int
    var state: PipedChildState

    def __init__(out self, pid: Int, port: Int, var state: PipedChildState):
        self.pid = pid
        self.port = port
        self.state = state^

    def __enter__(mut self) -> SpawnedMaxLocalView:
        return SpawnedMaxLocalView(self.pid, self.port, UnsafePointer(to=self))

    def __exit__(mut self):
        self.cleanup()

    def cleanup(mut self):
        """Fast, non-raising owned cleanup for assertion/error/early return.

        Ownership is released only once the child is provably collected. An
        uncertain wait keeps the handle retryable and records the failure in
        the caller-owned ledger so it stays observable after scope exit
        instead of being silently marked complete.
        """
        if self.state.reaped:
            return
        var status = terminate_owned(self.pid, TERMINATION_GRACE_MS)
        self.state.status = status.copy()
        if status.cleanup_proved():
            self.state.reaped = True
            self.state.close_reader()
            return
        self.state.cleanup_error = "unreaped:" + status.describe()
        self.state.ledger.record(
            "owned-child cleanup unproved " + status.describe()
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

        If the child has already exited, the observed reap status is cached in
        ``state.observed`` rather than claimed as a completed reap, so a later
        ``reap()`` still reads the report and evaluates exit/accounting truth.
        """
        if self.state.reaped:
            return self.state.status.copy()
        if self.state.observed_valid:
            return self.state.observed.copy()
        var st = wait_nohang(self.pid)
        if st.state == "running" or st.state == "interrupted":
            return st^
        self.state.observed = st.copy()
        self.state.observed_valid = True
        return st^

    def reap(mut self):
        """Reap the owned child and strictly decode its bounded report.

        Never raises (so ``__exit__`` cannot mask a body error). Success
        requires a complete strictly parsed report, matching child exit status
        and exact request accounting; missing/truncated/mismatched reports and
        nonzero exit or signals fail explicitly.
        """
        if self.state.reaped:
            return
        var remaining = self.state.deadline_ms - (
            now_ms() - self.state.spawn_ms
        )
        if remaining < 1:
            remaining = 1
        var status = wait_bounded(self.pid, remaining)
        if self.state.observed_valid:
            status = self.state.observed.copy()
        self.state.status = status.copy()
        if status.state == "running" or status.state == "interrupted":
            var term = terminate_owned(self.pid, TERMINATION_GRACE_MS)
            self.state.status = term.copy()
            self.state.store(False, "watchdog", "-", "timeout", 0, 0)
            if term.cleanup_proved():
                self.state.reaped = True
                self.state.close_reader()
            else:
                self.state.cleanup_error = "unreaped:" + term.describe()
                self.state.reason = "timeout_unreaped"
                self.state.ledger.record(
                    "owned-child cleanup unproved " + term.describe()
                )
            return
        if status.state == "gone":
            # No waitable owned child remains: cleanup is proved without a
            # signal and the report cannot be trusted, but ownership is done.
            self.state.store(False, "watchdog", "-", "gone", 0, 0)
            self.state.reaped = True
            self.state.close_reader()
            return
        if status.state == "wait_error":
            # Identity/ownership is unproved: retain it for a retry and record
            # the uncertainty instead of claiming the child was collected.
            self.state.store(False, "watchdog", "-", "wait_error", 0, 0)
            self.state.cleanup_error = "wait_error:" + status.error
            self.state.ledger.record(
                "owned-child wait unproved " + status.describe()
            )
            return
        var report_text = ""
        var report_error = ""
        try:
            report_text = self.state.read_line(STRICT_MAX_REPORT_BYTES, 1000)
            if self.state.last_terminated:
                var surplus = self.state.drain_surplus(
                    STRICT_MAX_REPORT_BYTES, 1000
                )
                if surplus > 0:
                    report_error = "duplicate_report"
            elif report_text.byte_length() > 0:
                # Bytes at EOF without a terminating newline are a truncated
                # report, never a complete one.
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
            return
        if report_error != "":
            self.state.store(False, "parse", "-", report_error, -1, -1)
            self.state.reaped = True
            return
        var parsed = parse_report(report_text)
        if parsed.phase == "parse":
            self.state.store(False, "parse", "-", parsed.reason, -1, -1)
            self.state.reaped = True
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

    def wait(mut self) raises:
        self.reap()
        if not self.state.ok:
            raise Error("fixture-failure " + self.describe())

    def terminate(mut self) raises:
        if self.state.reaped:
            return
        var status = terminate_owned(self.pid, TERMINATION_GRACE_MS)
        self.state.status = status.copy()
        if status.cleanup_proved():
            self.state.reaped = True
            self.state.close_reader()
            return
        self.state.cleanup_error = "unreaped:" + status.describe()
        self.state.ledger.record(
            "owned-child cleanup unproved " + status.describe()
        )
        raise Error("lifecycle: owned child not reaped: " + status.describe())


struct SpawnedMaxLocalView(Movable):
    """Body-scope view of an owned MaxLocal fixture handle."""

    var pid: Int
    var port: Int
    var target: UnsafePointer[SpawnedMaxLocalStub, MutAnyOrigin]

    def __init__(
        out self,
        pid: Int,
        port: Int,
        target: UnsafePointer[SpawnedMaxLocalStub, MutAnyOrigin],
    ):
        self.pid = pid
        self.port = port
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


def reserve_loopback_port() raises -> Int:
    var listener = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(listener.local_addr().port)
    listener.close()
    return port


def _serve_max_local_for(
    port: Int,
    var scripts: List[ExchangeScript],
    mode: String,
    requests: Int,
    scripted: Bool,
) raises -> ServeReport:
    if scripted:
        return serve_max_local_scripted(port, scripts^)
    return serve_max_local(port, mode, requests)


def serve_max_local_scripted(
    port: Int, var scripts: List[ExchangeScript]
) raises -> ServeReport:
    var listener = TcpListener.bind(SocketAddr.localhost(UInt16(port)))
    var actual_port = Int(listener.local_addr().port)
    write_raw(1, "ready " + String(actual_port) + "\n")
    return serve_scripts(listener, scripts^, "scripted")


def spawn_max_local_stub(
    port: Int,
    mode: String,
    requests: Int,
    deadline_ms: Int = FIXTURE_DEFAULT_DEADLINE_MS,
    ledger: CleanupLedger = CleanupLedger(),
) raises -> SpawnedMaxLocalStub:
    var scripts = List[ExchangeScript]()
    return _spawn_max_local(
        port, scripts^, mode, requests, False, deadline_ms, ledger
    )


def spawn_max_local_scripted(
    port: Int,
    var scripts: List[ExchangeScript],
    deadline_ms: Int = FIXTURE_DEFAULT_DEADLINE_MS,
    ledger: CleanupLedger = CleanupLedger(),
) raises -> SpawnedMaxLocalStub:
    return _spawn_max_local(
        port, scripts^, "scripted", len(scripts), True, deadline_ms, ledger
    )


def _spawn_max_local(
    port: Int,
    var scripts: List[ExchangeScript],
    mode: String,
    requests: Int,
    scripted: Bool,
    deadline_ms: Int,
    ledger: CleanupLedger,
) raises -> SpawnedMaxLocalStub:
    var pipe = make_pipe()
    var pid = fork_owned_or_close(pipe.copy())
    if pid == 0:
        if dup2_fd(pipe.write_fd, 1) < 0:
            child_exit(126)
        close_fd(pipe.read_fd)
        close_fd(pipe.write_fd)
        _ = set_alarm(STUB_ALARM_SECONDS)
        try:
            var report = _serve_max_local_for(
                port, scripts^, mode, requests, scripted
            )
            write_raw(1, report_line(report) + "\n")
            child_exit(0 if report.ok else 125)
        except:
            var failed = ServeReport(
                False, "startup", mode, "serve_failed", 0, 0
            )
            write_raw(1, report_line(failed) + "\n")
            child_exit(125)
    close_fd(pipe.write_fd)
    var state = piped_child_state(
        pid, pipe.read_fd, deadline_ms, requests, ledger
    )
    var ready_line = ""
    try:
        ready_line = state.read_line(STRICT_MAX_REPORT_BYTES, deadline_ms)
    except e:
        var st = terminate_owned(pid, TERMINATION_GRACE_MS)
        state.status = st.copy()
        state.reaped = True
        state.close_reader()
        raise Error(
            "max_local stub readiness failed ("
            + String(e)
            + " / "
            + st.describe()
            + ")"
        )
    var reported_port = 0
    try:
        reported_port = parse_ready_or_cleanup(pid, ready_line, 256)
    except e:
        state.reaped = True
        state.close_reader()
        raise Error("max_local stub malformed readiness (" + String(e) + ")")
    return SpawnedMaxLocalStub(pid, reported_port, state^)
