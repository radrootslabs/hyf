from std.collections import List

from mojson import Value, loads

from hyf_core.capabilities.registry import (
    all_deterministic_capabilities_implemented,
    bootstrap_capability_count,
    deterministic_enabled_capabilities,
    deferred_capabilities,
    implemented_deterministic_capability_count,
)
from hyf_core.request_context import request_context_feature_names


def _string_array(values: List[String]) raises -> Value:
    var array = loads("[]")
    for value in values:
        array.append(Value(String(value)))
    return array^


def build_status_output() raises -> Value:
    var output = loads("{}")
    output.set("daemon", Value("hyfd"))
    output.set("transport", Value("stdio"))
    output.set("request_framing", Value("newline_delimited_json"))
    output.set(
        "implementation_status",
        Value("bootstrap_registered_deterministic_ready")
        if all_deterministic_capabilities_implemented()
        else Value("bootstrap_partial_deterministic"),
    )

    var execution_modes = loads("{}")
    execution_modes.set("deterministic", Value(True))
    execution_modes.set("assisted", Value(False))
    output.set("enabled_execution_modes", execution_modes)

    var backends = loads("{}")
    backends.set(
        "deterministic_backend",
        Value("available")
        if all_deterministic_capabilities_implemented()
        else Value("partially_available"),
    )
    backends.set("assisted_backend", Value("unavailable"))
    output.set("backend_reachability", backends)

    var counts = loads("{}")
    counts.set("canonical_business_capabilities", Value(bootstrap_capability_count()))
    counts.set(
        "deterministic_registered_business_capabilities",
        Value(len(deterministic_enabled_capabilities())),
    )
    counts.set(
        "deterministic_implemented_business_capabilities",
        Value(implemented_deterministic_capability_count()),
    )
    counts.set(
        "disabled_business_capabilities",
        Value(len(deferred_capabilities())),
    )
    output.set("counts", counts)

    output.set(
        "deterministic_registered_capabilities",
        _string_array(deterministic_enabled_capabilities()),
    )
    output.set("disabled_capabilities", _string_array(deferred_capabilities()))

    var limits = loads("{}")
    limits.set("max_requests_per_process", Value(1))
    limits.set(
        "request_context_features",
        _string_array(request_context_feature_names()),
    )
    output.set("limits", limits)

    return output^
