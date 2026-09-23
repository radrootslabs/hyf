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
    assert_equal(
        body["questions"]["supply_status"]["type"].string_value(), "choice"
    )
    assert_true(
        body["questions"]["supply_status"]["criteria"]["offered"].is_null()
    )
    assert_equal(body["questions"]["seconds_ok"]["type"].string_value(), "noul")
    assert_equal(
        body["questions"]["culinary_fit"]["type"].string_value(), "score"
    )
    assert_equal(
        len(body["questions"]["culinary_fit"]["criteria"].array_items()), 3
    )
    with assert_raises():
        _ = build_jev_request_body(_bundle(), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_provider.jev_answers import parse_choice_answer, parse_noul_answer
from json import loads


def test_parse_choice_and_noul_answers() raises:
    var noul = parse_noul_answer(
        "seconds_ok", loads('{"type":"noul","noul":0.9}')
    )
    assert_equal(noul.kind, "noul")
    assert_equal(noul.noul, 0.9)
    var choices = List[String]()
    choices.append("offered")
    choices.append("forecast")
    choices.append("unclear")
    var choice = parse_choice_answer(
        "supply_status",
        loads(
            '{"type":"choice","choice":"offered","probabilities":{"offered":1.0,"forecast":0.0,"unclear":0.0},"confidence":1.0}'
        ),
        choices,
    )
    assert_equal(choice.choice, "offered")

    with assert_raises():
        _ = parse_noul_answer("q", loads('{"type":"noul","noul":1.5}'))
    with assert_raises():
        _ = parse_choice_answer(
            "q",
            loads('{"type":"choice","choice":"bogus","confidence":1.0}'),
            choices,
        )
    with assert_raises():
        _ = parse_choice_answer(
            "q",
            loads(
                '{"type":"choice","choice":"offered","probabilities":{"offered":0.5,"forecast":0.5,"unclear":0.5},"confidence":1.0}'
            ),
            choices,
        )
    with assert_raises():
        _ = parse_choice_answer(
            "q", loads('{"type":"noul","noul":0.5}'), choices
        )


from hyf_provider.jev_answers import parse_score_answer


def test_parse_score_answer_validates_rubric_and_levels() raises:
    var rubric = List[String]()
    rubric.append("unsuitable")
    rubric.append("limited")
    rubric.append("suitable")
    var answer = parse_score_answer(
        "culinary_fit",
        loads(
            '{"type":"score","score":2,"legend":{"0":"unsuitable","1":"limited","2":"suitable"},"probabilities":{"0":0.0,"1":0.0,"2":1.0},"confidence":1.0}'
        ),
        rubric,
    )
    assert_equal(answer.score, 2)
    with assert_raises():
        _ = parse_score_answer(
            "q",
            loads(
                '{"type":"score","score":5,"legend":{"0":"a","1":"b","2":"c"},"confidence":1.0}'
            ),
            rubric,
        )
    with assert_raises():
        _ = parse_score_answer(
            "q",
            loads(
                '{"type":"score","score":1,"legend":{"0":"a"},"confidence":1.0}'
            ),
            rubric,
        )


from hyf_provider.jev_answers import parse_jev_response


def test_parse_jev_response_validates_answer_set() raises:
    var body = loads(
        '{"model":"jev-1.13.0","answers":{'
        '"supply_status":{"type":"choice","choice":"offered","probabilities":{"offered":1.0,"forecast":0.0,"unclear":0.0},"confidence":1.0},'
        '"seconds_ok":{"type":"noul","noul":0.9},'
        '"culinary_fit":{"type":"score","score":2,"legend":{"0":"u","1":"l","2":"s"},"probabilities":{"0":0.0,"1":0.0,"2":1.0},"confidence":1.0}},'
        '"usage":{"input_tokens":10,"output_tokens":5}}'
    )
    var answers = parse_jev_response(body, _bundle())
    assert_equal(len(answers), 3)

    var extra = loads(
        '{"model":"jev-1.13.0","answers":{'
        '"supply_status":{"type":"choice","choice":"offered","probabilities":{"offered":1.0,"forecast":0.0,"unclear":0.0},"confidence":1.0},'
        '"seconds_ok":{"type":"noul","noul":0.9},'
        '"culinary_fit":{"type":"score","score":2,"legend":{"0":"u","1":"l","2":"s"},"probabilities":{"0":0.0,"1":0.0,"2":1.0},"confidence":1.0},'
        '"extra":{"type":"noul","noul":0.5}},'
        '"usage":{"input_tokens":10,"output_tokens":5}}'
    )
    with assert_raises():
        _ = parse_jev_response(extra, _bundle())

    var mismatch = loads(
        '{"model":"jev-other","answers":{"supply_status":{"type":"choice","choice":"offered","confidence":1.0},"seconds_ok":{"type":"noul","noul":0.9},"culinary_fit":{"type":"score","score":2,"confidence":1.0}}}'
    )
    with assert_raises():
        _ = parse_jev_response(mismatch, _bundle())

    var missing = loads(
        '{"model":"jev-1.13.0","answers":{"supply_status":{"type":"choice","choice":"offered","confidence":1.0}}}'
    )
    with assert_raises():
        _ = parse_jev_response(missing, _bundle())


from hyf_provider.jev_failures import map_jev_failure


def test_jev_failure_mapping_permanent_vs_transient() raises:
    assert_equal(map_jev_failure("authentication").family, "provider_auth")
    assert_true(not map_jev_failure("authentication").retryable)
    assert_equal(map_jev_failure("validation").family, "provider_validation")
    assert_true(not map_jev_failure("validation").retryable)
    assert_equal(map_jev_failure("rate_limit").family, "provider_capacity")
    assert_true(map_jev_failure("rate_limit").retryable)
    assert_true(map_jev_failure("overloaded").retryable)
    assert_true(map_jev_failure("internal_server").retryable)
    assert_equal(
        map_jev_failure("response_validation").family,
        "provider_response_contract",
    )
    assert_true(not map_jev_failure("response_validation").retryable)
    with assert_raises():
        _ = map_jev_failure("mystery")


from hyf_provider.jev_projection import (
    answer_by_id,
    project_choice,
    provider_cannot_supply_trusted_identity,
)


def test_provider_response_projection() raises:
    var body = loads(
        '{"model":"jev-1.13.0","answers":{'
        '"supply_status":{"type":"choice","choice":"offered","probabilities":{"offered":1.0,"forecast":0.0,"unclear":0.0},"confidence":1.0},'
        '"seconds_ok":{"type":"noul","noul":0.9},'
        '"culinary_fit":{"type":"score","score":2,"legend":{"0":"u","1":"l","2":"s"},"probabilities":{"0":0.0,"1":0.0,"2":1.0},"confidence":1.0}}}'
    )
    var answers = parse_jev_response(body, _bundle())
    assert_equal(project_choice(answers, "supply_status"), "offered")
    assert_equal(answer_by_id(answers, "seconds_ok").noul, 0.9)
    assert_true(provider_cannot_supply_trusted_identity())
    with assert_raises():
        _ = answer_by_id(answers, "nonexistent")


from hyf_provider.jev_state import minimal_state, state_includes_full_repository


def test_data_minimized_state_projection() raises:
    var state = minimal_state(
        "Roma tomatoes available now",
        "Roma tomatoes",
        "Tomatoes for sauce; seconds permitted",
    )
    assert_true(state.find("farm_update:") >= 0)
    assert_true(state.find("focus_product:") >= 0)
    assert_true(state.find("buyer_request:") >= 0)
    var only_source = minimal_state("Basil sold out", "", "")
    assert_equal(only_source, "farm_update: Basil sold out")
    assert_true(not state_includes_full_repository())
    var huge = String()
    for _ in range(2000):
        huge += "xxxxxxxxxx"
    with assert_raises():
        _ = minimal_state(huge, "", "")


from hyf_provider.jev_retry import retry_delay_ms, retry_policy, should_retry


def test_retry_classification_and_bounded_scheduling() raises:
    var policy = retry_policy(3, 100, 500, 1000)
    assert_equal(retry_delay_ms(policy, 0), 100)
    assert_equal(retry_delay_ms(policy, 1), 200)
    assert_equal(retry_delay_ms(policy, 2), 400)
    assert_equal(retry_delay_ms(policy, 5), 500)
    assert_true(should_retry(policy, 0, 0, True))
    assert_true(not should_retry(policy, 0, 0, False))
    assert_true(not should_retry(policy, 3, 0, True))
    assert_true(not should_retry(policy, 0, 950, True))
    with assert_raises():
        _ = retry_policy(1, 0, 10, 100)


from hyf_provider.jev_circuit import (
    circuit_allows,
    circuit_record_failure,
    circuit_record_success,
    circuit_state,
    process_liveness_is_provider_readiness,
)


def test_circuit_opens_and_recovers() raises:
    var state = circuit_state(2)
    assert_true(circuit_allows(state))
    state = circuit_record_failure(state)
    assert_true(circuit_allows(state))
    state = circuit_record_failure(state)
    assert_true(not circuit_allows(state))
    state = circuit_record_success(state)
    assert_true(circuit_allows(state))
    assert_true(not process_liveness_is_provider_readiness())


from flare.http import HttpClient
from parent_lifecycle import CleanupGuard
from jev_provider_helper import (
    reserve_jev_port,
    spawn_jev_stub_auto,
)


def test_local_provider_server_serves_scripted_jev() raises:
    var guard_1 = CleanupGuard()
    with spawn_jev_stub_auto("ok", 1, guard_1) as started:
        var port = started.port
        var url = "http://127.0.0.1:" + String(port) + "/v1/systemone"
        with HttpClient(timeout_ms=5000, max_redirects=0) as client:
            var response = client.post(
                url, '{"model":"jev-1.13.0","state":"s","questions":{}}'
            )
            assert_true(response.ok())
            var body = response.json()
            assert_equal(body["model"].string_value(), "jev-1.13.0")
        started.stub.wait()

    guard_1.assert_clean()


def test_local_provider_server_scripts_transport_failures() raises:
    var guard_2 = CleanupGuard()
    with spawn_jev_stub_auto("rate_limit", 1, guard_2) as rate_port_started:
        var rate_port = rate_port_started.port
        with HttpClient(timeout_ms=5000, max_redirects=0) as client:
            var response = client.post(
                "http://127.0.0.1:" + String(rate_port) + "/v1/systemone", "{}"
            )
            assert_equal(response.status, 429)
        rate_port_started.stub.wait()

        var guard_3 = CleanupGuard()
        with spawn_jev_stub_auto(
            "malformed_json", 1, guard_3
        ) as malformed_port_started:
            var malformed_port = malformed_port_started.port
            with HttpClient(timeout_ms=5000, max_redirects=0) as client:
                var response = client.post(
                    "http://127.0.0.1:"
                    + String(malformed_port)
                    + "/v1/systemone",
                    "{}",
                )
                assert_equal(response.text(), "not json")
            malformed_port_started.stub.wait()

            var guard_4 = CleanupGuard()
            with spawn_jev_stub_auto(
                "server_error", 1, guard_4
            ) as err_port_started:
                var err_port = err_port_started.port
                with HttpClient(timeout_ms=5000, max_redirects=0) as client:
                    var response = client.post(
                        "http://127.0.0.1:"
                        + String(err_port)
                        + "/v1/systemone",
                        "{}",
                    )
                    assert_equal(response.status, 500)
                err_port_started.stub.wait()

            guard_4.assert_clean()
        guard_3.assert_clean()
    guard_2.assert_clean()


from hyf_provider.jev_client import post_jev_systemone, validate_jev_base_url
from json import loads as _loads


def test_jev_endpoint_policy_and_loopback_client() raises:
    assert_equal(
        validate_jev_base_url("https://api.typesafe.ai/"),
        "https://api.typesafe.ai",
    )
    assert_equal(
        validate_jev_base_url("http://127.0.0.1:8000"),
        "http://127.0.0.1:8000",
    )
    with assert_raises():
        _ = validate_jev_base_url("http://api.typesafe.ai")
    with assert_raises():
        _ = validate_jev_base_url("http://127.0.0.1.evil.example")
    with assert_raises():
        _ = validate_jev_base_url("https://user:pass@api.typesafe.ai")
    with assert_raises():
        _ = validate_jev_base_url("ftp://api.typesafe.ai")

    var guard_5 = CleanupGuard()
    with spawn_jev_stub_auto("ok", 1, guard_5) as started:
        var port = started.port
        var outcome = post_jev_systemone(
            "http://127.0.0.1:" + String(port),
            _loads('{"model":"jev-1.13.0","state":"s","questions":{}}'),
            5000,
        )
        assert_equal(outcome.status, 200)
        assert_true(outcome.body_text.find("jev-1.13.0") >= 0)
        started.stub.wait()

    guard_5.assert_clean()


from flare.tls import TlsVerify
from flare.tls import TlsConfig
from hyf_provider.jev_client import (
    assert_tls_verification_required,
    production_tls_config,
    redirects_forward_credentials,
)


def test_tls_and_redirect_policy() raises:
    var config = production_tls_config()
    assert_equal(config.verify, TlsVerify.REQUIRED)
    assert_tls_verification_required(config)
    with assert_raises():
        assert_tls_verification_required(TlsConfig.insecure())
    assert_true(not redirects_forward_credentials())

    var guard_6 = CleanupGuard()
    with spawn_jev_stub_auto("redirect", 1, guard_6) as started:
        var port = started.port
        with assert_raises():
            with HttpClient(timeout_ms=5000, max_redirects=0) as client:
                _ = client.post(
                    "http://127.0.0.1:" + String(port) + "/v1/systemone", "{}"
                )
        started.stub.wait()

    guard_6.assert_clean()


from hyf_provider.jev_client import failure_kind_for_status, retry_decision


def test_bounded_retry_and_budget_behavior() raises:
    assert_equal(failure_kind_for_status(401), "authentication")
    assert_equal(failure_kind_for_status(429), "rate_limit")
    assert_equal(failure_kind_for_status(500), "internal_server")
    assert_equal(failure_kind_for_status(529), "overloaded")
    var policy = retry_policy(2, 50, 200, 400)
    assert_true(retry_decision(policy, 0, 0, 429))
    assert_true(retry_decision(policy, 0, 0, 500))
    assert_true(not retry_decision(policy, 0, 0, 401))
    assert_true(not retry_decision(policy, 0, 0, 422))
    assert_true(not retry_decision(policy, 2, 0, 429))
    assert_true(not retry_decision(policy, 0, 390, 429))
    with assert_raises():
        _ = retry_decision(policy, 0, 0, 200)


def test_transport_cleanup_and_local_cancellation() raises:
    var guard_7 = CleanupGuard()
    with spawn_jev_stub_auto("ok", 1, guard_7) as started:
        var port = started.port
        var outcome = post_jev_systemone(
            "http://127.0.0.1:" + String(port),
            _loads('{"model":"jev-1.13.0","state":"s","questions":{}}'),
            5000,
        )
        assert_equal(outcome.status, 200)
        started.stub.wait()

        # A refused connection is a bounded local transport failure (no listener).
        var dead_port = reserve_jev_port()
        with assert_raises():
            _ = post_jev_systemone(
                "http://127.0.0.1:" + String(dead_port),
                _loads('{"model":"jev-1.13.0","state":"s","questions":{}}'),
                150,
            )

    guard_7.assert_clean()
