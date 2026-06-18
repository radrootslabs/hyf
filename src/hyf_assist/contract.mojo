from std.collections import List


def assisted_runtime_contract_version() -> Int:
    return 1


def provider_runtime_id() -> String:
    return "hyf_provider_runtime"


def max_local_query_rewrite_route() -> String:
    return "provider_runtime.query_rewrite.max_local"


def assisted_runtime_supported_business_capabilities() -> List[String]:
    var capabilities = List[String]()
    capabilities.append("query_rewrite")
    return capabilities^


@fieldwise_init
struct AssistedRuntimeStatus(Copyable, Movable):
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
    var reason: String
    var fallback_contract: String
    var supported_business_capabilities: List[String]
