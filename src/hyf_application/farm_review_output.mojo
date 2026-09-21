from std.collections import List

from hyf_application.farm_status import ProductStatus
from hyf_core.domain.execution import ExecutionMeta
from hyf_core.domain.review import ReviewState
from hyf_core.domain.supply_change import ProposedSupplyChange


@fieldwise_init
struct FarmInterpretationOutput(Copyable, Movable):
    var claims: List[ProductStatus]
    var changes: List[ProposedSupplyChange]
    var review: ReviewState
    var execution: ExecutionMeta
    var original_source_preserved: Bool
    var hyf_business_writes: Int


def assemble_farm_output(
    claims: List[ProductStatus],
    changes: List[ProposedSupplyChange],
    review: ReviewState,
    execution: ExecutionMeta,
) raises -> FarmInterpretationOutput:
    var copied_claims = List[ProductStatus]()
    for claim in claims:
        copied_claims.append(claim.copy())
    var copied_changes = List[ProposedSupplyChange]()
    for change in changes:
        copied_changes.append(change.copy())
    return FarmInterpretationOutput(
        claims=copied_claims^,
        changes=copied_changes^,
        review=review.copy(),
        execution=execution.copy(),
        original_source_preserved=True,
        hyf_business_writes=0,
    )


def missing_optional_price_blocks_draft() -> Bool:
    return False


def ambiguous_withdrawal_blocks_apply() -> Bool:
    return True
