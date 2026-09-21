from std.collections import List

from hyf_core.domain.demand import DemandLine
from hyf_core.domain.execution import ExecutionMeta
from hyf_core.domain.review import ReviewState


@fieldwise_init
struct BuyerNeedOutput(Copyable, Movable):
    var demand_lines: List[DemandLine]
    var review: ReviewState
    var execution: ExecutionMeta


def assemble_buyer_need(
    lines: List[DemandLine], review: ReviewState, execution: ExecutionMeta
) raises -> BuyerNeedOutput:
    if len(lines) == 0:
        raise Error("buyer need requires at least one demand line")
    var copied = List[DemandLine]()
    for line in lines:
        copied.append(line.copy())
    return BuyerNeedOutput(
        demand_lines=copied^, review=review.copy(), execution=execution.copy()
    )


def needs_reparse_rewritten_text() -> Bool:
    return False


def buyer_need_creates_order() -> Bool:
    return False
