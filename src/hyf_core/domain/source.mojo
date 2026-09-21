from std.collections import List, Optional


@fieldwise_init
struct SourceId(Copyable, Movable):
    var value: String


@fieldwise_init
struct ActorId(Copyable, Movable):
    var value: String


@fieldwise_init
struct FarmId(Copyable, Movable):
    var value: String


@fieldwise_init
struct NeedId(Copyable, Movable):
    var value: String


@fieldwise_init
struct LotId(Copyable, Movable):
    var value: String


@fieldwise_init
struct Revision(Copyable, Movable):
    var value: String


def _require_identity(value: String, context: String) raises -> String:
    var trimmed = String(String(value).strip())
    if trimmed == "":
        raise Error(context + " must not be empty")
    if trimmed != value:
        raise Error(context + " must not include boundary whitespace")
    return trimmed^


def source_id(value: String) raises -> SourceId:
    return SourceId(value=_require_identity(value, "source id"))


def actor_id(value: String) raises -> ActorId:
    return ActorId(value=_require_identity(value, "actor id"))


def farm_id(value: String) raises -> FarmId:
    return FarmId(value=_require_identity(value, "farm id"))


def need_id(value: String) raises -> NeedId:
    return NeedId(value=_require_identity(value, "need id"))


def lot_id(value: String) raises -> LotId:
    return LotId(value=_require_identity(value, "lot id"))


def revision(value: String) raises -> Revision:
    return Revision(value=_require_identity(value, "revision"))


@fieldwise_init
struct TrustedSource(Copyable, Movable):
    var source_id: SourceId
    var revision: Revision
    var actor_id: ActorId
    var farm_id: FarmId


def trusted_source(
    source_id_value: String,
    revision_value: String,
    actor_id_value: String,
    farm_id_value: String,
) raises -> TrustedSource:
    return TrustedSource(
        source_id=source_id(source_id_value),
        revision=revision(revision_value),
        actor_id=actor_id(actor_id_value),
        farm_id=farm_id(farm_id_value),
    )
