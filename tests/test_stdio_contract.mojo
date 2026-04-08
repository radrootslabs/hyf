from std.os import Pipe, Process
from std.testing import assert_equal, assert_true, TestSuite
from std.ffi import CStringSlice, c_int, external_call
from std.sys._libc import close, exit, vfork

from mojson import Value, loads


comptime _EXPECTED_INTERNAL_ERROR_MESSAGE = (
    "internal hyf daemon error; inspect local diagnostics"
)


def _dup2(oldfd: c_int, newfd: c_int) -> c_int:
    return external_call["dup2", c_int](oldfd, newfd)


def _read_pipe_to_string(mut pipe: Pipe) raises -> String:
    var buffer = InlineArray[Byte, 4096](fill=0)
    var output = String("")
    while True:
        var read = pipe.read_bytes(Span(buffer))
        if read == 0:
            break
        output += String(
            from_utf8=Span(ptr=buffer.unsafe_ptr(), length=Int(read))
        )
    return output^


def _run_entrypoint(entrypoint: String, request_json: String) raises -> Value:
    var stdin_pipe = Pipe()
    var stdout_pipe = Pipe()
    var output = String("")
    var command = String("mojo")
    var include_flag = String("-I")
    var include_path = String("src")
    var entrypoint_path = String(entrypoint)
    var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
        length=6, fill={}
    )
    argv[0] = rebind[CStringSlice[ImmutAnyOrigin]](
        command.as_c_string_slice()
    )
    argv[1] = rebind[CStringSlice[ImmutAnyOrigin]](
        "run".as_c_string_slice()
    )
    argv[2] = rebind[CStringSlice[ImmutAnyOrigin]](
        include_flag.as_c_string_slice()
    )
    argv[3] = rebind[CStringSlice[ImmutAnyOrigin]](
        include_path.as_c_string_slice()
    )
    argv[4] = rebind[CStringSlice[ImmutAnyOrigin]](
        entrypoint_path.as_c_string_slice()
    )

    var pid = vfork()
    if pid < 0:
        raise Error("failed to spawn hyf process test child")

    if pid == 0:
        if _dup2(c_int(stdin_pipe.fd_in.value().value), 0) < 0:
            exit(126)
        if _dup2(c_int(stdout_pipe.fd_out.value().value), 1) < 0:
            exit(126)
        _ = close(c_int(stdin_pipe.fd_in.value().value))
        _ = close(c_int(stdin_pipe.fd_out.value().value))
        _ = close(c_int(stdout_pipe.fd_in.value().value))
        _ = close(c_int(stdout_pipe.fd_out.value().value))
        _ = external_call["execvp", c_int](
            command.as_c_string_slice().unsafe_ptr(),
            argv.unsafe_ptr(),
        )
        exit(127)

    stdin_pipe.set_output_only()
    stdout_pipe.set_input_only()

    stdin_pipe.write_bytes((request_json + "\n").as_bytes())
    stdin_pipe.set_input_only()

    output = _read_pipe_to_string(stdout_pipe)
    stdout_pipe.set_output_only()

    var process = Process(Int(pid))
    var status = process.wait()
    if not status.exit_code or status.exit_code.value() != 0:
        raise Error("hyf process exited unexpectedly")

    if output == "":
        raise Error("hyf process returned no stdout payload")
    return loads(output)


def _run_hyf(request_json: String) raises -> Value:
    return _run_entrypoint("src/main.mojo", request_json)

def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if candidate == key:
            return True
    return False


def test_status_success() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"status-proc-1","trace_id":"trace-status-proc-1","capability":"sys.status","input":{}}'
    )

    assert_equal(Int(response["version"].int_value()), 1)
    assert_equal(response["request_id"].string_value(), "status-proc-1")
    assert_equal(response["trace_id"].string_value(), "trace-status-proc-1")
    assert_true(response["ok"].bool_value())
    assert_equal(
        response["output"]["build_identity"]["service_name"].string_value(),
        "hyf",
    )
    assert_equal(
        response["output"]["execution_mode_request_behavior"]["assisted"].string_value(),
        "backend_unavailable",
    )
    assert_equal(
        response["output"]["request_context_contract"]["accepted_features"][2].string_value(),
        "scope.listing_ids",
    )
    assert_equal(
        response["output"]["request_context_contract"]["effective_features"][0].string_value(),
        "execution_mode_preference",
    )


def test_invalid_envelope_preserves_correlation() raises:
    var response = _run_hyf(
        '{"version":2,"request_id":"bad-envelope-proc-1","trace_id":"trace-bad-envelope-proc-1","capability":"sys.status","input":{}}'
    )

    assert_equal(Int(response["version"].int_value()), 1)
    assert_equal(response["request_id"].string_value(), "bad-envelope-proc-1")
    assert_equal(
        response["trace_id"].string_value(), "trace-bad-envelope-proc-1"
    )
    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")


def test_assisted_request_fails_explicitly() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"assisted-proc-1","capability":"query_rewrite","context":{"execution_mode_preference":"assisted"},"input":{"text":"eggs near me"}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "backend_unavailable")


def test_semantic_rank_exports_heuristic_score_without_latency() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"rank-proc-1","capability":"semantic_rank","input":{"query":"eggs near me with weekend pickup","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2},{"id":"lst_8k1p","title":"Free range eggs","farm":"Santa Elena","delivery":"delivery","distance_km":8.7,"freshness_minutes":18}]}}'
    )

    assert_true(response["ok"].bool_value())
    assert_equal(
        response["output"]["scored_candidates"][0]["heuristic_score"].int_value(),
        102,
    )
    assert_true(not _has_key(response["output"]["scored_candidates"][0], "score"))
    assert_true(not _has_key(response["meta"], "latency_ms"))


def test_strict_query_rewrite_failure() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"rewrite-bad-proc-1","capability":"query_rewrite","input":{"text":"eggs near me","tone":"brief"}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_strict_semantic_rank_failure() raises:
    var response = _run_hyf(
        '{"version":1,"request_id":"rank-bad-proc-1","capability":"semantic_rank","input":{"query":"eggs near me","candidates":[{"id":"lst_7ak2","title":"Pasture eggs","farm":"La Huerta del Sur","delivery":"pickup","distance_km":3.2,"freshness_minutes":2,"rating":5}]}}'
    )

    assert_true(not response["ok"].bool_value())
    assert_equal(response["error"]["code"].string_value(), "invalid_request")
    assert_true(
        response["error"]["message"].string_value().find("unexpected field")
        >= 0
    )


def test_internal_error_is_bounded_on_wire() raises:
    var response = _run_entrypoint(
        "tests/internal_error_stdio_main.mojo",
        '{"version":1,"request_id":"status-internal-proc-1","trace_id":"trace-status-internal-proc-1","capability":"sys.status","input":{}}',
    )

    assert_equal(Int(response["version"].int_value()), 1)
    assert_equal(
        response["request_id"].string_value(),
        "status-internal-proc-1",
    )
    assert_equal(
        response["trace_id"].string_value(),
        "trace-status-internal-proc-1",
    )
    assert_true(not response["ok"].bool_value())
    assert_equal(
        response["error"]["code"].string_value(), "internal_error"
    )
    assert_equal(
        response["error"]["message"].string_value(),
        _EXPECTED_INTERNAL_ERROR_MESSAGE,
    )
    assert_true(
        response["error"]["message"].string_value().find("simulated test-only")
        < 0
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
