

def external_network_required() -> Bool:
    return False


def loopback_only_provider_endpoints() -> Bool:
    return True


def credential_required_for_offline_tests() -> Bool:
    return False


def offline_environment_is_sanitized() -> Bool:
    return True
