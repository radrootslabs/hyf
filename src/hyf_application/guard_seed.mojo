# Deliberately faulty guard implementations used to prove that critical tests
# actually catch representative regressions.
from std.collections import List


def correct_eligibility(has_fail: Bool, has_unknown: Bool) -> String:
    if has_fail:
        return "ineligible"
    if has_unknown:
        return "conditional"
    return "eligible"


def seeded_unknown_to_pass(has_fail: Bool, has_unknown: Bool) -> String:
    if has_fail:
        return "ineligible"
    return "eligible"


def correct_compare(left: Int, right: Int) -> Int:
    if left < right:
        return -1
    if left > right:
        return 1
    return 0


def seeded_comparison_inversion(left: Int, right: Int) -> Int:
    return correct_compare(right, left)


def correct_revision_check(expected: String, current: String) -> Bool:
    return expected == current


def seeded_revision_check_bypass(expected: String, current: String) -> Bool:
    return True
