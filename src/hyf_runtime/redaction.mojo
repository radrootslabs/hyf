

comptime MAX_REDACTED_CHARS = 512


def redact_diagnostic(value: String) -> String:
    var replaced = String(value).replace("\n", "\\n")
    replaced = replaced.replace("\r", "\\r")
    if replaced.byte_length() > MAX_REDACTED_CHARS:
        return String(replaced[byte=0:MAX_REDACTED_CHARS]) + "..."
    return replaced^


def contains_credential_marker(value: String) -> Bool:
    var lowered = value.lower()
    return (
        lowered.find("apikey_") >= 0
        or lowered.find("bearer ") >= 0
        or lowered.find("authorization:") >= 0
    )
