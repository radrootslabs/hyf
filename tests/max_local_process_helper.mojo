"""Strict scripted MaxLocal HTTP fixture (ADR-0012 D29 / ADR-0014 D33).

Owned by the parent test process: startup, read, write and wait all have
parent-enforced deadlines (FX06) and cleanup is exception-safe (FX08). Fixture
verification failures are reported with a bounded phase/case/reason so tests
can distinguish intended rejections from compiler/loader/startup/signal
failures (FX07).
"""

from std.collections import List

from flare.net import SocketAddr
from flare.tcp import TcpListener
from flare.utils import usleep

from parent_lifecycle import (
    FIXTURE_DEFAULT_DEADLINE_MS,
    TERMINATION_GRACE_MS,
    ProcessStatus,
    child_exit,
    close_fd,
    dup2_fd,
    fork_pid,
    make_pipe,
    read_line_bounded,
    set_alarm,
    terminate_owned,
    wait_bounded,
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
    var pid: Int
    var port: Int
    var _report_fd: Int
    var _deadline_ms: Int
    var _reaped: Bool
    var _ok: Bool
    var _phase: String
    var _case: String
    var _reason: String
    var _requests: Int
    var _connections: Int

    def __init__(
        out self, pid: Int, port: Int, report_fd: Int, deadline_ms: Int
    ):
        self.pid = pid
        self.port = port
        self._report_fd = report_fd
        self._deadline_ms = deadline_ms
        self._reaped = False
        self._ok = False
        self._phase = "pending"
        self._case = "-"
        self._reason = "not_reaped"
        self._requests = 0
        self._connections = 0

    def ok(self) -> Bool:
        return self._ok

    def phase(self) -> String:
        return String(self._phase)

    def failure_case(self) -> String:
        return String(self._case)

    def reason(self) -> String:
        return String(self._reason)

    def request_count(self) -> Int:
        return self._requests

    def connection_count(self) -> Int:
        return self._connections

    def describe(self) -> String:
        return (
            "phase="
            + self._phase
            + " case="
            + self._case
            + " reason="
            + self._reason
            + " requests="
            + String(self._requests)
            + " connections="
            + String(self._connections)
        )

    def status(self) -> ProcessStatus:
        return wait_bounded(self.pid, 0)

    def _store(
        mut self,
        ok: Bool,
        phase: String,
        case_label: String,
        reason: String,
        requests: Int,
        connections: Int,
    ):
        self._ok = ok
        self._phase = String(phase)
        self._case = String(case_label)
        self._reason = String(reason)
        self._requests = requests
        self._connections = connections

    def reap(mut self):
        """Reap the owned child and decode its bounded report (never raises)."""
        if self._reaped:
            return
        var st = wait_bounded(self.pid, self._deadline_ms)
        var report_text = ""
        if st.state == "running":
            var term = terminate_owned(self.pid, TERMINATION_GRACE_MS)
            self._store(False, "watchdog", "-", "timeout", 0, 0)
            if not term.reaped():
                self._reason = "unreaped:" + term.describe()
            self._reaped = True
            close_fd(self._report_fd)
            return
        if self._report_fd >= 0:
            try:
                report_text = read_line_bounded(
                    self._report_fd, STRICT_MAX_REPORT_BYTES, 1000
                )
            except:
                report_text = ""
        if report_text.startswith("result "):
            var parsed = parse_report(report_text)
            self._store(
                parsed.ok,
                parsed.phase,
                parsed.case_label,
                parsed.reason,
                parsed.requests,
                parsed.connections,
            )
        elif st.exited and st.exit_code == 0:
            self._store(True, "complete", "-", "ok", 0, 0)
        elif st.exited:
            self._store(
                False,
                "startup",
                "-",
                "exit_" + String(st.exit_code),
                0,
                0,
            )
        else:
            self._store(
                False, "watchdog", "-", "signal_" + String(st.signal), 0, 0
            )
        self._reaped = True
        close_fd(self._report_fd)

    def wait(mut self) raises:
        self.reap()
        if not self._ok:
            raise Error("fixture-failure " + self.describe())

    def terminate(mut self) raises:
        if self._reaped:
            return
        var st = terminate_owned(self.pid, TERMINATION_GRACE_MS)
        if not st.reaped():
            raise Error("lifecycle: owned child not reaped: " + st.describe())
        self._reaped = True
        close_fd(self._report_fd)


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


def _read_ready_line(fd: Int, deadline_ms: Int) -> String:
    try:
        return read_line_bounded(fd, 256, deadline_ms)
    except:
        return ""


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
) raises -> SpawnedMaxLocalStub:
    var scripts = List[ExchangeScript]()
    return _spawn_max_local(port, scripts^, mode, requests, False, deadline_ms)


def spawn_max_local_scripted(
    port: Int,
    var scripts: List[ExchangeScript],
    deadline_ms: Int = FIXTURE_DEFAULT_DEADLINE_MS,
) raises -> SpawnedMaxLocalStub:
    return _spawn_max_local(
        port, scripts^, "scripted", len(scripts), True, deadline_ms
    )


def _spawn_max_local(
    port: Int,
    var scripts: List[ExchangeScript],
    mode: String,
    requests: Int,
    scripted: Bool,
    deadline_ms: Int,
) raises -> SpawnedMaxLocalStub:
    var pipe = make_pipe()
    var pid = fork_pid()
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
    var ready_line = _read_ready_line(pipe.read_fd, deadline_ms)
    if not ready_line.startswith("ready"):
        var st = terminate_owned(pid, TERMINATION_GRACE_MS)
        close_fd(pipe.read_fd)
        raise Error(
            "max_local stub failed to report ready ("
            + ready_line
            + " / "
            + st.describe()
            + ")"
        )
    var reported_port = port
    var space = ready_line.find(" ")
    if space >= 0:
        reported_port = Int(String(ready_line[byte = space + 1 :]))
    return SpawnedMaxLocalStub(pid, reported_port, pipe.read_fd, deadline_ms)
