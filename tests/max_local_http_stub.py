import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def query_rewrite_analysis():
    return {
        "original_text": "local apples pickup weekend",
        "normalized_text": "local apples pickup weekend",
        "rewritten_text": "apples pickup weekend",
        "query_terms": ["apples", "pickup", "weekend"],
        "normalization_signals": ["lowercase", "local_intent_detected"],
        "ranking_hints": ["prefer_local_results", "prefer_pickup"],
        "extracted_filters": {
            "local_intent": True,
            "fulfillment": "pickup",
            "time_window": "weekend",
        },
    }


def chat_completion(body):
    return {
        "choices": [
            {
                "message": {
                    "content": json.dumps(body, separators=(",", ":"))
                }
            }
        ]
    }


class StubServer(HTTPServer):
    def __init__(self, server_address, handler_class, mode, requests):
        super().__init__(server_address, handler_class)
        self.mode = mode
        self.requests_remaining = requests


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _send(self, status, payload, content_type="application/json"):
        if isinstance(payload, str):
            body = payload.encode("utf-8")
        else:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            if self.server.mode == "health_non_2xx":
                self._send(503, {"status": "unavailable"})
            else:
                self._send(200, {"status": "ok"})
            return
        self._send(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self._send(404, {"error": "not_found"})
            return
        mode = self.server.mode
        if mode == "query_rewrite_ok":
            self._send(200, chat_completion(query_rewrite_analysis()))
        elif mode == "query_rewrite_non_2xx":
            self._send(503, {"error": {"message": "provider unavailable"}})
        elif mode == "query_rewrite_invalid_json":
            self._send(200, '{"choices":[{"message":{"content":"not json"}}]}')
        elif mode == "query_rewrite_schema_invalid":
            body = query_rewrite_analysis()
            del body["rewritten_text"]
            self._send(200, chat_completion(body))
        elif mode == "query_rewrite_empty_choices":
            self._send(200, {"choices": []})
        elif mode == "query_rewrite_missing_content":
            self._send(200, {"choices": [{"message": {}}]})
        elif mode == "query_rewrite_error_payload":
            self._send(200, {"error": {"message": "provider refusal"}})
        elif mode == "query_rewrite_timeout":
            time.sleep(2)
            self._send(200, chat_completion(query_rewrite_analysis()))
        else:
            self._send(500, {"error": "unsupported_mode"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--requests", type=int, default=2)
    args = parser.parse_args()

    server = StubServer(
        ("127.0.0.1", args.port), Handler, args.mode, args.requests
    )
    print("ready", flush=True)
    while server.requests_remaining > 0:
        server.handle_request()
        server.requests_remaining -= 1
    server.server_close()


if __name__ == "__main__":
    main()
