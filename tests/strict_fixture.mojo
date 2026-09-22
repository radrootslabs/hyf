"""Strict bounded HTTP request framing for local test fixtures (ADR-0012 D29).

Bounded byte-oriented accumulation and header parsing *before* UTF-8 decoding,
validated nonnegative ``Content-Length``, exact header-name matching,
duplicate/conflicting length rejection, premature-EOF rejection, bounded
unsupported-transfer rejection and surplus retention for persistent
connections.
"""

from std.collections import List

from flare.tcp import TcpStream

comptime STRICT_MAX_HEADER_BYTES = 65536
comptime STRICT_MAX_BODY_BYTES = 1048576


struct FramedRequest(Movable):
    var ok: Bool
    var error: String
    var method: String
    var path: String
    var headers_raw: String
    var body: String
    var keep_alive: Bool
    var total_bytes: Int

    def __init__(out self):
        self.ok = False
        self.error = ""
        self.method = ""
        self.path = ""
        self.headers_raw = ""
        self.body = ""
        self.keep_alive = False
        self.total_bytes = 0


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
        var outcome = FramedRequest()
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
            header_end = self._header_end()
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

        var content_length = -1
        var have_length = False
        var have_transfer = False
        for i in range(1, len(lines)):
            var line = String(lines[i])
            if line.byte_length() == 0:
                continue
            var colon = line.find(":")
            if colon < 0:
                outcome.error = "malformed_header"
                return outcome^
            var name = String(line[byte=0:colon]).lower().strip()
            var value = String(line[byte = colon + 1 :]).strip()
            if name == "content-length":
                if have_length:
                    outcome.error = "duplicate_content_length"
                    return outcome^
                var parsed = Int(value)
                if parsed < 0:
                    outcome.error = "negative_content_length"
                    return outcome^
                content_length = parsed
                have_length = True
            elif name == "transfer-encoding":
                have_transfer = True
                if value.lower() != "identity":
                    outcome.error = "unsupported_transfer_encoding"
                    return outcome^
            elif name == "connection" and value.lower() == "keep-alive":
                outcome.keep_alive = True

        if have_transfer and have_length:
            outcome.error = "conflicting_framing"
            return outcome^
        if not have_length:
            content_length = 0
        if content_length > STRICT_MAX_BODY_BYTES:
            outcome.error = "body_too_large"
            return outcome^

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


def header_value(headers_raw: String, name: String) -> String:
    """Return the value of an exactly named header, or "" when absent."""
    var lines = headers_raw.split("\r\n")
    var wanted = name.lower()
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if colon < 0:
            continue
        if String(line[byte=0:colon]).lower().strip() == wanted:
            return String(String(line[byte = colon + 1 :]).strip())
    return ""


def bearer_token(headers_raw: String) -> String:
    var value = header_value(headers_raw, "authorization")
    if not value.startswith("Bearer "):
        return ""
    return String(value[byte=7:])
