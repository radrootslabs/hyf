from std.collections import List

from mojson import Value, loads

from hyf_core.capabilities.registry import canonical_business_capabilities


def _string_array(values: List[String]) raises -> Value:
    var array = loads("[]")
    for value in values:
        array.append(Value(String(value)))
    return array^


def build_capabilities_output() raises -> Value:
    var output = loads("{}")
    var control_routes = List[String]()
    control_routes.append("sys.status")
    control_routes.append("sys.capabilities")
    output.set(
        "control_routes", _string_array(control_routes)
    )

    var capabilities = loads("[]")
    for capability in canonical_business_capabilities():
        var value = loads("{}")
        value.set("id", Value(String(capability.id)))
        value.set("kind", Value("business"))
        value.set(
            "mode_a",
            Value("enabled") if capability.mode_a_enabled else Value("disabled"),
        )
        value.set(
            "implementation_status",
            Value("not_implemented")
            if capability.mode_a_enabled
            else Value("disabled"),
        )
        value.set("callable", Value(capability.callable))
        value.set("implemented", Value(capability.implemented))
        value.set("mode_b", Value("unavailable"))
        value.set("backend_assisted", Value(capability.mode_b_available))
        if capability.disabled_reason != "":
            value.set(
                "disabled_reason", Value(String(capability.disabled_reason))
            )
        capabilities.append(value)

    output.set("business_capabilities", capabilities)
    output.set("backend_assisted_capabilities", loads("[]"))
    output.set("request_context_features", loads("[]"))
    return output^
