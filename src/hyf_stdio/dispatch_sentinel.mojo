# ADR-0026 D46 CR04 — bounded local dispatch sentinel.
#
# Test observation hook only. When ``HYF_DISPATCH_SENTINEL`` names a file path,
# every legacy/shortcut business-capability dispatch attempt appends one line
# naming the capability. The variable is unset in normal runs, so the hook is
# inert there. It exists so the pre-activation guard's zero-dispatch obligation
# can be proven with an executed counter (positive control: a legacy dispatch
# records a line; negative control: a recognized v2 request records nothing)
# rather than by inferring from the absence of shortcut output alone.
#
# This does not add a provider or credential path, and it never records request
# or source payloads; only the capability name is written.

from std.os import getenv


comptime _HYF_DISPATCH_SENTINEL_ENV = "HYF_DISPATCH_SENTINEL"


def hyf_dispatch_sentinel_env_name() -> String:
    return _HYF_DISPATCH_SENTINEL_ENV


def record_business_dispatch_attempt(capability: String):
    var path = getenv(_HYF_DISPATCH_SENTINEL_ENV, "")
    if path == "":
        return
    try:
        with open(path, "a") as sentinel:
            sentinel.write("dispatch " + capability + "\n")
    except:
        pass
