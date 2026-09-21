from std.os import getenv

from hyf_provider.jev_client import post_jev_systemone
from hyf_runtime.jev_composition import typesafe_api_key_present
from hyf_core.normalization.candidates import discover_candidates
from std.collections import List
from json import loads, dumps


comptime BASE_URL = "https://api.typesafe.ai"
comptime MODEL = "jev-1.13.0"


def main() raises:
    if getenv("HYF_EVAL_AUTHORIZED", "") != "1":
        print(
            "BLOCKED: raw-input semantic evaluation is opt-in; set "
            "HYF_EVAL_AUTHORIZED=1 with an authorized reviewed corpus."
        )
        raise Error("eval_not_authorized")
    if not typesafe_api_key_present():
        print(
            "BLOCKED: evaluation requires TYPESAFE_API_KEY; no external call "
            "was made."
        )
        raise Error("live_jev_prerequisite_missing")

    # Raw-input candidate discovery runs locally first.
    var products = List[String]()
    products.append("roma tomatoes")
    var units = List[String]()
    units.append("lb")
    var dates = List[String]()
    dates.append("friday")
    var candidates = discover_candidates(
        "Got about 80 lb of Roma tomatoes. Can deliver Friday.",
        products,
        units,
        dates,
    )
    var body = loads(
        '{"model":"'
        + MODEL
        + '","state":"Got about 80 lb of Roma tomatoes. Can deliver Friday.",'
        + '"questions":{"supply_status":{"type":"choice","instructions":'
        + '"Is produce reported available?","criteria":{"offered":"yes",'
        + '"unclear":"no"}}}}'
    )
    var outcome = post_jev_systemone(BASE_URL, body, 15000)
    print("discovered_candidates=" + String(len(candidates)))
    print("provider_status=" + String(outcome.status))
