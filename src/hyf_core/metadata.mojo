from hyf_core.package_surface import hyf_package_name, hyf_package_version


def hyf_protocol_version() -> Int:
    return 1


@fieldwise_init
struct HyfPackageSurface(Copyable, Movable):
    var package_name: String
    var package_version: String


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

def current_package_surface() raises -> HyfPackageSurface:
    return HyfPackageSurface(
        package_name=hyf_package_name(),
        package_version=hyf_package_version(),
    )


def current_build_identity() raises -> HyfBuildIdentity:
    var package_surface = current_package_surface()
    return HyfBuildIdentity(
        service_name="hyf",
        package_name=package_surface.package_name,
        package_version=package_surface.package_version,
        daemon_name="hyfd",
        transport="stdio",
        protocol_version=hyf_protocol_version(),
        default_execution_mode="deterministic",
        deterministic_execution_available=True,
        assisted_execution_available=False,
    )
