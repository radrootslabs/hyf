from std.collections import List

from mojson import Value, loads

from hyf_core.capabilities.registry import (
    bootstrap_capability_count,
    bootstrap_enabled_capabilities,
    deferred_capabilities,
)


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
    output.set("implementation_status", Value("bootstrap_control_plane_only"))

    var modes = loads("{}")
    modes.set("a", Value(True))
    modes.set("b", Value(False))
    output.set("enabled_modes", modes)

    var backends = loads("{}")
    backends.set("mode_a_deterministic", Value("not_implemented"))
    backends.set("mode_b_model_assisted", Value("unavailable"))
    output.set("backend_reachability", backends)

    var counts = loads("{}")
    counts.set("canonical_business_capabilities", Value(bootstrap_capability_count()))
    counts.set(
        "mode_a_registered_business_capabilities",
        Value(len(bootstrap_enabled_capabilities())),
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
    limits.set("request_context_features", loads("[]"))
    output.set("limits", limits)

    return output^
