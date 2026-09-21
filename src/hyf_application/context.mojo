@fieldwise_init
struct InterpretationSource(Copyable, Movable):
    var source_id: String
    var revision: String
    var text: String
    var source_time: String
    var timezone: String
    var actor_id: String
    var farm_id: String


def _is_blank(value: String) -> Bool:
    return String(value).strip().byte_length() == 0


def interpretation_source(
    source_id: String,
    revision: String,
    text: String,
    source_time: String,
    timezone: String,
    actor_id: String,
    farm_id: String,
) raises -> InterpretationSource:
    for pair in [
        ("source_id", source_id),
        ("revision", revision),
        ("text", text),
        ("source_time", source_time),
        ("timezone", timezone),
        ("actor_id", actor_id),
        ("farm_id", farm_id),
    ]:
        if _is_blank(pair[1]):
            raise Error("interpretation source requires " + pair[0])
    return InterpretationSource(
        source_id=String(source_id),
        revision=String(revision),
        text=String(text),
        source_time=String(source_time),
        timezone=String(timezone),
        actor_id=String(actor_id),
        farm_id=String(farm_id),
    )


def context_is_trusted_host_supplied() -> Bool:
    return True


def source_text_is_data_not_instruction() -> Bool:
    return True
