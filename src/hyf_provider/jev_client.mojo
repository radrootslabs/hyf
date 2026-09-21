from flare.http import HttpClient
from flare.tls import TlsConfig, TlsVerify
from json import Value, dumps


@fieldwise_init
struct JevHttpOutcome(Copyable, Movable):
    var status: Int
    var body_text: String


def _is_loopback_host(host: String) -> Bool:
    return (
        host == "localhost"
        or host == "127.0.0.1"
        or host == "[::1]"
        or host == "::1"
    )


def validate_jev_base_url(base_url: String) raises -> String:
    var trimmed = String(String(base_url).strip())
    while trimmed.byte_length() > 1 and trimmed.endswith("/"):
        trimmed = String(trimmed[byte=0:trimmed.byte_length() - 1])
    if trimmed == "":
        raise Error("jev base_url must not be empty")
    var scheme = ""
    var rest = trimmed
    if trimmed.startswith("https://"):
        scheme = "https"
        rest = String(trimmed[byte=8:])
    elif trimmed.startswith("http://"):
        scheme = "http"
        rest = String(trimmed[byte=7:])
    else:
        raise Error("jev base_url must use https")
    if rest.find("@") >= 0:
        raise Error("jev base_url must not contain credentials")
    if rest.find("?") >= 0:
        raise Error("jev base_url must not contain a query")
    if rest.find("#") >= 0:
        raise Error("jev base_url must not contain a fragment")
    var slash = rest.find("/")
    var host_port = rest if slash < 0 else String(rest[byte=0:slash])
    var host = host_port
    var colon = host_port.find(":")
    if colon >= 0:
        if host_port.startswith("["):
            var close = host_port.find("]")
            if close >= 0:
                host = String(host_port[byte=0:close + 1])
        else:
            host = String(host_port[byte=0:colon])
    if host == "":
        raise Error("jev base_url must include a host")
    if scheme == "http" and not _is_loopback_host(host):
        raise Error(
            "jev base_url must use https unless the host is loopback"
        )
    return trimmed^


def jev_systemone_url(base_url: String) raises -> String:
    return validate_jev_base_url(base_url) + "/v1/systemone"


def post_jev_systemone(
    base_url: String, body: Value, timeout_ms: Int
) raises -> JevHttpOutcome:
    var url = jev_systemone_url(base_url)
    with HttpClient(timeout_ms=timeout_ms, max_redirects=0) as client:
        var response = client.post(url, dumps(body))
        return JevHttpOutcome(status=response.status, body_text=response.text())


def production_tls_config() -> TlsConfig:
    return TlsConfig()


def assert_tls_verification_required(config: TlsConfig) raises:
    if config.verify != TlsVerify.REQUIRED:
        raise Error("external provider transport must verify TLS certificates")


def redirects_forward_credentials() -> Bool:
    return False
