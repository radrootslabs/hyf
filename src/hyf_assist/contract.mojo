from std.collections import List

from hyf_core.capabilities.query_analysis import QueryAnalysis


def assist_bridge_contract_version() -> Int:
    return 1


def assist_bridge_runtime_id() -> String:
    return "hyf_assistd"


def assist_bridge_supported_business_capabilities() -> List[String]:
    var capabilities = List[String]()
    capabilities.append("query_rewrite")
    return capabilities^


def assist_bridge_fake_endpoint_prefix() -> String:
    return "hyf-assistd://fake"


@fieldwise_init
struct AssistBridgeStatus(Copyable, Movable):
    var id: String
    var kind: String
    var contract_version: Int
    var transport: String
    var endpoint: String
    var backend_kind: String
    var provider: String
    var route: String
    var model: String
    var configured: Bool
    var reachable: Bool
    var state: String
    var fallback_contract: String
    var supported_business_capabilities: List[String]


@fieldwise_init
struct AssistQueryRewriteResult(Copyable, Movable):
    var analysis: QueryAnalysis
    var provider: String
    var route: String
    var model: String
    var latency_ms: Int
    var schema_version: Int
