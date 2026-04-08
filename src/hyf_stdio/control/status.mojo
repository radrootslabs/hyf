from std.collections import List

from mojson import Value, loads

from hyf_core.capabilities.registry import (
    all_enabled_capabilities_implemented,
    bootstrap_capability_count,
    bootstrap_enabled_capabilities,
    deferred_capabilities,
    implemented_enabled_capability_count,
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
        Value("bootstrap_registered_mode_a_ready")
        if all_enabled_capabilities_implemented()
        else Value("bootstrap_partial_mode_a"),
    )

    var modes = loads("{}")
    modes.set("a", Value(True))
    modes.set("b", Value(False))
    output.set("enabled_modes", modes)

    var backends = loads("{}")
    backends.set(
        "mode_a_deterministic",
        Value("available")
        if all_enabled_capabilities_implemented()
        else Value("partially_available"),
    )
    backends.set("mode_b_model_assisted", Value("unavailable"))
    output.set("backend_reachability", backends)

    var counts = loads("{}")
    counts.set("canonical_business_capabilities", Value(bootstrap_capability_count()))
    counts.set(
        "mode_a_registered_business_capabilities",
        Value(len(bootstrap_enabled_capabilities())),
    )
    counts.set(
        "mode_a_implemented_business_capabilities",
        Value(implemented_enabled_capability_count()),
    )
    counts.set(
        "disabled_business_capabilities",
        Value(len(deferred_capabilities())),
    )
    output.set("counts", counts)

    output.set(
        "mode_a_registered_capabilities", _string_array(bootstrap_enabled_capabilities())
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
