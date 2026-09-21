from std.collections import List
from safe_tempdir import SafeTempDir
from std.testing import TestSuite, assert_equal, assert_true

from fixture_assertions import load_scenario_request_json
from hyf_runtime.startup import (
    RuntimeStartupContext,
    RuntimeStartupInput,
    resolve_startup_context,
)
from hyf_stdio.server import MAX_FRAME_BYTES, run_stdio_session


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
    with SafeTempDir() as temp_dir:
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
    with SafeTempDir() as temp_dir:
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


def test_session_preserves_order_and_recovers_after_malformed() raises:
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        var frames = List[String]()
        frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        frames.append("{bad json")
        frames.append(load_scenario_request_json("scenarios/capabilities_ok.json"))
        var responses = run_stdio_session(frames, context)
        assert_equal(len(responses), 3)
        assert_true(responses[0].find('"ok":true') >= 0)
        assert_true(responses[1].find('invalid_request') >= 0)
        assert_true(responses[2].find('"ok":true') >= 0)
        assert_true(responses[2].find('business_capabilities') >= 0)


def test_session_rejects_oversized_frame() raises:
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        var huge = String("")
        for _ in range(MAX_FRAME_BYTES + 1):
            huge += "x"
        assert_true(huge.byte_length() == MAX_FRAME_BYTES + 1)
        var frames = List[String]()
        frames.append(huge)
        frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        var responses = run_stdio_session(frames, context)
        assert_true(responses[0].find("size limit") >= 0)
        assert_true(responses[1].find('"ok":true') >= 0)


def test_session_accepts_frame_at_configured_limit() raises:
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        var at_limit = String("")
        for _ in range(MAX_FRAME_BYTES):
            at_limit += "x"
        assert_true(at_limit.byte_length() == MAX_FRAME_BYTES)
        var frames = List[String]()
        frames.append(at_limit)
        frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        var responses = run_stdio_session(frames, context)
        assert_true(responses[0].find("size limit") < 0)
        assert_true(responses[1].find('"ok":true') >= 0)


def test_farm_update_operation_is_gated_until_enabled() raises:
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        var request = (
            '{"version":1,"request_id":"farm-op-1","capability":"farm_update.interpret",'
            '"input":{"source":{"source_id":"s1","revision":"r1",'
            '"text":"Got about 80 lb of Roma tomatoes.",'
            '"source_time":"2026-09-21T09:00:00-07:00","timezone":"America/Vancouver",'
            '"actor_id":"farm-1","farm_id":"farm-1"}}}'
        )
        var frames = List[String]()
        frames.append(request)
        var responses = run_stdio_session(frames, context)
        assert_true(responses[0].find("capability_disabled") >= 0)


def test_buyer_match_operation_is_gated_until_enabled() raises:
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        var request = (
            '{"version":1,"request_id":"match-op-1","capability":"buyer_request.match",'
            '"input":{"need":{"need_id":"n1"},"snapshots":[]}}'
        )
        var frames = List[String]()
        frames.append(request)
        var responses = run_stdio_session(frames, context)
        assert_true(responses[0].find("capability_disabled") >= 0)


from fixture_loader import load_fixture_json_file as _load_fixture_json
from std.pathlib import Path as _Path, _dir_of_current_file as _dir_of


def test_new_operation_wire_frames_are_gated() raises:
    var wire_dir = _dir_of() / "fixtures" / "hyf_v1_jev" / "wire"
    var manifest = _load_fixture_json(wire_dir / "manifest.json")
    assert_equal(manifest["spec_id"].string_value(), "hyf_v1_jev")
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        for name in manifest["scenarios"].array_items():
            var scenario = _load_fixture_json(wire_dir / name.string_value())
            var frames = List[String]()
            frames.append(scenario["request"].string_value())
            var responses = run_stdio_session(frames, context)
            assert_true(
                responses[0].find(scenario["expected_error_code"].string_value()) >= 0
            )


def test_long_session_processes_many_frames_in_order() raises:
    with SafeTempDir() as temp_dir:
        var context = _context(temp_dir)
        var frames = List[String]()
        for index in range(50):
            frames.append(load_scenario_request_json("scenarios/status_ok.json"))
        var responses = run_stdio_session(frames, context)
        assert_equal(len(responses), 50)
        for response in responses:
            assert_true(response.find('"ok":true') >= 0)
            assert_true(response.find("status-fixture-1") >= 0)
