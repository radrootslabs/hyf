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
    var pid: Int
    var _report_fd: Int
    var _reaped: Bool
    var _ok: Bool
    var _phase: String
    var _case: String
    var _reason: String
    var _requests: Int
    var _connections: Int

    def __init__(out self, pid: Int, report_fd: Int):
        self.pid = pid
        self._report_fd = report_fd
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
        if self._reaped:
            return
        var st = wait_bounded(self.pid, FIXTURE_DEFAULT_DEADLINE_MS)
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
                False, "startup", "-", "exit_" + String(st.exit_code), 0, 0
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


@fieldwise_init
struct SpawnedJevStubAuto(Movable):
    var port: Int
    var stub: SpawnedJevStub


def reserve_jev_port() raises -> Int:
    var listener = TcpListener.bind(SocketAddr.localhost(0))
    var port = Int(listener.local_addr().port)
    listener.close()
    return port


def spawn_jev_stub_auto(
    mode: String, requests: Int
) raises -> SpawnedJevStubAuto:
    return _spawn_jev_stub(0, mode, requests)


def spawn_jev_stub(
    port: Int, mode: String, requests: Int
) raises -> SpawnedJevStub:
    var started = _spawn_jev_stub(port, mode, requests)
    return started.stub^


def serve_jev_scripted(
    port: Int, var scripts: List[ExchangeScript]
) raises -> ServeReport:
    var listener = TcpListener.bind(SocketAddr.localhost(UInt16(port)))
    var actual_port = Int(listener.local_addr().port)
    write_raw(1, "ready " + String(actual_port) + "\n")
    return serve_scripts(listener, scripts^, "scripted")


def _read_ready_line(fd: Int) -> String:
    try:
        return read_line_bounded(fd, 256, FIXTURE_DEFAULT_DEADLINE_MS)
    except:
        return ""


def spawn_jev_scripted_auto(
    var scripts: List[ExchangeScript],
) raises -> SpawnedJevStubAuto:
    return _spawn_jev_scripted(0, scripts^)


def _spawn_jev_scripted(
    port: Int, var scripts: List[ExchangeScript]
) raises -> SpawnedJevStubAuto:
    var total = len(scripts)
    var pipe = make_pipe()
    var pid = fork_pid()
    if pid == 0:
        if dup2_fd(pipe.write_fd, 1) < 0:
            child_exit(126)
        close_fd(pipe.read_fd)
        close_fd(pipe.write_fd)
        _ = set_alarm(STUB_ALARM_SECONDS)
        try:
            var report = serve_jev_scripted(port, scripts^)
            write_raw(1, report_line(report) + "\n")
            child_exit(0 if report.ok else 125)
        except:
            var failed = ServeReport(
                False, "startup", "scripted", "serve_failed", 0, 0
            )
            write_raw(1, report_line(failed) + "\n")
            child_exit(125)
    close_fd(pipe.write_fd)
    var ready_line = _read_ready_line(pipe.read_fd)
    if not ready_line.startswith("ready"):
        var st = terminate_owned(pid, TERMINATION_GRACE_MS)
        close_fd(pipe.read_fd)
        raise Error(
            "jev stub failed to report ready ("
            + ready_line
            + " / "
            + st.describe()
            + ")"
        )
    var reported_port = port
    var space = ready_line.find(" ")
    if space >= 0:
        reported_port = Int(String(ready_line[byte = space + 1 :]))
    _ = total
    return SpawnedJevStubAuto(
        port=reported_port, stub=SpawnedJevStub(pid, pipe.read_fd)
    )


def _spawn_jev_stub(
    port: Int, mode: String, requests: Int
) raises -> SpawnedJevStubAuto:
    var pipe = make_pipe()
    var pid = fork_pid()
    if pid == 0:
        if dup2_fd(pipe.write_fd, 1) < 0:
            child_exit(126)
        close_fd(pipe.read_fd)
        close_fd(pipe.write_fd)
        _ = set_alarm(STUB_ALARM_SECONDS)
        try:
            var report = serve_jev(port, mode, requests)
            write_raw(1, report_line(report) + "\n")
            child_exit(0 if report.ok else 125)
        except:
            var failed = ServeReport(
                False, "startup", mode, "serve_failed", 0, 0
            )
            write_raw(1, report_line(failed) + "\n")
            child_exit(125)
    close_fd(pipe.write_fd)
    var ready_line = _read_ready_line(pipe.read_fd)
    if not ready_line.startswith("ready"):
        var st = terminate_owned(pid, TERMINATION_GRACE_MS)
        close_fd(pipe.read_fd)
        raise Error(
            "jev stub failed to report ready ("
            + ready_line
            + " / "
            + st.describe()
            + ")"
        )
    var reported_port = port
    var space = ready_line.find(" ")
    if space >= 0:
        reported_port = Int(String(ready_line[byte = space + 1 :]))
    return SpawnedJevStubAuto(
        port=reported_port, stub=SpawnedJevStub(pid, pipe.read_fd)
    )
