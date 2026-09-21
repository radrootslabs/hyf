from std.collections import List


def supported_operations() -> List[String]:
    var operations = List[String]()
    operations.append("farm_update.interpret")
    operations.append("buyer_request.interpret")
    operations.append("buyer_request.match")
    return operations^


def application_layer_uses_transport_types() -> Bool:
    return False


def application_layer_owns_business_state() -> Bool:
    return False


def operation_is_supported(operation: String) -> Bool:
    for candidate in supported_operations():
        if candidate == operation:
            return True
    return False
