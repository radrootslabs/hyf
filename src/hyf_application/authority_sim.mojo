from std.collections import List


@fieldwise_init
struct AuthoritySimulation(Copyable, Movable):
    var accepted_changes: Int
    var requires_confirmation: Bool
    var applied_revisions: List[String]
    var duplicate_rejections: Int
    var stale_rejections: Int
    var hyf_business_writes: Int


def new_authority_simulation() -> AuthoritySimulation:
    return AuthoritySimulation(
        accepted_changes=0,
        requires_confirmation=True,
        applied_revisions=List[String](),
        duplicate_rejections=0,
        stale_rejections=0,
        hyf_business_writes=0,
    )


def apply_expected_version(
    mut simulation: AuthoritySimulation,
    source_revision: String,
    expected_revision: String,
    current_revision: String,
) raises:
    if expected_revision != current_revision:
        simulation.stale_rejections += 1
        raise Error("stale_acceptance")
    for applied in simulation.applied_revisions:
        if applied == source_revision:
            simulation.duplicate_rejections += 1
            raise Error("duplicate_acceptance")
    simulation.applied_revisions.append(String(source_revision))
    simulation.accepted_changes += 1
