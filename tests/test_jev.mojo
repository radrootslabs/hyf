from std.collections import List
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from hyf_assist.questions import (
    Question,
    QuestionBundle,
    choice_question,
    noul_question,
    question_bundle,
    score_question,
)
from hyf_provider.jev_request import build_jev_request_body


def _bundle() raises -> QuestionBundle:
    var choices = List[String]()
    choices.append("offered")
    choices.append("forecast")
    choices.append("unclear")
    var questions = List[Question]()
    questions.append(choice_question("supply_status", "status?", choices))
    questions.append(noul_question("seconds_ok", "seconds?"))
    var rubric = List[String]()
    rubric.append("unsuitable")
    rubric.append("limited")
    rubric.append("suitable")
    questions.append(score_question("culinary_fit", "fit?", rubric))
    return question_bundle("qb1", "1", "jev-1.13.0", questions)


def test_jev_request_serialization_shape() raises:
    var body = build_jev_request_body(_bundle(), "Roma tomatoes available now")
    assert_equal(body["model"].string_value(), "jev-1.13.0")
    assert_equal(body["state"].string_value(), "Roma tomatoes available now")
    assert_equal(body["questions"]["supply_status"]["type"].string_value(), "choice")
    assert_true(body["questions"]["supply_status"]["criteria"]["offered"].is_null())
    assert_equal(body["questions"]["seconds_ok"]["type"].string_value(), "noul")
    assert_equal(body["questions"]["culinary_fit"]["type"].string_value(), "score")
    assert_equal(len(body["questions"]["culinary_fit"]["criteria"].array_items()), 3)
    with assert_raises():
        _ = build_jev_request_body(_bundle(), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
