from flare.http import HttpClient

from hyf_provider.config import MaxLocalProviderConfig


def _trim_trailing_slash(url: String) -> String:
    if url.endswith("/") and url.byte_length() > 1:
        return String(url[byte = 0 : url.byte_length() - 1])
    return String(url)


def make_max_local_http_client(
    config: MaxLocalProviderConfig,
) -> HttpClient:
    return HttpClient(timeout_ms=config.request_timeout_ms)


def max_local_chat_completions_url(
    config: MaxLocalProviderConfig,
) -> String:
    return _trim_trailing_slash(config.base_url) + "/chat/completions"
