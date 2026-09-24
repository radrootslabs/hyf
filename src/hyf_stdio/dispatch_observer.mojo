# ADR-0027 D47 BP02 — bounded in-memory dispatch observation seam.
#
# The pre-activation guard's zero-dispatch obligation is proven with an
# executed counter at the real pre-dispatch boundary. The observer is threaded
# through the dispatch path as a compile-time type parameter: the production
# daemon instantiates ``NoopDispatchAttemptObserver`` (a compile-time no-op with
# no state and no I/O) and tests instantiate
# ``RecordingDispatchAttemptObserver`` (an ordinary in-memory list owned by the
# test invocation). There is no environment variable, file path, global
# observer, dynamic production switch, durable trace facility or runtime
# dependency, and no observer instance is shared across invocations.

from std.collections import List


trait DispatchAttemptObserver:
    """Bounded pre-dispatch boundary observer.

    Implementations must not perform I/O or retain process-global state; the
    production implementation is a compile-time no-op.
    """

    def record_dispatch_attempt(mut self, capability: String):
        ...


@fieldwise_init
struct NoopDispatchAttemptObserver(Copyable, DispatchAttemptObserver, Movable):
    """Compile-time no-op production observer."""

    def record_dispatch_attempt(mut self, capability: String):
        pass


@fieldwise_init
struct RecordingDispatchAttemptObserver(DispatchAttemptObserver, Movable):
    """Test-owned in-memory observer; never used by the production daemon."""

    var attempts: List[String]

    def record_dispatch_attempt(mut self, capability: String):
        self.attempts.append(capability)
