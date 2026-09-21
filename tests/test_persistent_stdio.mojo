from std.collections import List
from std.tempfile import TemporaryDirectory
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


def test_persistent_session_processes_multiple_frames() raises:
    with TemporaryDirectory() as temp_dir:
        var context = _context(temp_dir)
        var frames = List[String]()
        frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        frames.append(load_scenario_request_json("scenarios/capabilities_ok.json"))
        frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        var responses = run_stdio_session(frames, context)
        assert_equal(len(responses), 3)
        for response in responses:
            assert_true(response.find('"ok":true') >= 0)


def test_session_recovers_from_malformed_frame() raises:
    with TemporaryDirectory() as temp_dir:
        var context = _context(temp_dir)
        var frames = List[String]()
        frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        frames.append("{not valid json")
        frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        var responses = run_stdio_session(frames, context)
        assert_equal(len(responses), 3)
        assert_true(responses[0].find('"ok":true') >= 0)
        assert_true(responses[1].find('invalid_request') >= 0)
        assert_true(responses[2].find('"ok":true') >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
