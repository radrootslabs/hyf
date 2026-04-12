from std.collections import List

from mojson import Value, loads

from hyf_assist.bridge import (
    assisted_backend_available_for_capability,
    assisted_execution_state_for_capability,
    resolve_assist_bridge_status,
    serialize_assist_bridge_status_value,
)
from hyf_core.capabilities.registry import canonical_business_capabilities
from hyf_runtime.startup import (
    RuntimeStartupContext,
    resolve_startup_context_from_process,
)
from hyf_stdio.control.request_context_contract import (
    build_request_context_contract_value,
)


def _string_array(values: List[String]) raises -> Value:
    var array = loads("[]")
    for value in values:
        array.append(Value(String(value)))
    return array^


def build_capabilities_output() raises -> Value:
    return build_capabilities_output_with_runtime_context(
        resolve_startup_context_from_process()
    )


def build_capabilities_output_with_runtime_context(
    runtime_context: RuntimeStartupContext,
) raises -> Value:
    var output = loads("{}")
    var assist_bridge = resolve_assist_bridge_status(runtime_context.config)
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
            "deterministic_execution",
            Value("enabled")
            if capability.deterministic_enabled
            else Value("disabled"),
        )
        value.set(
            "implementation_status",
            Value("implemented")
            if capability.implemented
            else (
                Value("not_implemented")
                if capability.deterministic_enabled
                else Value("disabled")
            ),
        )
        value.set("callable", Value(capability.callable))
        value.set("implemented", Value(capability.implemented))
        value.set(
            "assisted_execution",
            Value(
                assisted_execution_state_for_capability(
                    assist_bridge, capability.id
                )
            ),
        )
        value.set(
            "assisted_backend_available",
            Value(
                assisted_backend_available_for_capability(
                    assist_bridge, capability.id
                )
            ),
        )
        if capability.disabled_reason != "":
            value.set(
                "disabled_reason", Value(String(capability.disabled_reason))
            )
        capabilities.append(value)

    output.set("business_capabilities", capabilities)
    var assisted_runtime_capabilities = loads("[]")
    assisted_runtime_capabilities.append(
        serialize_assist_bridge_status_value(assist_bridge)
    )
    output.set(
        "assisted_runtime_capabilities", assisted_runtime_capabilities.copy()
    )
    output.set(
        "assisted_backend_capabilities", assisted_runtime_capabilities
    )
    output.set(
        "request_context_contract",
        build_request_context_contract_value(),
    )
    return output^
