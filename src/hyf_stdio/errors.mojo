from mojson import Value, loads


@fieldwise_init
struct WireError(Copyable, Movable):
    var code: String
    var message: String

    def to_json_value(self) raises -> Value:
        var value = loads("{}")
        value.set("code", Value(String(self.code)))
        value.set("message", Value(String(self.message)))
        return value^


def invalid_request_error(message: String) -> WireError:
    return WireError(code="invalid_request", message=message)


def unsupported_capability_error(capability: String) -> WireError:
    return WireError(
        code="unsupported_capability",
        message="no handler registered for capability '" + capability + "'",
    )


def capability_disabled_error(capability: String) -> WireError:
    return WireError(
        code="capability_disabled",
        message="bootstrap deferred capability '" + capability + "' is disabled",
    )


def capability_unavailable_error(capability: String) -> WireError:
    return WireError(
        code="capability_unavailable",
        message="bootstrap capability '" + capability + "' is not implemented yet",
    )


def internal_error(message: String) -> WireError:
    return WireError(code="internal_error", message=message)
