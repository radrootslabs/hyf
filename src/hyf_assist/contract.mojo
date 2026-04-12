from std.collections import List


def assist_bridge_contract_version() -> Int:
    return 1


def assist_bridge_runtime_id() -> String:
    return "hyf_assistd"


def assist_bridge_supported_business_capabilities() -> List[String]:
    var capabilities = List[String]()
    capabilities.append("query_rewrite")
    return capabilities^


@fieldwise_init
struct AssistBridgeStatus(Copyable, Movable):
    var id: String
    var kind: String
    var contract_version: Int
    var transport: String
    var endpoint: String
    var backend_kind: String
    var configured: Bool
    var reachable: Bool
    var state: String
    var fallback_contract: String
    var supported_business_capabilities: List[String]
