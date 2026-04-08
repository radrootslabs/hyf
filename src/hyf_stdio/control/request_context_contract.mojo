from std.collections import List

from mojson import Value, loads

from hyf_core.request_context import (
    accepted_request_context_feature_names,
    effective_request_context_feature_names,
)


def _string_array(values: List[String]) raises -> Value:
    var array = loads("[]")
    for value in values:
        array.append(Value(String(value)))
    return array^


def build_request_context_contract_value() raises -> Value:
    var contract = loads("{}")
    contract.set(
        "accepted_features",
        _string_array(accepted_request_context_feature_names()),
    )
    contract.set(
        "effective_features",
        _string_array(effective_request_context_feature_names()),
    )
    contract.set("unsupported_field_behavior", Value("reject"))
    return contract^
