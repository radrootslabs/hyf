from std.collections import List


comptime MAX_STATE_BYTES = 4096


def _is_blank(value: String) -> Bool:
    return String(value).strip().byte_length() == 0


def _truncate(value: String, limit: Int) -> String:
    if value.byte_length() <= limit:
        return String(value)
    return String(value[byte=0:limit])


def minimal_state(
    source_text: String, focus_product: String, buyer_request: String
) raises -> String:
    if source_text.byte_length() > MAX_STATE_BYTES:
        raise Error("provider state exceeds maximum size")
    var parts = List[String]()
    if not _is_blank(source_text):
        parts.append(String("farm_update: ") + _truncate(source_text, 2048))
    if not _is_blank(focus_product):
        parts.append(String("focus_product: ") + _truncate(focus_product, 256))
    if not _is_blank(buyer_request):
        parts.append(String("buyer_request: ") + _truncate(buyer_request, 512))

    var joined = String()
    var first = True
    for part in parts:
        if not first:
            joined += "\n"
        joined += part
        first = False
    if joined.byte_length() > MAX_STATE_BYTES:
        raise Error("provider state exceeds maximum size")
    return joined^


def state_includes_full_repository() -> Bool:
    return False
