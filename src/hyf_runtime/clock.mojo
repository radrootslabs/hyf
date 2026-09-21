from std.ffi import c_long, external_call
from std.time import perf_counter_ns


@fieldwise_init
struct Clock(Copyable, Movable):
    var wall_epoch_seconds: Int
    var monotonic_ns: Int


def fixed_clock(wall_epoch_seconds: Int, monotonic_ns: Int) -> Clock:
    return Clock(wall_epoch_seconds=wall_epoch_seconds, monotonic_ns=monotonic_ns)


def advance(clock: Clock, monotonic_delta_ns: Int) -> Clock:
    return Clock(
        wall_epoch_seconds=clock.wall_epoch_seconds,
        monotonic_ns=clock.monotonic_ns + monotonic_delta_ns,
    )


def clock_wall_epoch_seconds(clock: Clock) -> Int:
    return clock.wall_epoch_seconds


def clock_monotonic_ns(clock: Clock) -> Int:
    return clock.monotonic_ns


def monotonic_elapsed_ns(start: Clock, end: Clock) -> Int:
    return end.monotonic_ns - start.monotonic_ns


def system_wall_epoch_seconds() -> Int:
    return Int(external_call["time", c_long](0))


def system_monotonic_ns() -> Int:
    return Int(perf_counter_ns())


def system_clock() -> Clock:
    return Clock(
        wall_epoch_seconds=system_wall_epoch_seconds(),
        monotonic_ns=system_monotonic_ns(),
    )
