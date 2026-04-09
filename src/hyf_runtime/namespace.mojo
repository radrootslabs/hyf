from hyf_runtime.errors import raise_runtime_contract_error


comptime _HYF_RUNTIME_NAMESPACE = "services/hyf"


def hyf_runtime_namespace() -> String:
    return _HYF_RUNTIME_NAMESPACE


def validate_runtime_namespace(namespace: String) raises:
    if namespace != _HYF_RUNTIME_NAMESPACE:
        raise_runtime_contract_error(
            "namespace must be '" + _HYF_RUNTIME_NAMESPACE + "'"
        )


def _trim_trailing_slashes(path: String) -> String:
    var trimmed = String(String(path).strip())
    while trimmed.byte_length() > 1 and trimmed.endswith("/"):
        trimmed = String(trimmed[byte = 0 : trimmed.byte_length() - 1])
    return trimmed^


def join_runtime_path(left: String, right: String) raises -> String:
    var normalized_left = _trim_trailing_slashes(left)
    var normalized_right = String(String(right).strip())

    if normalized_left == "":
        raise_runtime_contract_error("path root must not be empty")
    if normalized_right == "":
        raise_runtime_contract_error("path leaf must not be empty")

    if normalized_left == "/":
        return "/" + normalized_right
    return normalized_left + "/" + normalized_right
