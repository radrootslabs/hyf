"""Strict bounded HTTP request framing and scripted exchanges for local test
fixtures (ADR-0012 D29, ADR-0014 D33 FX01-FX05).

This module owns the *test fixture* wire contract only. It deliberately does
not change HYF's product HTTP/TLS policy or timeouts.

Framing contract (FX03):

* bounded byte-oriented accumulation before any UTF-8 decode
* header cap 65,536 bytes and body cap 1,048,576 bytes (ADR-0010 D21)
* lexical ``Content-Length``: nonempty ASCII digits only, with an explicit
  overflow guard; no sign, whitespace or non-digit
* request line must be ``METHOD SP target SP HTTP/1.1|HTTP/1.0``
* malformed header syntax (whitespace before ``:``, obs-fold, control bytes,
  non-token name bytes) is rejected rather than silently stripped
* duplicate/conflicting framing and unsupported transfer encodings rejected
* premature EOF and oversize rejected before unbounded accumulation
* surplus bytes after a frame are retained for the next frame

Exchange contract (FX01/FX02/FX04/FX05): explicit ordered scripts carrying the
expected method/path/selected headers/body plus the scripted status/headers/
body/delay and connection semantics. Request and connection counters are
distinct and verified.
"""

from std.collections import List

from flare.net import Timeout
from flare.tcp import TcpListener
from flare.tcp import TcpStream
from flare.utils import usleep


comptime STRICT_MAX_HEADER_BYTES = 65536
comptime STRICT_MAX_BODY_BYTES = 1048576
comptime STRICT_MAX_READY_BYTES = 256
comptime STRICT_MAX_REPORT_BYTES = 2048
comptime STRICT_COMPLETION_GRACE_MS = 100


# ── JSON-safe escaping (FX04) ───────────────────────────────────────────────


def _hex_digit(value: Int) -> UInt8:
    if value < 10:
        return UInt8(48 + value)
    return UInt8(97 + (value - 10))


def json_escape(value: String) -> String:
    """Return ``value`` as a JSON string literal with full control escaping."""
    var out = List[UInt8]()
    out.append(UInt8(34))
    for byte in value.as_bytes():
        var b = Int(byte)
        if b == 34:
            out.append(UInt8(92))
            out.append(UInt8(34))
        elif b == 92:
            out.append(UInt8(92))
            out.append(UInt8(92))
        elif b == 8:
            out.append(UInt8(92))
            out.append(UInt8(98))
        elif b == 12:
            out.append(UInt8(92))
            out.append(UInt8(102))
        elif b == 10:
            out.append(UInt8(92))
            out.append(UInt8(110))
        elif b == 13:
            out.append(UInt8(92))
            out.append(UInt8(114))
        elif b == 9:
            out.append(UInt8(92))
            out.append(UInt8(116))
        elif b < 32 or b == 127:
            out.append(UInt8(92))
            out.append(UInt8(117))
            out.append(UInt8(48))
            out.append(UInt8(48))
            out.append(_hex_digit(b // 16))
            out.append(_hex_digit(b % 16))
        else:
            out.append(UInt8(b))
    out.append(UInt8(34))
    return String(unsafe_from_utf8=Span(ptr=out.unsafe_ptr(), length=len(out)))


# ── Header access (FX03/FX04) ───────────────────────────────────────────────


def header_values(headers_raw: String, name: String) -> List[String]:
    """Return every value for an exactly named header (case-insensitive name).

    The header name is compared byte-exactly after lowercasing; malformed
    spacing was already rejected by the framer, so no whitespace stripping of
    the name token occurs here.
    """
    var out = List[String]()
    var lines = headers_raw.split("\r\n")
    var wanted = name.lower()
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if colon <= 0:
            continue
        if String(line[byte=0:colon]).lower() == wanted:
            out.append(String(line[byte = colon + 1 :].strip()))
    return out^


def header_value(headers_raw: String, name: String) -> String:
    var values = header_values(headers_raw, name)
    if len(values) != 1:
        return ""
    return values[0]


def bearer_token(headers_raw: String) -> String:
    var values = header_values(headers_raw, "authorization")
    if len(values) != 1:
        return ""
    if not values[0].startswith("Bearer "):
        return ""
    return String(values[0][byte=7:])


def authorization_reason(headers_raw: String, required: Bool) -> String:
    """Validate the exact ``Authorization`` header, rejecting spoofs (FX04)."""
    if not required:
        return ""
    var values = header_values(headers_raw, "authorization")
    if len(values) == 0:
        return "auth_missing"
    if len(values) > 1:
        return "auth_duplicate"
    if not values[0].startswith("Bearer ") or values[0].byte_length() <= 7:
        return "auth_invalid"
    return ""


# ── Framing ─────────────────────────────────────────────────────────────────


@fieldwise_init
struct FramedRequest(Movable):
    var ok: Bool
    var error: String
    var method: String
    var path: String
    var version: String
    var headers_raw: String
    var body: String
    var content_length: Int
    var keep_alive: Bool
    var total_bytes: Int


def _token_byte(value: Int) -> Bool:
    if value >= 48 and value <= 57:
        return True
    if value >= 65 and value <= 90:
        return True
    if value >= 97 and value <= 122:
        return True
    # RFC 7230 token punctuation.
    return (
        value == 33
        or value == 35
        or value == 36
        or value == 37
        or value == 38
        or value == 39
        or value == 42
        or value == 43
        or value == 45
        or value == 46
        or value == 94
        or value == 95
        or value == 96
        or value == 124
        or value == 126
    )


def _valid_method(method: String) -> Bool:
    if method.byte_length() == 0:
        return False
    for byte in method.as_bytes():
        var b = Int(byte)
        if b < 65 or b > 90:
            return False
    return True


def _valid_version(version: String) -> Bool:
    return version == "HTTP/1.1" or version == "HTTP/1.0"


def _valid_header_name(name: String) -> Bool:
    if name.byte_length() == 0:
        return False
    for byte in name.as_bytes():
        if not _token_byte(Int(byte)):
            return False
    return True


def _valid_header_value(value: String) -> Bool:
    for byte in value.as_bytes():
        var b = Int(byte)
        if b == 9:
            continue
        if b < 32 or b == 127:
            return False
    return True


def _trim_ows(value: String) -> String:
    """Trim only legal HTTP optional whitespace (SP / HTAB)."""
    var start = 0
    var end = value.byte_length()
    var bytes = value.as_bytes()
    while start < end and (Int(bytes[start]) == 32 or Int(bytes[start]) == 9):
        start += 1
    while end > start and (
        Int(bytes[end - 1]) == 32 or Int(bytes[end - 1]) == 9
    ):
        end -= 1
    if start == 0 and end == value.byte_length():
        return String(value)
    return String(value[byte=start:end])


def _ascii_digits(value: String) -> Bool:
    if value.byte_length() == 0:
        return False
    for byte in value.as_bytes():
        var b = Int(byte)
        if b < 48 or b > 57:
            return False
    return True


def _bytes_string(bytes: List[UInt8], stop: Int) raises -> String:
    return String(from_utf8=Span(ptr=bytes.unsafe_ptr(), length=stop))


struct ConnectionReader(Movable):
    var _stream: TcpStream
    var _buffer: List[UInt8]
    var _eof: Bool

    def __init__(out self, var stream: TcpStream):
        self._stream = stream^
        self._buffer = List[UInt8]()
        self._eof = False

    def has_buffered(self) -> Bool:
        return len(self._buffer) > 0

    def _read_more(mut self) raises -> Int:
        var chunk = InlineArray[Byte, 4096](fill=0)
        var n = self._stream.read(chunk.unsafe_ptr(), 4096)
        if n <= 0:
            self._eof = True
            return 0
        for index in range(Int(n)):
            self._buffer.append(UInt8(Int(chunk[index])))
        return Int(n)

    def write_all(mut self, text: String) raises:
        self._stream.write_all(Span[UInt8, _](text.as_bytes()))

    def _header_end(self) -> Int:
        var i = 0
        while i + 3 < len(self._buffer):
            if (
                self._buffer[i] == 13
                and self._buffer[i + 1] == 10
                and self._buffer[i + 2] == 13
                and self._buffer[i + 3] == 10
            ):
                return i
            i += 1
        return -1

    def read(mut self) raises -> FramedRequest:
        var outcome = FramedRequest(
            ok=False,
            error="",
            method="",
            path="",
            version="",
            headers_raw="",
            body="",
            content_length=0,
            keep_alive=False,
            total_bytes=0,
        )
        var header_end = self._header_end()
        while header_end < 0:
            if self._eof:
                outcome.error = (
                    "empty" if len(self._buffer)
                    == 0 else "missing_header_terminator"
                )
                return outcome^
            if len(self._buffer) > STRICT_MAX_HEADER_BYTES:
                outcome.error = "header_too_large"
                return outcome^
            _ = self._read_more()
            # Recompute the terminator before any total-length check: a single
            # coalesced chunk may carry a small header plus a large body, and
            # only the header bytes count against the header cap.
            header_end = self._header_end()
            if header_end < 0 and len(self._buffer) > STRICT_MAX_HEADER_BYTES:
                outcome.error = "header_too_large"
                return outcome^
        if header_end > STRICT_MAX_HEADER_BYTES:
            outcome.error = "header_too_large"
            return outcome^

        var header_text = _bytes_string(self._buffer, header_end)
        var lines = header_text.split("\r\n")
        if len(lines) < 1:
            outcome.error = "malformed_request_line"
            return outcome^
        var request_line = String(lines[0])
        var parts = request_line.split(" ")
        if len(parts) != 3:
            outcome.error = "malformed_request_line"
            return outcome^
        outcome.method = String(parts[0])
        outcome.path = String(parts[1])
        outcome.version = String(parts[2])
        if not _valid_method(outcome.method):
            outcome.error = "malformed_method"
            return outcome^
        if not _valid_version(outcome.version):
            outcome.error = "malformed_version"
            return outcome^
        if outcome.path.byte_length() == 0:
            outcome.error = "malformed_target"
            return outcome^

        var content_length = 0
        var have_length = False
        var have_transfer = False
        for i in range(1, len(lines)):
            var line = String(lines[i])
            if line.byte_length() == 0:
                continue
            var first = Int(line.as_bytes()[0])
            if first == 32 or first == 9:
                outcome.error = "malformed_header"
                return outcome^
            var colon = line.find(":")
            if colon <= 0:
                outcome.error = "malformed_header"
                return outcome^
            var name = String(line[byte=0:colon])
            var raw_value = String(line[byte = colon + 1 :])
            if not _valid_header_name(name):
                outcome.error = "malformed_header"
                return outcome^
            var value = _trim_ows(raw_value)
            if not _valid_header_value(value):
                outcome.error = "malformed_header"
                return outcome^
            var lower = name.lower()
            if lower == "content-length":
                if have_length:
                    outcome.error = "duplicate_content_length"
                    return outcome^
                if not _ascii_digits(value):
                    outcome.error = "malformed_content_length"
                    return outcome^
                if value.byte_length() > 10:
                    outcome.error = "content_length_overflow"
                    return outcome^
                var parsed = Int(value)
                if parsed > STRICT_MAX_BODY_BYTES:
                    outcome.error = "body_too_large"
                    return outcome^
                content_length = parsed
                have_length = True
            elif lower == "transfer-encoding":
                if have_transfer:
                    outcome.error = "duplicate_transfer_encoding"
                    return outcome^
                have_transfer = True
                if value.lower() != "identity":
                    outcome.error = "unsupported_transfer_encoding"
                    return outcome^
            elif lower == "connection" and value.lower() == "keep-alive":
                outcome.keep_alive = True

        if have_transfer and have_length:
            outcome.error = "conflicting_framing"
            return outcome^
        if not have_length:
            content_length = 0
        outcome.content_length = content_length

        var expected_total = header_end + 4 + content_length
        while len(self._buffer) < expected_total:
            if self._eof:
                outcome.error = "premature_eof"
                return outcome^
            _ = self._read_more()

        outcome.headers_raw = header_text
        outcome.body = String(
            _bytes_string(self._buffer, expected_total)[byte = header_end + 4 :]
        )
        var surplus = List[UInt8]()
        for index in range(expected_total, len(self._buffer)):
            surplus.append(self._buffer[index])
        self._buffer = surplus^
        outcome.ok = True
        outcome.total_bytes = expected_total
        return outcome^

    def probe_completion(mut self, grace_ms: Int) raises -> String:
        """Bounded completion handshake after the final expected exchange.

        Any already-buffered or subsequently received bytes mean the client
        sent an extra exchange. A bounded timeout with no bytes is success; a
        real read error is propagated as the exact read cause (never read as
        success or as a timeout) and is recorded by the serve loop as a
        bounded io_error. The Mojo error model cannot discriminate these
        struct payloads by handler type, so the timeout is identified from the
        rendered cause.
        """
        if len(self._buffer) > 0:
            return "extra_exchange_after_completion"
        self._stream.set_recv_timeout(grace_ms)
        var outcome = ""
        try:
            var n = self._read_more()
            if n > 0:
                outcome = "extra_exchange_after_completion"
        except e:
            var text = String(e)
            if text.startswith("Timeout"):
                return ""
            raise Error("probe_completion_read_error:" + text)
        return outcome^


# ── Scripted exchanges (FX01/FX02/FX04/FX05) ────────────────────────────────


@fieldwise_init
struct ExchangeScript(Copyable, Movable):
    var case_label: String
    var method: String
    var path: String
    var headers: String
    var body: String
    var check_body: Bool
    var require_bearer: Bool
    var status: Int
    var response_headers: String
    var response_body: String
    var raw_response: String
    var delay_ms: Int
    var stall_after_head_ms: Int
    var close_connection: Bool
    var echo_authorization: Bool
    var expect_peer_close: Bool
    var expected_close_cause: String
    var expected_close_phase: String
    var inject_write_error: String

    def __copyinit__(out self, existing: Self):
        self.case_label = existing.case_label
        self.method = existing.method
        self.path = existing.path
        self.headers = existing.headers
        self.body = existing.body
        self.check_body = existing.check_body
        self.require_bearer = existing.require_bearer
        self.status = existing.status
        self.response_headers = existing.response_headers
        self.response_body = existing.response_body
        self.raw_response = existing.raw_response
        self.delay_ms = existing.delay_ms
        self.stall_after_head_ms = existing.stall_after_head_ms
        self.close_connection = existing.close_connection
        self.echo_authorization = existing.echo_authorization
        self.expect_peer_close = existing.expect_peer_close
        self.expected_close_cause = existing.expected_close_cause
        self.expected_close_phase = existing.expected_close_phase
        self.inject_write_error = existing.inject_write_error


def exchange_script(
    case_label: String,
    method: String,
    path: String,
    status: Int,
    body: String,
) -> ExchangeScript:
    return ExchangeScript(
        case_label=case_label,
        method=method,
        path=path,
        headers="",
        body="",
        check_body=False,
        require_bearer=False,
        status=status,
        response_headers="",
        response_body=body,
        raw_response="",
        delay_ms=0,
        stall_after_head_ms=0,
        close_connection=True,
        echo_authorization=False,
        expect_peer_close=False,
        expected_close_cause="",
        expected_close_phase="",
        inject_write_error="",
    )


def verify_exchange(script: ExchangeScript, framed: FramedRequest) -> String:
    """Return ``""`` when the request matches the script, else a bounded reason.
    """
    if framed.method != script.method:
        return "method_mismatch"
    if framed.path != script.path:
        return "path_mismatch"
    if script.check_body and framed.body != script.body:
        return "body_mismatch"
    var expected_headers = script.headers.split("\n")
    for entry in expected_headers:
        var expected = String(entry).strip()
        if expected.byte_length() == 0:
            continue
        var split = expected.find(":")
        if split <= 0:
            return "malformed_script_header"
        var name = String(expected[byte=0:split])
        if name.byte_length() == 0 or not _valid_header_name(name):
            return "malformed_script_header"
        var value = _trim_ows(String(expected[byte = split + 1 :]))
        var values = header_values(framed.headers_raw, name)
        if len(values) == 0:
            return "header_missing:" + name
        if len(values) > 1:
            return "header_duplicate:" + name
        if values[0] != value:
            return "header_mismatch:" + name
    var auth = authorization_reason(framed.headers_raw, script.require_bearer)
    if auth != "":
        return auth
    return ""


def _substitute(
    text: String, request_index: Int, connection_index: Int
) -> String:
    var out = text.replace("{request_index}", String(request_index))
    return out.replace("{connection_index}", String(connection_index))


def render_response(
    script: ExchangeScript,
    request_headers_raw: String,
    request_index: Int,
    connection_index: Int,
) -> String:
    if script.raw_response != "":
        return String(script.raw_response)
    var reason = "OK"
    if script.status == 401:
        reason = "Unauthorized"
    elif script.status == 404:
        reason = "Not Found"
    elif script.status == 429:
        reason = "Too Many Requests"
    elif script.status == 500:
        reason = "Internal Server Error"
    elif script.status == 503:
        reason = "Service Unavailable"
    elif script.status == 529:
        reason = "Overloaded"
    var body = _substitute(
        script.response_body, request_index, connection_index
    )
    if script.echo_authorization:
        body = (
            '{"authorization":'
            + json_escape(bearer_token(request_headers_raw))
            + "}"
        )
    var extra = ""
    if script.response_headers != "":
        extra = script.response_headers + "\r\n"
    var connection = "keep-alive" if not script.close_connection else "close"
    return (
        "HTTP/1.1 "
        + String(script.status)
        + " "
        + reason
        + "\r\ncontent-type: application/json\r\n"
        + extra
        + "content-length: "
        + String(body.byte_length())
        + "\r\nconnection: "
        + connection
        + "\r\n\r\n"
        + body
    )


# ── Convenience-mode validation + reports ────────────────────────────────────


def classify_write_error_cause(text: String) -> String:
    """Bounded cause class for a response-write error observed by the fixture.

    Mojo's error model cannot discriminate handler types, so the exact rendered
    cause is classified. A script that declares an expected peer close must
    match one of these bounded classes *and* the exact phase; every other write
    error (an injected handler failure, a write timeout, an invalid descriptor)
    is surfaced as a bounded fixture failure rather than tolerated.
    """
    if text.find("ConnectionReset") >= 0:
        return "peer_reset"
    if text.find("BrokenPipe") >= 0:
        return "broken_pipe"
    if text.find("Timeout") >= 0:
        return "write_timeout"
    return "unrelated_error"


def serve_scripts(
    listener: TcpListener, var scripts: List[ExchangeScript], label: String
) raises -> ServeReport:
    """Serve an ordered list of explicit exchange scripts (FX01/FX02/FX05).

    Every script must be consumed in order on its expected method/path/
    selected-headers/body; unexpected, extra, missing and unconsumed exchanges
    fail with a bounded case-specific reason. A 404-then-success outcome is
    never a pass.
    """
    var request_count = 0
    var connection_count = 0
    var total = len(scripts)
    try:
        while request_count < total:
            var stream = listener.accept()
            connection_count += 1
            var reader = ConnectionReader(stream^)
            while request_count < total:
                var framed = reader.read()
                if not framed.ok:
                    if framed.error == "empty":
                        if request_count < total:
                            return ServeReport(
                                False,
                                "accounting",
                                label,
                                "missing_exchanges",
                                request_count,
                                connection_count,
                            )
                        break
                    return ServeReport(
                        False,
                        "read",
                        label,
                        framed.error,
                        request_count,
                        connection_count,
                    )
                var script = scripts[request_count].copy()
                var verify = verify_exchange(script, framed)
                if verify != "":
                    return ServeReport(
                        False,
                        "exchange",
                        script.case_label,
                        verify,
                        request_count,
                        connection_count,
                    )
                var next_index = request_count + 1
                if next_index == total:
                    var extra = reader.probe_completion(
                        STRICT_COMPLETION_GRACE_MS
                    )
                    if extra != "":
                        return ServeReport(
                            False,
                            "accounting",
                            script.case_label,
                            extra,
                            request_count,
                            connection_count,
                        )
                request_count = next_index
                if script.delay_ms > 0:
                    usleep(script.delay_ms * 1000)
                var phase = (
                    "body_stall" if script.stall_after_head_ms
                    > 0 else "delayed_write"
                )
                try:
                    if script.stall_after_head_ms > 0:
                        # Headers-then-stall control (H007): write the complete
                        # response head, flush it, hold the connection open for
                        # the declared bounded stall, then attempt the body. This
                        # separates a body-read stall from a connection timeout
                        # and from the overall budget using a bounded fixture
                        # delay that never hangs the owning test.
                        var rendered = render_response(
                            script,
                            framed.headers_raw,
                            request_count,
                            connection_count,
                        )
                        var separator = rendered.find("\r\n\r\n")
                        if separator >= 0:
                            var head_end = separator + 4
                            reader.write_all(String(rendered[byte=0:head_end]))
                            usleep(script.stall_after_head_ms * 1000)
                            if script.inject_write_error != "":
                                raise Error(script.inject_write_error)
                            reader.write_all(String(rendered[byte=head_end:]))
                        else:
                            reader.write_all(rendered)
                    else:
                        if script.inject_write_error != "":
                            raise Error(script.inject_write_error)
                        reader.write_all(
                            render_response(
                                script,
                                framed.headers_raw,
                                request_count,
                                connection_count,
                            )
                        )
                except e:
                    # A delay/stall is not permission to swallow every write
                    # error. Only an explicitly declared expected peer close
                    # whose exact bounded cause and phase match is accepted;
                    # unexpected/wrong-phase closes, write timeouts, invalid
                    # descriptors and unrelated handler errors fail the fixture
                    # with a bounded, cause-specific reason.
                    var observed = classify_write_error_cause(String(e))
                    if (
                        script.expect_peer_close
                        and observed == script.expected_close_cause
                        and phase == script.expected_close_phase
                    ):
                        return ServeReport(
                            True,
                            "complete",
                            script.case_label
                            + "_peer_close_"
                            + observed
                            + "_"
                            + phase,
                            "ok",
                            request_count,
                            connection_count,
                        )
                    return ServeReport(
                        False,
                        "peer_close",
                        script.case_label,
                        "unexpected_write_" + observed + "_" + phase,
                        request_count,
                        connection_count,
                    )
                if script.close_connection:
                    break
        if request_count < total:
            return ServeReport(
                False,
                "accounting",
                scripts[request_count].case_label,
                "missing_exchanges",
                request_count,
                connection_count,
            )
        return ServeReport(
            True, "complete", label, "ok", request_count, connection_count
        )
    except:
        return ServeReport(
            False, "read", label, "io_error", request_count, connection_count
        )


def validate_convenience(
    framed: FramedRequest,
    allowed_paths: List[String],
    allowed_methods: List[String],
    require_bearer: Bool,
) -> String:
    """Validate route then method (and auth) before any response.

    ``allowed_methods`` is parallel to ``allowed_paths``. Wrong routes,
    methods and spoofed auth never count as a successful intended exchange
    (FX02/FX04).
    """
    var matched = -1
    for index in range(len(allowed_paths)):
        if framed.path == allowed_paths[index]:
            matched = index
    if matched < 0:
        return "unexpected_path"
    if matched >= len(allowed_methods):
        return "unexpected_method"
    if framed.method != allowed_methods[matched]:
        return "unexpected_method"
    return authorization_reason(framed.headers_raw, require_bearer)


@fieldwise_init
struct ServeReport(Movable):
    var ok: Bool
    var phase: String
    var case_label: String
    var reason: String
    var requests: Int
    var connections: Int

    def describe(self) -> String:
        return (
            "phase="
            + self.phase
            + " case="
            + self.case_label
            + " reason="
            + self.reason
            + " requests="
            + String(self.requests)
            + " connections="
            + String(self.connections)
        )


def report_status_matches_exit(
    exited: Bool, exit_code: Int, report_ok: Bool
) -> Bool:
    """The fixture child exits 0 for a successful report and 125 for a failed
    one; any other exit (including a signal) contradicts the report."""
    if not exited:
        return False
    if report_ok:
        return exit_code == 0
    return exit_code == 125


def report_line(report: ServeReport) -> String:
    var state = "ok" if report.ok else "fail"
    return "result " + state + " " + report.describe()


def _strict_nonneg(value: String) -> Int:
    """Parse a nonnegative decimal count; -1 for empty/non-digit/overflow."""
    if value.byte_length() == 0 or value.byte_length() > 12:
        return -1
    var total = 0
    for byte in value.as_bytes():
        var b = Int(byte)
        if b < 48 or b > 57:
            return -1
        total = total * 10 + (b - 48)
    return total


def _report_failure(reason: String) -> ServeReport:
    return ServeReport(False, "parse", "-", reason, -1, -1)


def parse_report(line: String) -> ServeReport:
    """Strictly parse one bounded ``result`` report line.

    Missing/truncated/duplicate/malformed/unknown/missing-count fields fail
    with a bounded cause instead of defaulting counts to zero, and only the
    exact ``ok``/``fail`` status is accepted.
    """
    if not line.startswith("result "):
        return _report_failure("missing_result_prefix")
    var parts = String(line[byte=7:]).split(" ")
    if len(parts) == 0:
        return _report_failure("missing_status")
    var status = String(parts[0])
    if status != "ok" and status != "fail":
        return _report_failure("unknown_status")
    var phase = ""
    var case_label = ""
    var reason = ""
    var requests = -1
    var connections = -1
    var have_phase = False
    var have_case = False
    var have_reason = False
    var have_requests = False
    var have_connections = False
    for index in range(1, len(parts)):
        var field = String(parts[index])
        if field.byte_length() == 0:
            return _report_failure("empty_field")
        var eq = field.find("=")
        if eq <= 0:
            return _report_failure("malformed_field")
        var key = String(field[byte=0:eq])
        var value = String(field[byte = eq + 1 :])
        if value.byte_length() == 0:
            return _report_failure("empty_field")
        if key == "phase":
            if have_phase:
                return _report_failure("duplicate_field")
            have_phase = True
            phase = value
        elif key == "case":
            if have_case:
                return _report_failure("duplicate_field")
            have_case = True
            case_label = value
        elif key == "reason":
            if have_reason:
                return _report_failure("duplicate_field")
            have_reason = True
            reason = value
        elif key == "requests":
            if have_requests:
                return _report_failure("duplicate_field")
            have_requests = True
            requests = _strict_nonneg(value)
            if requests < 0:
                return _report_failure("invalid_count")
        elif key == "connections":
            if have_connections:
                return _report_failure("duplicate_field")
            have_connections = True
            connections = _strict_nonneg(value)
            if connections < 0:
                return _report_failure("invalid_count")
        else:
            return _report_failure("unknown_field")
    if not (
        have_phase
        and have_case
        and have_reason
        and have_requests
        and have_connections
    ):
        return _report_failure("missing_field")
    if status == "ok" and (phase != "complete" or reason != "ok"):
        # A claimed success must carry the emitted success phase/reason; any
        # other pairing is an inconsistent report, never a success.
        return _report_failure("inconsistent_status")
    return ServeReport(
        status == "ok", phase, case_label, reason, requests, connections
    )
