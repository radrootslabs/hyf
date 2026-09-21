from std.collections import List


def validate_match_scope(trusted_tenant: String, snapshot_tenant: String) raises:
    if String(trusted_tenant).strip().byte_length() == 0:
        raise Error("match requires a trusted tenant")
    if snapshot_tenant != trusted_tenant:
        raise Error("snapshot is outside the authorized tenant scope")


def validate_supplied_lots(lot_keys: List[String]) raises -> List[String]:
    var unique = List[String]()
    for key in lot_keys:
        if String(key).strip().byte_length() == 0:
            raise Error("supplied lot key must not be empty")
        for existing in unique:
            if existing == key:
                raise Error("duplicate supplied lot revision: " + key)
        unique.append(String(key))
    if len(unique) == 0:
        raise Error("matching requires at least one supplied lot")
    return unique^


def caller_name_is_authentication() -> Bool:
    return False
