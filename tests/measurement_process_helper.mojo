"""Governed test-only persistent-process measurement tooling (ADR-0012 D29).

H005A requires repo-owned, standalone measurement tooling rather than a
docs-resident script. This helper owns exactly one persistent HYF stdio process
and drives warmup plus measured frames over that single process, validating
every frame's parsed envelope, correlation, outcome and count with finite
bounded I/O, a checked child exit and exception-safe cleanup.

It exists only for tests. It changes no HYF product policy, no schema and no
dependency: the process is launched from a build of the existing product entry
point and the samples are read back with the bounded lifecycle primitives.

ADR-0019 D39 MR01-MR05 requalification:

* MR01 — the *whole* stdout stream is accounted for through EOF. Exactly the
  expected warmup/measured frames may succeed; a retained surplus byte, a
  trailing frame in the same or a later chunk, an unterminated tail, early EOF
  and a nonzero exit all fail with a bounded cause. stdout/stderr are drained
  concurrently with request writes and exit observation.
* MR02 — one spawn-relative measurement work deadline covers sampling, request
  writes, response reads, the EOF drain and the child exit. An expired budget
  is never clamped into a fresh successful interval and a late valid response
  is never accepted. Build and pre-spawn identity capture are separate,
  explicitly bounded phases. Byte/output caps distinguish timeout, read error,
  EOF and overflow; stderr read errors and overflow fail explicitly.
* MR03 — every owned descriptor (stdin, stdout, stderr) is closed exactly once
  on success, invalid output, sampling failure, early EOF, nonzero exit and
  timeout. EOF is not descriptor closure. The terminal child state is cached
  before any further wait/signal, and an unproved cleanup retains the exact
  child/descriptor ownership in the caller-held guard.
* MR04 — the product binary is bound to a clean, verified source/tree identity
  plus a deterministic content manifest of the tracked build inputs; capture,
  build and run drift is rejected. Startup is measured from spawn to the first
  validated response, sampling is recorded separately as instrumentation
  overhead, and the secret-free HYF_PATHS profile is read back from the live
  environment.

Explicit failure policy (R56/R57, R69/R70/R71):

* a frame that is not JSON, has the wrong correlation or outcome, or a child
  that exits nonzero, fails the measurement instead of reporting success;
* unavailable ``ps``/``lsof`` sampling raises a sampling error rather than
  recording a placeholder value;
* every read/write/wait is parent-bounded by the one finite work deadline and
  the owned child is always terminated and reaped through the shared ownership
  guard.
"""

import std.os
from std.collections import List
from std.ffi import (
    ErrNo,
    CStringSlice,
    c_int,
    c_ssize_t,
    c_size_t,
    c_uint,
    external_call,
    get_errno,
)

from json import Value, loads

from parent_lifecycle import (
    IO_DEADLINE_EXPIRED,
    POLLERR,
    POLLHUP,
    POLLIN,
    POLLNVAL,
    POLLOUT,
    TERMINATION_GRACE_MS,
    CleanupGuard,
    ProcessStatus,
    child_exit,
    close_fd,
    dup2_fd,
    fork_owned_or_close3,
    make_three_pipes,
    now_ms,
    poll_three,
    read_fd,
    set_alarm,
    sleep_ms,
    terminate_owned,
    wait_bounded,
    write_fd_chunk,
)


comptime MEASUREMENT_FRAME_BYTES = 1048576
comptime MEASUREMENT_CHILD_ALARM_SECONDS = 900
comptime MEASUREMENT_MAX_STDERR_BYTES = 65536
comptime MEASUREMENT_SAMPLE_DEADLINE_MS = 10000
comptime MEASUREMENT_BUILD_DEADLINE_MS = 600000
comptime MEASUREMENT_SAMPLE_INTERVAL = 50
# Bounded polling granularity. Every wait is sliced by this value so an
# idle-but-live child is observed incrementally; the recorded request latency
# therefore carries at most one polling slice of tolerance rather than a fixed
# idle delay. Instrumentation (sampling subprocesses) is timed separately.
comptime MEASUREMENT_POLL_SLICE_MS = 10


# ── Bounded captured commands (identity and sampling) ───────────────────────


@fieldwise_init
struct CommandOutput(Movable):
    var exit_code: Int
    var signal: Int
    var stdout: String
    var stderr: String

    def describe(self) -> String:
        return (
            "exited="
            + String(self.exit_code)
            + " signal="
            + String(self.signal)
        )


def run_capture(
    command: String,
    var args: List[String],
    deadline_ms: Int,
    mut guard: CleanupGuard,
    cwd: String = "",
) raises -> CommandOutput:
    """Run one bounded child command and capture its stdout/stderr.

    The child is owned by this test: it is forked once, its stdio is closed or
    captured, every drain is bounded by ``deadline_ms`` and a timeout terminates
    and reaps the exact owned pid. A non-``execvp`` failure is reported as an
    exit rather than silently succeeding.
    """
    var parts = List[String]()
    parts.append(command)
    for index in range(len(args)):
        parts.append(args[index])
    var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
        length=len(parts) + 1, fill={}
    )
    var elements = parts.unsafe_ptr()
    for index in range(len(parts)):
        argv[index] = rebind[CStringSlice[ImmutAnyOrigin]](
            elements[index].as_c_string_slice()
        )

    var pipes = make_three_pipes()
    var stdin_read_fd = pipes.stdin_pipe.read_fd
    var stdin_write_fd = pipes.stdin_pipe.write_fd
    var stdout_read_fd = pipes.stdout_pipe.read_fd
    var stdout_write_fd = pipes.stdout_pipe.write_fd
    var stderr_read_fd = pipes.stderr_pipe.read_fd
    var stderr_write_fd = pipes.stderr_pipe.write_fd
    var command_ptr = elements[0].as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv.unsafe_ptr()
    var cwd_local = String(cwd)
    var cwd_ptr = cwd_local.as_c_string_slice().unsafe_ptr()

    var pid = fork_owned_or_close3(pipes)
    if pid == 0:
        if dup2_fd(stdin_read_fd, 0) < 0:
            child_exit(126)
        if dup2_fd(stdout_write_fd, 1) < 0:
            child_exit(126)
        if dup2_fd(stderr_write_fd, 2) < 0:
            child_exit(126)
        close_fd(stdin_read_fd)
        close_fd(stdin_write_fd)
        close_fd(stdout_read_fd)
        close_fd(stdout_write_fd)
        close_fd(stderr_read_fd)
        close_fd(stderr_write_fd)
        if cwd != "":
            if Int(external_call["chdir", c_int](cwd_ptr)) != 0:
                child_exit(126)
        _ = set_alarm(MEASUREMENT_CHILD_ALARM_SECONDS)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        child_exit(127)

    close_fd(stdin_read_fd)
    close_fd(stdin_write_fd)
    close_fd(stdout_write_fd)
    close_fd(stderr_write_fd)

    var stdout = List[UInt8]()
    var stderr_bytes = List[UInt8]()
    var stdout_eof = False
    var stderr_eof = False
    var read_reason = ""
    var start = now_ms()
    while not (stdout_eof and stderr_eof):
        var elapsed = now_ms() - start
        if elapsed >= deadline_ms:
            read_reason = "sample_deadline_expired"
            break
        var slice_ms = min(MEASUREMENT_POLL_SLICE_MS * 2, deadline_ms - elapsed)
        if slice_ms < 1:
            slice_ms = 1
        var pr = poll_three(
            -1,
            0,
            stdout_read_fd,
            0 if stdout_eof else POLLIN,
            stderr_read_fd,
            0 if stderr_eof else POLLIN,
            slice_ms,
        )
        if pr.count < 0:
            read_reason = "sample_poll_failed"
            break
        if pr.count == 0:
            continue
        var remaining = deadline_ms - (now_ms() - start)
        if not stdout_eof:
            var d = drain_capture(stdout_read_fd, stdout, pr.r1, remaining)
            stdout_eof = d.eof
            if d.reason != "":
                read_reason = "stdout_" + d.reason
                break
        if not stderr_eof:
            var d = drain_capture(
                stderr_read_fd, stderr_bytes, pr.r2, remaining
            )
            stderr_eof = d.eof
            if d.reason != "":
                read_reason = "stderr_" + d.reason
                break

    close_fd(stdout_read_fd)
    close_fd(stderr_read_fd)
    if read_reason != "":
        var term = terminate_owned(pid, TERMINATION_GRACE_MS)
        guard.retain(
            pid, -1, "measurement sample command " + command + " " + read_reason
        )
        if term.cleanup_proved():
            guard.resolve_pid(pid)
        raise Error(
            "measurement: sample command " + command + " " + read_reason
        )

    var remaining = deadline_ms - (now_ms() - start)
    if remaining <= 0:
        # A bounded sampling phase never converts an expired budget into a new
        # successful interval: the exact owned child is reaped or retained.
        var expired = terminate_owned(pid, TERMINATION_GRACE_MS)
        guard.retain(
            pid, -1, "measurement sample command " + command + " deadline"
        )
        if expired.cleanup_proved():
            guard.resolve_pid(pid)
        raise Error(
            "measurement: sample command "
            + command
            + " sample_deadline_expired"
        )
    var st = wait_bounded(pid, remaining)
    if not st.cleanup_proved():
        var term = terminate_owned(pid, TERMINATION_GRACE_MS)
        guard.retain(
            pid, -1, "measurement sample command " + command + " timeout"
        )
        if term.cleanup_proved():
            guard.resolve_pid(pid)
        raise Error("measurement: sample command " + command + " timeout")
    guard.resolve_pid(pid)

    return CommandOutput(
        exit_code=st.exit_code if st.exited else -1,
        signal=st.signal,
        stdout=bytes_to_text(stdout),
        stderr=bytes_to_text(stderr_bytes),
    )


@fieldwise_init
struct DrainResult(Movable):
    var eof: Bool
    var reason: String


def drain_capture(
    fd: Int, mut out: List[UInt8], revents: Int, deadline_ms: Int
) -> DrainResult:
    """Drain one captured descriptor with a bounded cause."""
    if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0:
        return DrainResult(False, "")
    var buf = InlineArray[Byte, 4096](fill=0)
    var budget = deadline_ms
    if budget < 1:
        budget = 1
    var n = read_fd(fd, buf.unsafe_ptr(), 4096, budget)
    if n == IO_DEADLINE_EXPIRED:
        return DrainResult(True, "read_deadline_expired")
    if n < 0:
        return DrainResult(True, "read_error")
    if n == 0:
        return DrainResult(True, "")
    if len(out) + n > MEASUREMENT_MAX_STDERR_BYTES:
        return DrainResult(True, "capture_overflow")
    for index in range(n):
        out.append(UInt8(Int(buf[index])))
    return DrainResult(False, "")


def bytes_to_text(bytes: List[UInt8]) raises -> String:
    if len(bytes) == 0:
        return ""
    return String(from_utf8=Span(ptr=bytes.unsafe_ptr(), length=len(bytes)))


# ── Identity ────────────────────────────────────────────────────────────────


def run_capture_simple(
    command: String, var args: List[String], mut guard: CleanupGuard
) raises -> CommandOutput:
    return run_capture(command, args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard)


def file_sha256(path: String, mut guard: CleanupGuard) raises -> String:
    """Exact sha256 of ``path`` via a bounded ``shasum``/``sha256sum`` call."""
    var shasum_args = List[String]()
    shasum_args.append("-a")
    shasum_args.append("256")
    shasum_args.append(path)
    var out = run_capture_simple("shasum", shasum_args^, guard)
    if out.exit_code != 0 or out.stdout.strip().byte_length() < 64:
        var sum_args = List[String]()
        sum_args.append(path)
        var alt = run_capture(
            "sha256sum", sum_args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard
        )
        if alt.exit_code != 0 or alt.stdout.strip().byte_length() < 64:
            raise Error("measurement: sha256 unavailable for " + path)
        out = alt^
    var text = String(out.stdout.strip())
    var digest = String(text[byte=0:64])
    _require_hex(digest, 64, "sha256 for " + path)
    return digest


def _require_hex(digest: String, expected_len: Int, label: String) raises:
    if digest.byte_length() != expected_len:
        raise Error(
            "measurement: "
            + label
            + " is not a "
            + String(expected_len)
            + "-character digest"
        )
    for byte in digest.as_bytes():
        var b = Int(byte)
        var is_digit = b >= 48 and b <= 57
        var is_hex = (b >= 97 and b <= 102) or (b >= 65 and b <= 70)
        if not is_digit and not is_hex:
            raise Error("measurement: " + label + " is not hexadecimal")


def host_platform(mut guard: CleanupGuard) raises -> String:
    var args = List[String]()
    args.append("-s")
    args.append("-m")
    var out = run_capture_simple("uname", args^, guard)
    if out.exit_code != 0:
        raise Error("measurement: host platform unavailable")
    return String(out.stdout.strip())


def toolchain_version(mut guard: CleanupGuard) raises -> String:
    var args = List[String]()
    args.append("--version")
    var out = run_capture_simple("mojo", args^, guard)
    if out.exit_code != 0:
        raise Error("measurement: toolchain version unavailable")
    var text = String(out.stdout.strip())
    if text == "":
        text = String(out.stderr.strip())
    if text.byte_length() == 0:
        raise Error("measurement: toolchain version output empty")
    var newline = text.find("\n")
    if newline >= 0:
        return String(text[byte=0:newline])
    return text^


@fieldwise_init
struct SourceTreeIdentity(Movable):
    """Verified source/tree identity for the measured build inputs.

    ``revision``/``tree`` are the exact commit and tree, ``manifest_sha256`` is
    a deterministic content digest of the tracked ``src`` build inputs and
    ``dirty_status`` is the exact ``git status --porcelain`` output for the
    measured paths (``""`` proves a clean tree). A mismatch between capture,
    build and run is a bounded drift failure, never a silent success.
    """

    var source_root: String
    var revision: String
    var tree: String
    var manifest_sha256: String
    var dirty_status: String

    def describe(self) -> String:
        return (
            "revision="
            + self.revision
            + " tree="
            + self.tree
            + " manifest_sha256="
            + self.manifest_sha256
            + " tree_state="
            + (self.dirty_status if self.dirty_status == "" else "dirty")
        )

    def same_as(self, other: SourceTreeIdentity) -> Bool:
        return (
            self.revision == other.revision
            and self.tree == other.tree
            and self.manifest_sha256 == other.manifest_sha256
            and self.dirty_status == other.dirty_status
        )


def git_capture(
    source_root: String, var args: List[String], mut guard: CleanupGuard
) raises -> CommandOutput:
    return run_capture(
        "git", args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard, source_root
    )


def source_revision(
    source_root: String, mut guard: CleanupGuard
) raises -> String:
    """Exact capsule source revision; a measurement must not guess it."""
    var args = List[String]()
    args.append("rev-parse")
    args.append("HEAD")
    var out = git_capture(source_root, args^, guard)
    var text = String(out.stdout.strip())
    if out.exit_code != 0 or text.byte_length() != 40:
        raise Error(
            "measurement: source revision unavailable in " + source_root
        )
    _require_hex(text, 40, "source revision")
    return text^


def source_tree_id(
    source_root: String, mut guard: CleanupGuard
) raises -> String:
    """Exact commit tree object id; distinguishes a content-identical tree."""
    var args = List[String]()
    args.append("rev-parse")
    args.append("HEAD^{tree}")
    var out = git_capture(source_root, args^, guard)
    var text = String(out.stdout.strip())
    if out.exit_code != 0 or text.byte_length() != 40:
        raise Error("measurement: source tree id unavailable in " + source_root)
    _require_hex(text, 40, "source tree id")
    return text^


def source_manifest_sha256(
    source_root: String, mut guard: CleanupGuard
) raises -> String:
    """Deterministic content digest of the tracked ``src`` build inputs.

    The digest covers the index entries (mode/blob/path) of every tracked file
    under ``src`` — the exact inputs of ``mojo build -I src src/main.mojo``.
    It never reads or hashes secrets or arbitrary workspace files.
    """
    var args = List[String]()
    args.append("-c")
    args.append(
        "git ls-files -s -- src | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1"
    )
    var out = run_capture(
        "sh", args^, MEASUREMENT_SAMPLE_DEADLINE_MS, guard, source_root
    )
    var text = String(out.stdout.strip())
    if out.exit_code != 0:
        raise Error(
            "measurement: source content manifest unavailable in " + source_root
        )
    _require_hex(text, 64, "source content manifest")
    return text^


def source_dirty_status(
    source_root: String, mut guard: CleanupGuard
) raises -> String:
    """Exact porcelain status for the measured build inputs and toolchain."""
    var args = List[String]()
    args.append("status")
    args.append("--porcelain")
    args.append("--")
    args.append("src")
    args.append("pixi.toml")
    args.append("pixi.lock")
    var out = git_capture(source_root, args^, guard)
    if out.exit_code != 0:
        raise Error(
            "measurement: source tree status unavailable in " + source_root
        )
    return String(out.stdout.strip())


def source_identity(
    source_root: String, mut guard: CleanupGuard
) raises -> SourceTreeIdentity:
    return SourceTreeIdentity(
        source_root=source_root,
        revision=source_revision(source_root, guard),
        tree=source_tree_id(source_root, guard),
        manifest_sha256=source_manifest_sha256(source_root, guard),
        dirty_status=source_dirty_status(source_root, guard),
    )


def require_clean_source(identity: SourceTreeIdentity, phase: String) raises:
    """Reject a dirty measured build input at capture, build or run time."""
    if identity.dirty_status != "":
        raise Error(
            "measurement: measured source tree is dirty at "
            + phase
            + " ("
            + identity.dirty_status
            + ")"
        )


def require_identity_drift_free(
    before: SourceTreeIdentity, after: SourceTreeIdentity, phase: String
) raises:
    if not before.same_as(after):
        raise Error(
            "measurement: source drifted during "
            + phase
            + " (before "
            + before.describe()
            + " after "
            + after.describe()
            + ")"
        )


def working_directory(mut guard: CleanupGuard) raises -> String:
    var args = List[String]()
    var out = run_capture_simple("pwd", args^, guard)
    if out.exit_code != 0:
        raise Error("measurement: working directory unavailable")
    return String(out.stdout.strip())


def verified_environment_profile() -> String:
    """The environment actually inherited by the measured child, read back.

    Recorded from the live process environment rather than asserted, so the
    reproduced profile is truthful: the measured child inherits exactly these
    values through ``execvp``. The profile is deliberately bounded to the two
    governed, secret-free HYF_PATHS variables.
    """
    var profile = std.os.getenv("HYF_PATHS_PROFILE")
    var root = std.os.getenv("HYF_PATHS_REPO_LOCAL_ROOT")
    return (
        "HYF_PATHS_PROFILE="
        + (profile if profile != "" else "<unset>")
        + " HYF_PATHS_REPO_LOCAL_ROOT="
        + (root if root != "" else "<unset>")
    )


@fieldwise_init
struct MeasurementIdentity(Movable):
    """Exact source/binary/toolchain/host identity and launch profile."""

    var source_root: String
    var source_revision: String
    var source_tree: String
    var source_manifest_sha256: String
    var source_tree_state: String
    var binding: String
    var cwd: String
    var binary_path: String
    var binary_sha256: String
    var pixi_toml_sha256: String
    var pixi_lock_sha256: String
    var toolchain_version: String
    var host_platform: String
    var argv_profile: String
    var env_profile: String

    def describe(self) -> String:
        return (
            "binding="
            + self.binding
            + " source_revision="
            + self.source_revision
            + " source_tree="
            + self.source_tree
            + " source_manifest_sha256="
            + self.source_manifest_sha256
            + " source_tree_state="
            + self.source_tree_state
            + " cwd="
            + self.cwd
            + " binary_sha256="
            + self.binary_sha256
            + " pixi_toml_sha256="
            + self.pixi_toml_sha256
            + " pixi_lock_sha256="
            + self.pixi_lock_sha256
            + " toolchain="
            + self.toolchain_version
            + " host="
            + self.host_platform
            + " argv="
            + self.argv_profile
            + " env="
            + self.env_profile
        )


def measurement_identity(
    source_root: String,
    binary_path: String,
    binary_sha256: String,
    binding: String,
    argv_profile: String,
    mut guard: CleanupGuard,
) raises -> MeasurementIdentity:
    var observed = source_identity(source_root, guard)
    return MeasurementIdentity(
        source_root=source_root,
        source_revision=observed.revision,
        source_tree=observed.tree,
        source_manifest_sha256=observed.manifest_sha256,
        source_tree_state=("dirty" if observed.dirty_status != "" else "clean"),
        binding=binding,
        cwd=working_directory(guard),
        binary_path=binary_path,
        binary_sha256=binary_sha256,
        pixi_toml_sha256=file_sha256(source_root + "/pixi.toml", guard),
        pixi_lock_sha256=file_sha256(source_root + "/pixi.lock", guard),
        toolchain_version=toolchain_version(guard),
        host_platform=host_platform(guard),
        argv_profile=argv_profile,
        env_profile=verified_environment_profile(),
    )


@fieldwise_init
struct BuiltProduct(Movable):
    """A product binary bound to the clean source/tree it was built from.

    The build is a separate, explicitly bounded phase: the pre-build source
    identity is captured, the binary is built, the binary digest is recorded
    and the post-build source identity must be byte-for-byte the same. A
    later run re-verifies the same identity and binary before spawning.
    """

    var binary_path: String
    var binary_sha256: String
    var source: SourceTreeIdentity
    var build_ms: Int


def build_product_binary(
    source_root: String, temp_dir: String, mut guard: CleanupGuard
) raises -> BuiltProduct:
    """Build the existing product entry point once, outside measured frames.

    The measurement itself never compiles or starts a process per frame. The
    build input tree must be clean and must not drift across the build.
    """
    var before = source_identity(source_root, guard)
    require_clean_source(before, "build capture")
    var output = temp_dir + "/hyfd"
    var args = List[String]()
    args.append("build")
    args.append("-I")
    args.append("src")
    args.append("src/main.mojo")
    args.append("-o")
    args.append(output)
    var start = now_ms()
    var out = run_capture(
        "mojo", args^, MEASUREMENT_BUILD_DEADLINE_MS, guard, source_root
    )
    var build_ms = now_ms() - start
    if out.exit_code != 0:
        raise Error(
            "measurement: product build failed (" + out.describe() + ")"
        )
    var binary_sha256 = file_sha256(output, guard)
    var after = source_identity(source_root, guard)
    require_identity_drift_free(before, after, "build")
    return BuiltProduct(
        binary_path=output,
        binary_sha256=binary_sha256,
        source=after^,
        build_ms=build_ms,
    )


# ── Persistent measured process ─────────────────────────────────────────────


@fieldwise_init
struct MeasurementPoll(Movable):
    """One bounded ``poll(2)`` result with an explicit EINTR classification."""

    var count: Int
    var r0: Int
    var r1: Int
    var r2: Int
    var interrupted: Bool


def measurement_poll(
    fd0: Int,
    events0: Int,
    fd1: Int,
    events1: Int,
    fd2: Int,
    events2: Int,
    timeout_ms: Int,
    fault_eintr_count: Int = 0,
) -> MeasurementPoll:
    """Poll three descriptors, classifying a real ``EINTR`` as retryable.

    ``fault_eintr_count`` is a bounded test-only seam: any nonzero value makes
    every attempt report ``EINTR`` so the deadline-bounded retry branch is
    deterministically executable without changing host signal state.
    """
    if fault_eintr_count != 0:
        return MeasurementPoll(-1, 0, 0, 0, True)
    var cell = InlineArray[Int32, 12](fill=0)
    cell[0] = Int32(fd0)
    cell[1] = Int32(events0)
    cell[2] = Int32(fd1)
    cell[3] = Int32(events1)
    cell[4] = Int32(fd2)
    cell[5] = Int32(events2)
    var n = Int(
        external_call["poll", c_int](
            cell.unsafe_ptr(), c_uint(3), c_int(timeout_ms)
        )
    )
    if n < 0:
        if get_errno() == ErrNo.EINTR:
            return MeasurementPoll(-1, 0, 0, 0, True)
        return MeasurementPoll(-1, 0, 0, 0, False)
    if n == 0:
        return MeasurementPoll(0, 0, 0, 0, False)
    return MeasurementPoll(
        n,
        (Int(cell[1]) >> 16) & 0xFFFF,
        (Int(cell[3]) >> 16) & 0xFFFF,
        (Int(cell[5]) >> 16) & 0xFFFF,
        False,
    )


def measurement_poll_retry(
    fd0: Int,
    events0: Int,
    fd1: Int,
    events1: Int,
    fd2: Int,
    events2: Int,
    max_wait_ms: Int,
    fault_eintr_count: Int = 0,
) -> MeasurementPoll:
    """Poll with a deadline-bounded retry of a real ``EINTR``.

    The retry can never outlive ``max_wait_ms``: once the budget is exhausted
    the last interrupted result is returned to the deadline owner instead of
    spinning. ``fault_eintr_count`` is the bounded test-only seam.
    """
    var start = now_ms()
    var slice = min(MEASUREMENT_POLL_SLICE_MS, max_wait_ms)
    if slice < 1:
        slice = 1
    while True:
        var pr = measurement_poll(
            fd0, events0, fd1, events1, fd2, events2, slice, fault_eintr_count
        )
        if not pr.interrupted:
            return pr^
        if now_ms() - start >= max_wait_ms:
            return pr^
        sleep_ms(1)


@fieldwise_init
struct MeasurementProcess(Movable):
    """Exactly one persistent HYF stdio process owned by the measurement.

    stdout/stderr are consumed concurrently with request writes and exit
    observation and are drained to EOF. Every owned descriptor carries an
    explicit close-once flag: EOF is a stream property and never implies that
    the parent descriptor was closed, so no later cleanup can target a reused
    descriptor number.
    """

    var pid: Int
    var stdin_fd: Int
    var stdout_fd: Int
    var stderr_fd: Int
    var stdout_pending: List[UInt8]
    var stderr_bytes: List[UInt8]
    var stdout_eof: Bool
    var stderr_eof: Bool
    var stdin_closed: Bool
    var stdout_closed: Bool
    var stderr_closed: Bool
    var reaped: Bool
    var status: ProcessStatus
    var spawn_ms: Int
    var deadline_at_ms: Int
    var stdout_total_bytes: Int
    var guard: UnsafePointer[CleanupGuard, MutAnyOrigin]

    def work_remaining_ms(self) -> Int:
        """Remaining part of the one spawn-relative measurement work budget.

        A nonpositive result must never be turned into a new successful
        interval; callers fail and use only the separate bounded cleanup
        allowance.
        """
        return self.deadline_at_ms - now_ms()

    def close_stdin(mut self):
        if self.stdin_closed:
            return
        close_fd(self.stdin_fd)
        self.stdin_fd = -1
        self.stdin_closed = True

    def close_stdout(mut self):
        if self.stdout_closed:
            return
        # A descriptor retained by the guard for recovery is closed by the
        # guard exactly once, so the handle can never close a reused number.
        if not self.guard[].close_retained_fd(self.stdout_fd):
            close_fd(self.stdout_fd)
        self.stdout_closed = True

    def close_stderr(mut self):
        if self.stderr_closed:
            return
        close_fd(self.stderr_fd)
        self.stderr_closed = True

    def stdout_pending_len(self) -> Int:
        return len(self.stdout_pending)

    def stderr_len(self) -> Int:
        return len(self.stderr_bytes)

    def drain_stdout(mut self, revents: Int, budget_ms: Int) raises:
        """Drain ready stdout bytes with a bounded size cap and cause."""
        if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0:
            return
        if budget_ms < 1:
            raise Error(
                "measurement: work deadline expired during stdout drain"
                " (work_deadline_expired)"
            )
        var buf = InlineArray[Byte, 4096](fill=0)
        var n = read_fd(self.stdout_fd, buf.unsafe_ptr(), 4096, budget_ms)
        if n == IO_DEADLINE_EXPIRED:
            raise Error(
                "measurement: stdout read deadline expired"
                " (work_deadline_expired)"
            )
        if n < 0:
            raise Error("measurement: stdout read_error")
        if n == 0:
            self.stdout_eof = True
            return
        self.stdout_total_bytes += n
        if len(self.stdout_pending) + n > MEASUREMENT_FRAME_BYTES:
            raise Error("measurement: stdout_overflow")
        for index in range(n):
            self.stdout_pending.append(UInt8(Int(buf[index])))

    def drain_stderr(mut self, revents: Int, budget_ms: Int) raises:
        """Drain ready stderr bytes; errors and overflow fail explicitly."""
        if (revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0:
            return
        if budget_ms < 1:
            raise Error(
                "measurement: work deadline expired during stderr drain"
                " (work_deadline_expired)"
            )
        var buf = InlineArray[Byte, 4096](fill=0)
        var n = read_fd(self.stderr_fd, buf.unsafe_ptr(), 4096, budget_ms)
        if n == IO_DEADLINE_EXPIRED:
            raise Error(
                "measurement: stderr read deadline expired"
                " (work_deadline_expired)"
            )
        if n < 0:
            raise Error("measurement: stderr read_error")
        if n == 0:
            self.stderr_eof = True
            return
        if len(self.stderr_bytes) + n > MEASUREMENT_MAX_STDERR_BYTES:
            raise Error("measurement: stderr_overflow")
        for index in range(n):
            self.stderr_bytes.append(UInt8(Int(buf[index])))

    def poll_and_drain(
        mut self,
        want_stdin_write: Bool,
        max_wait_ms: Int,
        fault_eintr_count: Int = 0,
    ) raises -> Bool:
        """Poll stdin/stdout/stderr and drain whatever is ready.

        Returns True when the stdin write end is writable. All waits are sliced
        by ``MEASUREMENT_POLL_SLICE_MS`` inside the caller's remaining budget;
        a real ``EINTR`` is retried until the budget expires.
        """
        if max_wait_ms <= 0:
            raise Error(
                "measurement: work deadline expired (work_deadline_expired)"
            )
        var slice = min(MEASUREMENT_POLL_SLICE_MS, max_wait_ms)
        var fd0 = self.stdin_fd if (
            want_stdin_write and not self.stdin_closed
        ) else -1
        var fd1 = self.stdout_fd if (
            not self.stdout_eof and not self.stdout_closed
        ) else -1
        var fd2 = self.stderr_fd if (
            not self.stderr_eof and not self.stderr_closed
        ) else -1
        if fd0 < 0 and fd1 < 0 and fd2 < 0:
            sleep_ms(slice)
            return False
        var start = now_ms()
        var pr = measurement_poll_retry(
            fd0,
            POLLOUT if fd0 >= 0 else 0,
            fd1,
            POLLIN if fd1 >= 0 else 0,
            fd2,
            POLLIN if fd2 >= 0 else 0,
            max_wait_ms,
            fault_eintr_count,
        )
        if pr.count > 0:
            var remaining = max_wait_ms - (now_ms() - start)
            if fd0 >= 0 and (pr.r0 & (POLLERR | POLLHUP | POLLNVAL)) != 0:
                raise Error("measurement: request write pipe closed")
            if (
                fd1 >= 0
                and (pr.r1 & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0
            ):
                self.drain_stdout(pr.r1, remaining)
            if (
                fd2 >= 0
                and (pr.r2 & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0
            ):
                self.drain_stderr(pr.r2, remaining)
            return fd0 >= 0 and (pr.r0 & POLLOUT) != 0
        return False

    def send_frame(mut self, frame: String, index: Int) raises:
        """Write one newline-delimited request frame within the work budget.

        stdout/stderr are drained concurrently while the request is written, so
        a child that emits output during the write can never deadlock the
        parent. There is no fixed idle wait in the request latency.
        """
        if self.stdin_closed:
            raise Error("measurement: request write after stdin closed")
        var payload = frame + "\n"
        var sent = 0
        var total = payload.byte_length()
        while sent < total:
            var remaining = self.work_remaining_ms()
            if remaining <= 0:
                raise Error(
                    "measurement: work deadline expired during request write"
                    " (work_deadline_expired)"
                )
            var writable = self.poll_and_drain(True, remaining)
            if self.stdin_closed:
                raise Error("measurement: request write pipe closed")
            if not writable:
                continue
            var remaining_write = self.work_remaining_ms()
            if remaining_write <= 0:
                raise Error(
                    "measurement: work deadline expired during request write"
                    " (work_deadline_expired)"
                )
            var cw = write_fd_chunk(
                self.stdin_fd, payload, sent, remaining_write
            )
            if cw.reason == "write_deadline_expired":
                raise Error("measurement: request write deadline expired")
            if cw.reason != "":
                raise Error(
                    "measurement: request write failed (" + cw.reason + ")"
                )
            if cw.written <= 0:
                continue
            sent += cw.written

    def read_response(mut self, index: Int) raises -> String:
        """Read one complete newline-terminated response within the budget."""
        while True:
            var found = _newline_index(self.stdout_pending)
            if found >= 0:
                if found > MEASUREMENT_FRAME_BYTES:
                    raise Error("measurement: response frame overflow")
                var line_bytes = _list_prefix(self.stdout_pending, found)
                self.stdout_pending = _list_suffix(
                    self.stdout_pending, found + 1
                )
                return _decode_frame(line_bytes^)
            if self.stdout_eof:
                if len(self.stdout_pending) == 0:
                    raise Error(
                        "measurement: response stream reached EOF with no"
                        " frame (early_eof)"
                    )
                raise Error(
                    "measurement: response frame was not newline-terminated"
                )
            var remaining = self.work_remaining_ms()
            if remaining <= 0:
                raise Error(
                    "measurement: work deadline expired while awaiting"
                    " response (work_deadline_expired)"
                )
            _ = self.poll_and_drain(False, remaining)

    def assert_no_surplus(mut self, index: Int) raises:
        """Exactly one response per request: surplus bytes are a failure."""
        if len(self.stdout_pending) > 0:
            raise Error(
                "measurement: unexpected trailing stdout ("
                + String(len(self.stdout_pending))
                + " bytes) after response "
                + String(index)
            )

    def finish_expected(mut self, total: Int) raises -> ProcessStatus:
        """Close stdin, account the whole stream through EOF and reap.

        The remaining stdout stream must be exactly empty after the expected
        responses, stderr must reach a clean EOF and the child must exit within
        the remaining work budget. The terminal state is cached before any
        further wait or signal.
        """
        if len(self.stdout_pending) > 0:
            raise Error(
                "measurement: unexpected trailing stdout ("
                + String(len(self.stdout_pending))
                + " bytes) after "
                + String(total)
                + " expected responses"
            )
        self.close_stdin()
        while not (self.stdout_eof and self.stderr_eof):
            var remaining = self.work_remaining_ms()
            if remaining <= 0:
                raise Error(
                    "measurement: work deadline expired during output drain"
                    " (work_deadline_expired)"
                )
            _ = self.poll_and_drain(False, remaining)
            if len(self.stdout_pending) > 0:
                raise Error(
                    "measurement: unexpected trailing stdout ("
                    + String(len(self.stdout_pending))
                    + " bytes) after "
                    + String(total)
                    + " expected responses"
                )
        var remaining_exit = self.work_remaining_ms()
        if remaining_exit <= 0:
            raise Error(
                "measurement: work deadline expired before child exit"
                " (work_deadline_expired)"
            )
        var st = wait_bounded(self.pid, remaining_exit)
        if not st.cleanup_proved():
            self.status = st.copy()
            var term = terminate_owned(self.pid, TERMINATION_GRACE_MS)
            self.status = term.copy()
            if term.cleanup_proved():
                self.reaped = True
                self.guard[].resolve_pid(self.pid)
            else:
                self.guard[].retain(
                    self.pid,
                    self.stdout_fd,
                    "measurement process cleanup unproved " + term.describe(),
                )
            raise Error(
                "measurement: process did not exit within its budget ("
                + term.describe()
                + ")"
            )
        self.status = st.copy()
        self.reaped = True
        self.guard[].resolve_pid(self.pid)
        self.close_stdout()
        self.close_stderr()
        return st^

    def cleanup(mut self):
        """Non-raising cleanup so a failing assertion still reaps the child."""
        self.close_stdin()
        if not self.reaped:
            var st = terminate_owned(self.pid, TERMINATION_GRACE_MS)
            self.status = st.copy()
            if st.cleanup_proved():
                self.reaped = True
                self.guard[].resolve_pid(self.pid)
            else:
                self.guard[].retain(
                    self.pid,
                    self.stdout_fd,
                    "measurement process cleanup unproved " + st.describe(),
                )
        self.close_stdout()
        self.close_stderr()

    def stderr_text(self) raises -> String:
        return bytes_to_text(
            _list_prefix(self.stderr_bytes, len(self.stderr_bytes))
        )


def _newline_index(bytes: List[UInt8]) -> Int:
    for index in range(len(bytes)):
        if Int(bytes[index]) == 10:
            return index
    return -1


def _list_prefix(bytes: List[UInt8], count: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for index in range(count):
        out.append(bytes[index])
    return out^


def _list_suffix(bytes: List[UInt8], start: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for index in range(start, len(bytes)):
        out.append(bytes[index])
    return out^


def _decode_frame(var bytes: List[UInt8]) raises -> String:
    try:
        return bytes_to_text(bytes^)
    except:
        raise Error("measurement: response frame is not valid UTF-8")


def spawn_measurement_process(
    binary_path: String,
    var argv: List[String],
    deadline_ms: Int,
    mut guard: CleanupGuard,
) raises -> MeasurementProcess:
    """Fork exactly one persistent process for warmup and measured frames."""
    var parts = List[String]()
    parts.append(binary_path)
    for index in range(len(argv)):
        parts.append(argv[index])
    var argv_c = List[Optional[CStringSlice[ImmutAnyOrigin]]](
        length=len(parts) + 1, fill={}
    )
    var elements = parts.unsafe_ptr()
    for index in range(len(parts)):
        argv_c[index] = rebind[CStringSlice[ImmutAnyOrigin]](
            elements[index].as_c_string_slice()
        )

    var pipes = make_three_pipes()
    var stdin_read_fd = pipes.stdin_pipe.read_fd
    var stdin_write_fd = pipes.stdin_pipe.write_fd
    var stdout_read_fd = pipes.stdout_pipe.read_fd
    var stdout_write_fd = pipes.stdout_pipe.write_fd
    var stderr_read_fd = pipes.stderr_pipe.read_fd
    var stderr_write_fd = pipes.stderr_pipe.write_fd
    var command_ptr = elements[0].as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv_c.unsafe_ptr()

    var spawn_ms = now_ms()
    var pid = fork_owned_or_close3(pipes)
    if pid == 0:
        if dup2_fd(stdin_read_fd, 0) < 0:
            child_exit(126)
        if dup2_fd(stdout_write_fd, 1) < 0:
            child_exit(126)
        if dup2_fd(stderr_write_fd, 2) < 0:
            child_exit(126)
        close_fd(stdin_read_fd)
        close_fd(stdin_write_fd)
        close_fd(stdout_read_fd)
        close_fd(stdout_write_fd)
        close_fd(stderr_read_fd)
        close_fd(stderr_write_fd)
        _ = set_alarm(MEASUREMENT_CHILD_ALARM_SECONDS)
        _ = external_call["execvp", c_int](command_ptr, argv_ptr)
        child_exit(127)

    close_fd(stdin_read_fd)
    close_fd(stdout_write_fd)
    close_fd(stderr_write_fd)
    return MeasurementProcess(
        pid=pid,
        stdin_fd=stdin_write_fd,
        stdout_fd=stdout_read_fd,
        stderr_fd=stderr_read_fd,
        stdout_pending=List[UInt8](),
        stderr_bytes=List[UInt8](),
        stdout_eof=False,
        stderr_eof=False,
        stdin_closed=False,
        stdout_closed=False,
        stderr_closed=False,
        reaped=False,
        status=ProcessStatus("pending", False, -1, 0, 0, ""),
        spawn_ms=spawn_ms,
        deadline_at_ms=spawn_ms + deadline_ms,
        stdout_total_bytes=0,
        guard=UnsafePointer(to=guard),
    )


# ── Frame validation ────────────────────────────────────────────────────────


@fieldwise_init
struct FrameVerdict(Movable):
    """Bounded per-frame validation result."""

    var ok: Bool
    var reason: String
    var outcome: String
    var declared_max_requests: Int

    def describe(self) -> String:
        return (
            "ok="
            + String(self.ok)
            + " outcome="
            + self.outcome
            + " reason="
            + self.reason
        )


def _has_key(value: Value, key: String) -> Bool:
    for candidate in value.object_keys():
        if String(candidate) == key:
            return True
    return False


def _field_string(value: Value, key: String) raises -> String:
    if not value.is_object():
        return ""
    if not _has_key(value, key):
        return ""
    var field = value[key]
    if not field.is_string():
        return ""
    return String(field.string_value())


def validate_status_frame(
    response_text: String,
    expected_request_id: String,
    expected_trace_id: String,
) raises -> FrameVerdict:
    """Validate one status frame's parsed envelope, correlation and outcome."""
    var parsed = Value(None)
    try:
        parsed = loads(response_text)
    except:
        return FrameVerdict(False, "not_json", "", -1)
    if not parsed.is_object():
        return FrameVerdict(False, "not_object", "", -1)
    if not _has_key(parsed, "version"):
        return FrameVerdict(False, "missing_version", "", -1)
    if Int(parsed["version"].int_value()) != 1:
        return FrameVerdict(False, "version_mismatch", "", -1)
    var request_id = _field_string(parsed, "request_id")
    if request_id != expected_request_id:
        return FrameVerdict(False, "correlation_mismatch", "", -1)
    var trace_id = _field_string(parsed, "trace_id")
    if trace_id != expected_trace_id:
        return FrameVerdict(False, "trace_mismatch", "", -1)
    if not _has_key(parsed, "ok"):
        return FrameVerdict(False, "missing_outcome", "", -1)
    if not parsed["ok"].bool_value():
        return FrameVerdict(False, "not_ok", "", -1)
    if _has_key(parsed, "error"):
        return FrameVerdict(False, "unexpected_error", "", -1)
    if not _has_key(parsed, "output") or not parsed["output"].is_object():
        return FrameVerdict(False, "missing_output", "", -1)
    var daemon = _field_string(parsed["output"], "daemon")
    if daemon != "hyfd":
        return FrameVerdict(False, "outcome_mismatch", "", -1)
    var declared = -1
    var output = parsed["output"]
    if _has_key(output, "limits") and output["limits"].is_object():
        var limits = output["limits"]
        if _has_key(limits, "max_requests_per_process"):
            declared = Int(limits["max_requests_per_process"].int_value())
    return FrameVerdict(True, "", "sys.status_ok", declared)


def build_status_frame(index: Int) -> List[String]:
    """One status request frame plus its expected request/trace correlation."""
    var request_id = "meas-status-" + String(index)
    var trace_id = "meas-trace-" + String(index)
    var frame = (
        '{"version":1,"request_id":"'
        + request_id
        + '","trace_id":"'
        + trace_id
        + '","capability":"sys.status","input":{}}'
    )
    var pair = List[String]()
    pair.append(frame)
    pair.append(request_id)
    pair.append(trace_id)
    return pair^


# ── Sampling ────────────────────────────────────────────────────────────────


def sample_rss_kb(
    pid: Int,
    command: String,
    mut guard: CleanupGuard,
    deadline_ms: Int = MEASUREMENT_SAMPLE_DEADLINE_MS,
) raises -> Int:
    """Numeric resident-set size in kB, or an explicit sampling failure.

    The sampling subprocess consumes the caller's remaining work budget, so
    instrumentation can never extend the measured window.
    """
    if deadline_ms <= 0:
        raise Error(
            "measurement: work deadline expired before rss sampling"
            " (work_deadline_expired)"
        )
    var args = List[String]()
    args.append("-o")
    args.append("rss=")
    args.append("-p")
    args.append(String(pid))
    var out = run_capture(command, args^, deadline_ms, guard)
    if out.exit_code != 0:
        raise Error(
            "measurement: rss sampling unavailable ("
            + command
            + " "
            + out.describe()
            + ")"
        )
    var text = String(out.stdout.strip())
    if text.byte_length() == 0:
        raise Error("measurement: rss sampling returned no value")
    for byte in text.as_bytes():
        var b = Int(byte)
        if b < 48 or b > 57:
            raise Error("measurement: rss sampling value is not numeric")
    return Int(text)


def sample_fd_count(
    pid: Int,
    command: String,
    mut guard: CleanupGuard,
    deadline_ms: Int = MEASUREMENT_SAMPLE_DEADLINE_MS,
) raises -> Int:
    """Numeric descriptor count, excluding lsof cwd/txt/mem pseudo rows."""
    if deadline_ms <= 0:
        raise Error(
            "measurement: work deadline expired before descriptor sampling"
            " (work_deadline_expired)"
        )
    var args = List[String]()
    args.append("-p")
    args.append(String(pid))
    args.append("-F")
    args.append("f")
    var out = run_capture(command, args^, deadline_ms, guard)
    if out.exit_code != 0:
        raise Error(
            "measurement: descriptor sampling unavailable ("
            + command
            + " "
            + out.describe()
            + ")"
        )
    var count = 0
    for line in out.stdout.split("\n"):
        var entry = String(line).strip()
        if entry.byte_length() < 2:
            continue
        if not entry.startswith("f"):
            continue
        var digits = String(entry[byte=1:])
        var numeric = True
        for byte in digits.as_bytes():
            var b = Int(byte)
            if b < 48 or b > 57:
                numeric = False
                break
        if numeric:
            count += 1
    if count == 0:
        raise Error("measurement: descriptor sampling counted no descriptors")
    return count


def child_process_count(
    pid: Int,
    mut guard: CleanupGuard,
    deadline_ms: Int = MEASUREMENT_SAMPLE_DEADLINE_MS,
) raises -> Int:
    """Numeric count of live direct children of ``pid`` (0 when none)."""
    if deadline_ms <= 0:
        raise Error(
            "measurement: work deadline expired before child census"
            " (work_deadline_expired)"
        )
    var args = List[String]()
    args.append("-P")
    args.append(String(pid))
    var out = run_capture("pgrep", args^, deadline_ms, guard)
    if out.exit_code == 1:
        return 0
    if out.exit_code != 0:
        raise Error(
            "measurement: child census unavailable (" + out.describe() + ")"
        )
    var count = 0
    for line in out.stdout.split("\n"):
        if String(line).strip().byte_length() > 0:
            count += 1
    return count


# ── Measurement session ─────────────────────────────────────────────────────


@fieldwise_init
struct MeasurementSession(Movable):
    """Validated result of one persistent warmup/measured process."""

    var identity: MeasurementIdentity
    var warmup_frames: Int
    var measured_frames: Int
    var ok_frames: Int
    var failed_frames: Int
    var first_failure: String
    var startup_ms: Int
    var startup_wall_ms: Int
    var startup_sampling_ms: Int
    var warmup_ms: Int
    var measured_wall_ms: Int
    var measured_sampling_ms: Int
    var measured_ms: Int
    var request_total_ms: Int
    var request_min_ms: Int
    var request_max_ms: Int
    var rss_kb_before_warmup: Int
    var rss_kb_after_warmup: Int
    var rss_kb_after_measured: Int
    var rss_kb_peak: Int
    var fd_before_warmup: Int
    var fd_after_measured: Int
    var fd_peak: Int
    var declared_max_requests_per_process: Int
    var child_exit: String
    var stderr_excerpt: String
    var sampling_method: String
    var sampling_cadence: String

    def summary(self) -> String:
        return (
            "frames="
            + String(self.warmup_frames + self.measured_frames)
            + " ok="
            + String(self.ok_frames)
            + " failed="
            + String(self.failed_frames)
            + " startup_ms="
            + String(self.startup_ms)
            + " startup_wall_ms="
            + String(self.startup_wall_ms)
            + " startup_sampling_ms="
            + String(self.startup_sampling_ms)
            + " warmup_ms="
            + String(self.warmup_ms)
            + " measured_ms="
            + String(self.measured_ms)
            + " measured_wall_ms="
            + String(self.measured_wall_ms)
            + " measured_sampling_ms="
            + String(self.measured_sampling_ms)
            + " request_total_ms="
            + String(self.request_total_ms)
            + " request_min_ms="
            + String(self.request_min_ms)
            + " request_max_ms="
            + String(self.request_max_ms)
            + " rss_kb="
            + String(self.rss_kb_before_warmup)
            + "/"
            + String(self.rss_kb_after_warmup)
            + "/"
            + String(self.rss_kb_after_measured)
            + " peak="
            + String(self.rss_kb_peak)
            + " fd="
            + String(self.fd_before_warmup)
            + "/"
            + String(self.fd_after_measured)
            + " peak="
            + String(self.fd_peak)
            + " child="
            + self.child_exit
            + " stderr_bytes="
            + String(self.stderr_excerpt.byte_length())
            + " first_failure="
            + (self.first_failure if self.first_failure != "" else "none")
        )


def argv_profile_of(binary_path: String, var argv: List[String]) -> String:
    """Machine-derived argv profile of the measured child (not asserted)."""
    var profile = String("<" + binary_path + ">")
    for index in range(len(argv)):
        profile += " " + argv[index]
    return profile^


def measure_persistent_process(
    source_root: String,
    binary_path: String,
    var argv: List[String],
    warmup_frames: Int,
    measured_frames: Int,
    deadline_ms: Int,
    mut guard: CleanupGuard,
    rss_sampler: String = "ps",
    fd_sampler: String = "lsof",
    expected_revision: String = "",
    expected_manifest_sha256: String = "",
    expected_binary_sha256: String = "",
) raises -> MeasurementSession:
    """Drive warmup then measured frames over one persistent owned process.

    Identity capture is a separate bounded phase before the spawn; the single
    spawn-relative work deadline then covers sampling, request writes, response
    reads, the EOF drain and the child exit. When ``expected_revision`` is
    provided (product measurement) the measured source tree must be clean and
    the observed revision/tree/manifest must match the build exactly; a
    mismatch before or after the run is a bounded drift failure. Controlled
    test children record the observed identity as ``controlled_child`` and do
    not claim a build binding.
    """
    if warmup_frames < 0 or measured_frames < 1:
        raise Error("measurement: invalid warmup/measured frame counts")
    if deadline_ms <= 0:
        raise Error("measurement: invalid work deadline")
    var binding = (
        "clean_product_tree" if expected_revision != "" else "controlled_child"
    )
    var observed = source_identity(source_root, guard)
    if expected_revision != "":
        require_clean_source(observed, "run capture")
        if observed.revision != expected_revision:
            raise Error(
                "measurement: source revision drift before run (expected "
                + expected_revision
                + " observed "
                + observed.revision
                + ")"
            )
        if observed.manifest_sha256 != expected_manifest_sha256:
            raise Error(
                "measurement: source manifest drift before run (expected "
                + expected_manifest_sha256
                + " observed "
                + observed.manifest_sha256
                + ")"
            )
    var binary_sha256 = file_sha256(binary_path, guard)
    if expected_binary_sha256 != "" and binary_sha256 != expected_binary_sha256:
        raise Error(
            "measurement: binary drift before run (expected "
            + expected_binary_sha256
            + " observed "
            + binary_sha256
            + ")"
        )
    var identity = measurement_identity(
        source_root,
        binary_path,
        binary_sha256,
        binding,
        argv_profile_of(binary_path, argv.copy()),
        guard,
    )
    var process = spawn_measurement_process(
        binary_path, argv^, deadline_ms, guard
    )
    var ok_frames = 0
    var failed_frames = 0
    var first_failure = ""
    var startup_ms = -1
    var startup_wall_ms = -1
    var startup_sampling_ms = 0
    var warmup_ms = 0
    var measured_wall_ms = 0
    var measured_sampling_ms = 0
    var measured_ms = 0
    var request_total_ms = 0
    var request_min_ms = -1
    var request_max_ms = 0
    var rss_before = 0
    var rss_after_warmup = 0
    var rss_after_measured = 0
    var rss_peak = 0
    var fd_before = 0
    var fd_after = 0
    var fd_peak = 0
    var declared = -1
    var child_exit = ""
    var stderr_excerpt = ""

    try:
        # Instrumentation before the first frame; timed as overhead so the
        # recorded startup latency is the child's own work.
        var pre_sample_start = now_ms()
        var pre_remaining = process.work_remaining_ms()
        rss_before = sample_rss_kb(
            process.pid, rss_sampler, guard, pre_remaining
        )
        var pre_remaining_fd = process.work_remaining_ms()
        fd_before = sample_fd_count(
            process.pid, fd_sampler, guard, pre_remaining_fd
        )
        var pre_sample_ms = now_ms() - pre_sample_start
        rss_peak = rss_before
        fd_peak = fd_before
        var warmup_start = now_ms()
        var measured_start = -1
        var total = warmup_frames + measured_frames
        for index in range(total):
            var pair = build_status_frame(index)
            var frame = pair[0]
            var request_id = pair[1]
            var trace_id = pair[2]
            var frame_start = now_ms()
            process.send_frame(frame, index)
            var response = process.read_response(index)
            process.assert_no_surplus(index)
            var latency = now_ms() - frame_start
            if index == 0:
                # Startup is the true spawn-to-first-validated-response
                # latency; any sampling that overlapped the child's own
                # startup is recorded separately as instrumentation rather than
                # subtracted, so the value can never understate real startup.
                startup_wall_ms = now_ms() - process.spawn_ms
                startup_sampling_ms = pre_sample_ms
                startup_ms = startup_wall_ms
            var verdict = validate_status_frame(response, request_id, trace_id)
            if verdict.declared_max_requests >= 0:
                declared = verdict.declared_max_requests
            if verdict.ok:
                ok_frames += 1
            else:
                failed_frames += 1
                if first_failure == "":
                    first_failure = (
                        "frame="
                        + String(index)
                        + " reason="
                        + verdict.reason
                        + " response="
                        + response
                    )
                # A mandatory per-frame guarantee failed: fail loudly instead
                # of reporting a partially successful measurement.
                raise Error("measurement: frame invalid " + first_failure)
            if index == warmup_frames - 1:
                warmup_ms = now_ms() - warmup_start
                var s_start = now_ms()
                var s_remaining = process.work_remaining_ms()
                rss_after_warmup = sample_rss_kb(
                    process.pid, rss_sampler, guard, s_remaining
                )
                var s_remaining_fd = process.work_remaining_ms()
                fd_peak = max(
                    fd_peak,
                    sample_fd_count(
                        process.pid, fd_sampler, guard, s_remaining_fd
                    ),
                )
                if rss_after_warmup > rss_peak:
                    rss_peak = rss_after_warmup
                measured_start = now_ms()
                measured_sampling_ms -= now_ms() - s_start
            if index >= warmup_frames:
                var measured_index = index - warmup_frames
                request_total_ms += latency
                if request_min_ms < 0 or latency < request_min_ms:
                    request_min_ms = latency
                if latency > request_max_ms:
                    request_max_ms = latency
                if measured_index % MEASUREMENT_SAMPLE_INTERVAL == 0:
                    var s_start = now_ms()
                    var s_remaining = process.work_remaining_ms()
                    var mid_rss = sample_rss_kb(
                        process.pid, rss_sampler, guard, s_remaining
                    )
                    var s_remaining_fd = process.work_remaining_ms()
                    var mid_fd = sample_fd_count(
                        process.pid, fd_sampler, guard, s_remaining_fd
                    )
                    measured_sampling_ms += now_ms() - s_start
                    if mid_rss > rss_peak:
                        rss_peak = mid_rss
                    if mid_fd > fd_peak:
                        fd_peak = mid_fd
        # Post-measured instrumentation (still inside the measured window).
        var post_start = now_ms()
        var post_remaining = process.work_remaining_ms()
        rss_after_measured = sample_rss_kb(
            process.pid, rss_sampler, guard, post_remaining
        )
        var post_remaining_fd = process.work_remaining_ms()
        fd_after = sample_fd_count(
            process.pid, fd_sampler, guard, post_remaining_fd
        )
        measured_sampling_ms += now_ms() - post_start
        if rss_after_measured > rss_peak:
            rss_peak = rss_after_measured
        if fd_after > fd_peak:
            fd_peak = fd_after
        measured_wall_ms = now_ms() - measured_start
        measured_ms = measured_wall_ms - measured_sampling_ms
        var st = process.finish_expected(total)
        child_exit = st.describe() + " cleanup=proved"
        stderr_excerpt = process.stderr_text()
        if not st.exited or st.exit_code != 0:
            raise Error(
                "measurement: child exited nonzero ("
                + st.describe()
                + ") stderr="
                + stderr_excerpt
            )
        # Post-run drift rejection: the measured binary and source must be the
        # same ones captured before the run.
        var after = source_identity(source_root, guard)
        if expected_revision != "":
            require_identity_drift_free(observed, after, "run")
        var binary_after = file_sha256(binary_path, guard)
        if binary_after != binary_sha256:
            raise Error(
                "measurement: binary drifted during run (before "
                + binary_sha256
                + " after "
                + binary_after
                + ")"
            )
    except e:
        process.cleanup()
        raise Error("measurement: persistent measurement failed: " + String(e))

    return MeasurementSession(
        identity=identity^,
        warmup_frames=warmup_frames,
        measured_frames=measured_frames,
        ok_frames=ok_frames,
        failed_frames=failed_frames,
        first_failure=first_failure,
        startup_ms=startup_ms,
        startup_wall_ms=startup_wall_ms,
        startup_sampling_ms=startup_sampling_ms,
        warmup_ms=warmup_ms,
        measured_wall_ms=measured_wall_ms,
        measured_sampling_ms=measured_sampling_ms,
        measured_ms=measured_ms,
        request_total_ms=request_total_ms,
        request_min_ms=request_min_ms,
        request_max_ms=request_max_ms,
        rss_kb_before_warmup=rss_before,
        rss_kb_after_warmup=rss_after_warmup,
        rss_kb_after_measured=rss_after_measured,
        rss_kb_peak=rss_peak,
        fd_before_warmup=fd_before,
        fd_after_measured=fd_after,
        fd_peak=fd_peak,
        declared_max_requests_per_process=declared,
        child_exit=child_exit,
        stderr_excerpt=stderr_excerpt,
        sampling_method=(
            "ps -o rss= -p <pid> (kB) / "
            + fd_sampler
            + " -p <pid> -F f numeric f<digits> rows"
        ),
        sampling_cadence=(
            "before warmup, after warmup, every "
            + String(MEASUREMENT_SAMPLE_INTERVAL)
            + " measured frames, after measured phase"
        ),
    )
