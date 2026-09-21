from std.os import getenv

from hyf_provider.jev_client import post_jev_systemone
from hyf_runtime.jev_composition import typesafe_api_key_present
from json import loads


comptime BASE_URL = "https://api.typesafe.ai"
comptime MODEL = "jev-1.13.0"


def main() raises:
    if not typesafe_api_key_present():
        print(
            "BLOCKED: live Jev smoke requires TYPESAFE_API_KEY and explicit "
            "authorization; no external call was made."
        )
        raise Error("live_jev_prerequisite_missing")
    var body = loads(
        '{"model":"'
        + MODEL
        + '","state":"Roma tomatoes available now; basil sold out.",'
        + '"questions":{"supply_status":{"type":"choice","instructions":'
        + '"Is produce reported available?","criteria":{"offered":"yes",'
        + '"unclear":"no"}}}}'
    )
    var outcome = post_jev_systemone(BASE_URL, body, 15000)
    if outcome.status < 200 or outcome.status >= 300:
        raise Error("live Jev smoke failed with status " + String(outcome.status))
    print("ok: live Jev smoke status " + String(outcome.status))
