from std.pathlib import Path, _dir_of_current_file


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


def _package_surface_manifest_path() raises -> Path:
    return _dir_of_current_file() / ".." / ".." / "pixi.toml"


def _parse_quoted_assignment_value(value: String) raises -> String:
    var trimmed_value = value.strip()
    if (
        trimmed_value.byte_length() < 2
        or not trimmed_value.startswith("\"")
        or not trimmed_value.endswith("\"")
    ):
        raise Error("manifest assignment value must be a quoted string")

    return String(
        trimmed_value[byte=1 : trimmed_value.byte_length() - 1]
    )


def current_package_surface() raises -> HyfPackageSurface:
    var in_workspace = False
    var package_name = String("")
    var package_version = String("")

    for raw_line in _package_surface_manifest_path().read_text().splitlines():
        var line = String(raw_line).strip()
        if line == "" or line.startswith("#"):
            continue

        if line.startswith("["):
            in_workspace = line == "[workspace]"
            continue

        if not in_workspace:
            continue

        var equals_index = line.find("=")
        if equals_index < 0:
            continue

        var key = String(line[byte=0:equals_index]).strip()
        var value = _parse_quoted_assignment_value(
            String(line[byte=equals_index + 1 :])
        )

        if key == "name":
            package_name = value^
        elif key == "version":
            package_version = value^

        if package_name != "" and package_version != "":
            return HyfPackageSurface(
                package_name=package_name^,
                package_version=package_version^,
            )

    raise Error("unable to derive hyf package surface from pixi.toml")


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
