from std.collections import List

from mojson import Value, loads

from hyf_core.capabilities.registry import (
    all_deterministic_capabilities_implemented,
    bootstrap_capability_count,
    deterministic_enabled_capabilities,
    deferred_capabilities,
    implemented_deterministic_capability_count,
)
from hyf_core.metadata import current_build_identity
from hyf_core.request_context import request_context_feature_names


def _string_array(values: List[String]) raises -> Value:
    var array = loads("[]")
    for value in values:
        array.append(Value(String(value)))
    return array^


def _build_identity_value() raises -> Value:
    var build_identity = current_build_identity()
    var value = loads("{}")
    value.set("service_name", Value(String(build_identity.service_name)))
    value.set("package_name", Value(String(build_identity.package_name)))
    value.set("package_version", Value(String(build_identity.package_version)))
    value.set("daemon_name", Value(String(build_identity.daemon_name)))
    value.set("transport", Value(String(build_identity.transport)))
    value.set("protocol_version", Value(build_identity.protocol_version))
    value.set(
        "default_execution_mode",
        Value(String(build_identity.default_execution_mode)),
    )
    value.set(
        "deterministic_execution_available",
        Value(build_identity.deterministic_execution_available),
    )
    value.set(
        "assisted_execution_available",
        Value(build_identity.assisted_execution_available),
    )
    return value^


def build_status_output() raises -> Value:
    var output = loads("{}")
    var build_identity = _build_identity_value()
    output.set("build_identity", build_identity.copy())
    output.set("daemon", build_identity["daemon_name"].clone())
    output.set("transport", build_identity["transport"].clone())
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

    var execution_mode_request_behavior = loads("{}")
    execution_mode_request_behavior.set("deterministic", Value("execute"))
    execution_mode_request_behavior.set(
        "assisted", Value("backend_unavailable")
    )
    output.set(
        "execution_mode_request_behavior",
        execution_mode_request_behavior,
    )

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
