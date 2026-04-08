def hyf_protocol_version() -> Int:
    return 1


@fieldwise_init
struct HyfBuildIdentity(Copyable, Movable):
    var service_name: String
    var package_name: String
    var package_version: String
    var daemon_name: String
    var transport: String
    var protocol_version: Int
    var default_execution_mode: String
    var deterministic_execution_available: Bool
    var assisted_execution_available: Bool


def current_build_identity() -> HyfBuildIdentity:
    return HyfBuildIdentity(
        service_name="hyf",
        package_name="hyf",
        package_version="0.1.0",
        daemon_name="hyfd",
        transport="stdio",
        protocol_version=hyf_protocol_version(),
        default_execution_mode="deterministic",
        deterministic_execution_available=True,
        assisted_execution_available=False,
    )
