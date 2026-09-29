#!/usr/bin/env python3
"""Minimal mock of the Slack Web API's chat.postMessage, for the ext-tool
slack adapter's own test. Not part of the shipped product -- test-only.

Slack's Web API answers every call with HTTP 200 and an {"ok": ...} envelope
-- even a failure is a 200 with "ok": false -- so that is the only shape this
fixture needs to produce. It records the most recently received request
(path, Authorization header, and parsed JSON body) so the test can assert
handle sent the right thing, without ever touching a real workspace.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Slack's own error code for this response. Empty means answer {"ok": true,
# "channel": "...", "ts": "..."} instead -- the fixture defaults to the
# failure case because that is the one behavior this test exists to prove
# (handle turns a Slack-reported error into a one-line failure).
MOCK_SLACK_ERROR = os.environ.get("MOCK_SLACK_ERROR", "not_in_channel")
REQUEST_LOG = os.environ.get("MOCK_SLACK_REQUEST_LOG", "")
# Slack's real rate limiting is the one case that answers with a non-200
# status (429) instead of a 200 {"ok": false, ...} envelope -- everything
# else, including every other error, is a plain 200.
MOCK_SLACK_HTTP_STATUS = int(os.environ.get("MOCK_SLACK_HTTP_STATUS", "200"))
# Held before answering, so a test can inspect the CALLER's own process
# table (ps) while a request is genuinely in flight -- proving curl's argv
# never carries the token or the body, not just that the final result
# happens not to show them.
MOCK_SLACK_DELAY_SECONDS = float(os.environ.get("MOCK_SLACK_DELAY_SECONDS", "0"))


class LoopbackHTTPServer(HTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence default access logging on stderr
        pass

    def _handle(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        if MOCK_SLACK_DELAY_SECONDS > 0:
            time.sleep(MOCK_SLACK_DELAY_SECONDS)
        if REQUEST_LOG:
            try:
                parsed_body = json.loads(raw.decode("utf-8")) if raw else None
            except ValueError:
                parsed_body = None
            with open(REQUEST_LOG, "w") as fh:
                json.dump({
                    "method": self.command,
                    "path": self.path,
                    "authorization": self.headers.get("Authorization", ""),
                    "content_type": self.headers.get("Content-Type", ""),
                    "body": parsed_body,
                }, fh)
        if MOCK_SLACK_HTTP_STATUS == 429:
            payload = {"ok": False, "error": "ratelimited"}
        elif MOCK_SLACK_ERROR:
            payload = {"ok": False, "error": MOCK_SLACK_ERROR}
        else:
            payload = {"ok": True, "channel": "C0000000000", "ts": "1234567890.000100"}
        body = json.dumps(payload).encode("utf-8")
        self.send_response(MOCK_SLACK_HTTP_STATUS)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self._handle()

    def do_GET(self):
        self._handle()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = LoopbackHTTPServer(("127.0.0.1", port), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
