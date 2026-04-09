from hyf_runtime.paths import RuntimePaths, join_runtime_path


# Runtime status posture only: do not load, create, wrap, or persist secrets here.
comptime _DEFAULT_SECRET_BACKEND = "encrypted_file"
comptime _SECRET_STORAGE_STATUS = "reserved_pending_shared_secret_storage"
comptime _PROTECTED_LOCAL_DATA_STATUS = "reserved_pending_protected_store"


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


def protected_local_data_status_name() -> String:
    return _PROTECTED_LOCAL_DATA_STATUS


def protected_local_data_store_open() -> Bool:
    return False


def protected_local_data_dir_for_runtime_paths(
    paths: RuntimePaths,
) raises -> String:
    return join_runtime_path(paths.data_dir, "protected")
