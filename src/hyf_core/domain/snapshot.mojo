from hyf_core.domain.product import ProductRef
from hyf_core.domain.units import unit_dimension


@fieldwise_init
struct SupplySnapshot(Copyable, Movable):
    var lot_id: String
    var revision: String
    var supplier_id: String
    var product: ProductRef
    var unreserved_state: String
    var unreserved_value: Int
    var unreserved_scale: Int
    var unit: String
    var dimension: String


def supply_snapshot(
    lot_id: String,
    revision: String,
    supplier_id: String,
    product: ProductRef,
    unreserved_state: String,
    unreserved_value: Int,
    unreserved_scale: Int,
    unit: String,
) raises -> SupplySnapshot:
    if (
        lot_id.strip() == ""
        or revision.strip() == ""
        or supplier_id.strip() == ""
    ):
        raise Error("snapshot requires lot id, revision and supplier id")
    if unreserved_state != "known" and unreserved_state != "unknown":
        raise Error("unreserved state must be 'known' or 'unknown'")
    if unreserved_scale < 0 or unreserved_scale > 9:
        raise Error("unreserved scale must be between 0 and 9")
    return SupplySnapshot(
        lot_id=String(lot_id),
        revision=String(revision),
        supplier_id=String(supplier_id),
        product=product.copy(),
        unreserved_state=String(unreserved_state),
        unreserved_value=unreserved_value,
        unreserved_scale=unreserved_scale,
        unit=String(unit),
        dimension=String(unit_dimension(unit)),
    )


def snapshot_unreserved_known(snapshot: SupplySnapshot) -> Bool:
    return snapshot.unreserved_state == "known"


def snapshot_identity(snapshot: SupplySnapshot) -> String:
    return snapshot.lot_id + "@" + snapshot.revision
