from std.collections import List
from safe_tempdir import SafeTempDir
from std.testing import TestSuite, assert_equal, assert_true

from fixture_assertions import load_scenario_request_json
from hyf_runtime.startup import (
    RuntimeStartupContext,
    RuntimeStartupInput,
    resolve_startup_context,
)
from hyf_stdio.server import run_stdio_session


def _context(temp_dir: String) raises -> RuntimeStartupContext:
    return resolve_startup_context(
        RuntimeStartupInput(
            env_paths_profile="repo_local",
            env_repo_local_base_root=temp_dir,
            user_home="/home/unused",
            argv=List[String](),
        )
    )


def test_bounded_process_soak_200_frames() raises:
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        var frames = List[String]()
        for _ in range(200):
            frames.append(
                load_scenario_request_json("scenarios/status_ok.json")
            )
        var responses = run_stdio_session(frames, context)
        assert_equal(len(responses), 200)
        for response in responses:
            assert_true(response.find('"ok":true') >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


from hyf_application.resource_envelope import (
    default_resource_envelope,
    within_envelope,
)


def test_candidate_and_plan_resource_envelope() raises:
    var envelope = default_resource_envelope()
    assert_true(within_envelope(envelope, 10, 2, 100, 5, 1))
    assert_true(not within_envelope(envelope, 1000, 2, 100, 5, 1))
    assert_true(not within_envelope(envelope, 10, 100, 100, 5, 1))
    assert_true(not within_envelope(envelope, 10, 2, 100000, 5, 1))


from hyf_runtime.config import default_loaded_runtime_config, operation_enabled
from hyf_runtime.jev_composition import compose_jev
from hyf_application.authority_sim import (
    apply_expected_version,
    new_authority_simulation,
)


def test_provider_disablement_and_rollback_preserve_state() raises:
    var config = default_loaded_runtime_config()
    config.effective.runtime.enable_farm_update_interpret = True
    config.effective.runtime.enable_buyer_request_interpret = True
    config.effective.runtime.enable_buyer_request_match = True
    assert_true(operation_enabled(config, "farm_update.interpret"))
    config.effective.runtime.disable_provider = True
    assert_true(not operation_enabled(config, "farm_update.interpret"))
    assert_true(not operation_enabled(config, "buyer_request.match"))
    var composition = compose_jev(config)
    assert_equal(composition.reason, "provider_disabled")

    # Model/provider rollback must not erase accepted business state.
    var simulation = new_authority_simulation()
    apply_expected_version(simulation, "s1", "r1", "r1")
    assert_equal(simulation.accepted_changes, 1)
    assert_true(simulation.requires_confirmation)
