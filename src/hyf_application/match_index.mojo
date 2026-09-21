from std.collections import List


def index_supplied_lots(
    lot_ids: List[String], revisions: List[String]
) raises -> List[String]:
    if len(lot_ids) != len(revisions):
        raise Error("lot ids and revisions must align")
    if len(lot_ids) == 0:
        raise Error("matching requires at least one supplied lot")
    var keys = List[String]()
    var seen_ids = List[String]()
    var seen_revisions = List[String]()
    for index in range(len(lot_ids)):
        var lot = String(lot_ids[index])
        var rev = String(revisions[index])
        if String(lot).strip().byte_length() == 0 or String(rev).strip().byte_length() == 0:
            raise Error("supplied lot requires id and revision")
        var key = lot + "@" + rev
        for existing in keys:
            if existing == key:
                raise Error("duplicate supplied lot revision: " + key)
        var id_seen = False
        for known in seen_ids:
            if known == lot:
                id_seen = True
        if id_seen:
            raise Error("conflicting revisions for lot: " + lot)
        seen_ids.append(String(lot))
        seen_revisions.append(String(rev))
        keys.append(String(key))
    return keys^


def duplicate_records_double_stock() -> Bool:
    return False
