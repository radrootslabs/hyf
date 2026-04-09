from std.os.path import exists

from hyf_runtime.paths import RuntimePaths, join_runtime_path


# Runtime status posture only: do not load, create, wrap, or persist secrets here.
comptime _DEFAULT_SECRET_BACKEND = "encrypted_file"
comptime _SECRET_STORAGE_STATUS = "reserved"
comptime _PROTECTED_LOCAL_DATA_STATUS = "reserved"


def default_secret_backend_name() -> String:
    return _DEFAULT_SECRET_BACKEND


def secret_storage_status_name() -> String:
    return _SECRET_STORAGE_STATUS


def secret_storage_backend_implemented() -> Bool:
    return False


def identity_material_loaded() -> Bool:
    return False


def identity_material_created_by_startup() -> Bool:
    return False


def identity_material_configured_for_runtime_paths(paths: RuntimePaths) -> Bool:
    return exists(paths.identity_path)


def protected_local_data_status_name() -> String:
    return _PROTECTED_LOCAL_DATA_STATUS


def protected_local_data_support_implemented() -> Bool:
    return False


def protected_local_data_store_open() -> Bool:
    return False


def protected_local_data_configured_for_runtime_paths(
    paths: RuntimePaths,
) raises -> Bool:
    return exists(protected_local_data_dir_for_runtime_paths(paths))


def protected_local_data_dir_for_runtime_paths(
    paths: RuntimePaths,
) raises -> String:
    return join_runtime_path(paths.data_dir, "protected")
