#!/usr/bin/env python3
"""Minimal mock of OpenRouter's /api/alpha/decisions endpoint, for the
ext-tool jev adapter's own test. Not part of the shipped product -- test-only,
and the real OpenRouter API is never called in CI (design note §5b).

It records the most recently received request (path, Authorization header,
and parsed JSON body) so the test can assert handle sent the right thing,
and answers with a configurable decision response or error, without ever
touching the real API.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

REQUEST_LOG = os.environ.get("MOCK_OPENROUTER_REQUEST_LOG", "")
# 200 is the default "real decision" response; 401/429 are the two error
# statuses handle names explicitly, and any other value exercises the
# generic "unexpected HTTP" path.
MOCK_OPENROUTER_HTTP_STATUS = int(os.environ.get("MOCK_OPENROUTER_HTTP_STATUS", "200"))
# When set, the 200 response body is malformed on purpose (missing
# "answers") to exercise handle's "unexpected response shape" failure.
MOCK_OPENROUTER_MALFORMED = os.environ.get("MOCK_OPENROUTER_MALFORMED", "")
# Held before answering, so a test can inspect the CALLER's own process
# table (ps) while a request is genuinely in flight -- proving curl's argv
# never carries the key or the body, not just that the final result happens
# not to show them.
MOCK_OPENROUTER_DELAY_SECONDS = float(os.environ.get("MOCK_OPENROUTER_DELAY_SECONDS", "0"))
# When set, "usage" has no "cost" key at all -- matching TypeSafe's real
# response (confirmed against two live production calls, including
# headers: no cost anywhere). Without this, every scenario got OpenRouter's
# cost field even when testing the TypeSafe path, which is exactly what let
# a real bug (handle's tab-delimited field parsing silently misaligning
# once cost was genuinely empty) pass review-findings-free the first time
# (review finding, #1364).
MOCK_OPENROUTER_NO_COST = os.environ.get("MOCK_OPENROUTER_NO_COST", "")
# Overrides the "model" answer's choice name (and its probability entry).
# Lets a test simulate an adversarial/unusual choice name -- e.g. one
# containing a literal control character -- without handle ever having
# validated `questions` itself (that shape is caller-controlled, echoed
# straight back by the API; see handle's own comment, review finding
# #1364 round 2).
MOCK_OPENROUTER_CHOICE = os.environ.get("MOCK_OPENROUTER_CHOICE", "")
# When set, the "effort" answer in a multi-question response is malformed
# (its "choice" key is dropped entirely) so a test can exercise handle's
# per-row degrade: the OTHER question's real answer still comes back, and
# this one renders as its own error line instead of failing the whole call.
MOCK_OPENROUTER_BAD_ROW = os.environ.get("MOCK_OPENROUTER_BAD_ROW", "")


class LoopbackHTTPServer(HTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence default access logging on stderr
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        if MOCK_OPENROUTER_DELAY_SECONDS > 0:
            time.sleep(MOCK_OPENROUTER_DELAY_SECONDS)
        if REQUEST_LOG:
            try:
                parsed_body = json.loads(raw.decode("utf-8")) if raw else None
            except ValueError:
                parsed_body = None
            with open(REQUEST_LOG, "w") as fh:
                json.dump({
                    "method": self.command,
                    "path": self.path,
                    "headers": dict(self.headers.items()),
                    "authorization": self.headers.get("Authorization", ""),
                    "content_type": self.headers.get("Content-Type", ""),
                    "body": parsed_body,
                }, fh)

        if MOCK_OPENROUTER_HTTP_STATUS == 400:
            payload = {"error": {"message": "max_tokens_exceeded", "code": "max_tokens_exceeded"}}
        elif MOCK_OPENROUTER_HTTP_STATUS == 401:
            payload = {"error": {"message": "invalid API key"}}
        elif MOCK_OPENROUTER_HTTP_STATUS == 429:
            payload = {"error": {"message": "rate limited"}}
        elif MOCK_OPENROUTER_MALFORMED:
            payload = {"model": "typesafe/jev-1.13-20260917", "id": "gen-dec-broken"}
        else:
            payload = {
                "model": "typesafe/jev-1.13-20260917",
                "answers": {
                    "model": {
                        "type": "choice",
                        "choice": "sonnet",
                        "probabilities": {"haiku": 0.10, "sonnet": 0.80, "opus": 0.08, "fable": 0.02},
                        "confidence": 0.90,
                    },
                    "effort": {
                        "type": "choice",
                        "choice": "high",
                        "probabilities": {"low": 0.05, "medium": 0.15, "high": 0.80},
                        "confidence": 0.70,
                    },
                },
                "usage": {"input_tokens": 441, "output_tokens": 85},
                "id": "gen-dec-test",
                "provider": "TypeSafe",
            }
            if not MOCK_OPENROUTER_NO_COST:
                payload["usage"]["cost"] = 0.000018522
            if MOCK_OPENROUTER_CHOICE:
                payload["answers"]["model"]["choice"] = MOCK_OPENROUTER_CHOICE
                payload["answers"]["model"]["probabilities"] = {MOCK_OPENROUTER_CHOICE: 0.80}
            if MOCK_OPENROUTER_BAD_ROW:
                del payload["answers"]["effort"]["choice"]
        body = json.dumps(payload).encode("utf-8")
        self.send_response(MOCK_OPENROUTER_HTTP_STATUS)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = LoopbackHTTPServer(("127.0.0.1", port), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
