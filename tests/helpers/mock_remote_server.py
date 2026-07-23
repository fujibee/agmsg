#!/usr/bin/env python3
"""Minimal mock of the ADR 0007 pairing-exchange + revoke endpoints, for
bats tests exercising scripts/remote.sh without a real server. Not part of
the shipped product — test-only.

Token -> response behavior, so tests can pick a scenario by token value:
  good-token                    -> 200, write_allowed_ciphers = ["none"]
  good-token-enc                -> 200, write_allowed_ciphers = ["age-v1"]
  bad-token                     -> 401
  malformed-credential-id-token -> 200, but credential_id contains '/'
                                    (path-injection shape) — for B6
  missing-field-token           -> 200, but protocol_version is omitted
                                    entirely — for B6

credential_id is derived deterministically from the token
("cred-<token>") for every other token value, so a test can reconnect
with a fresh/different token and assert the OLD credential_id (tied to
the OLD token) specifically got revoked before the new one was issued.

Revoke: POST /v1/credentials/<id>/revoke -> 200 if <id> is one this
server has ever issued, else 404; each revoked id is recorded so tests
can assert on it via GET /_test/revoked. Set MOCK_REVOKE_FAIL=1 to make
every revoke call fail (returns 500) for the server-unreachable test.
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REVOKE_FAIL = os.environ.get("MOCK_REVOKE_FAIL") == "1"
ISSUED_CREDENTIAL_IDS = set()
REVOKED_CREDENTIAL_IDS = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep test output quiet

    def _send_json(self, code, obj):
        self._send_raw(code, json.dumps(obj))

    def _send_raw(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/_test/revoked":
            self._send_json(200, {"revoked": REVOKED_CREDENTIAL_IDS})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""

        if self.path == "/v1/pairing/exchange":
            try:
                data = json.loads(raw) if raw else {}
            except Exception:
                self._send_json(400, {"error": "bad json"})
                return
            token = data.get("token", "")
            if token == "bad-token":
                self._send_json(401, {"error": "invalid token"})
                return

            if token == "missing-field-token":
                self._send_json(200, {
                    "credential": "session-credential-xyz",
                    "credential_id": "cred-missing-field",
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "remote_team_name": "myteam",
                    "capabilities": {"write_allowed_ciphers": ["none"]},
                })
                return

            if token == "malformed-credential-id-token":
                self._send_json(200, {
                    "credential": "session-credential-xyz",
                    "credential_id": "../../etc/passwd",
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "remote_team_name": "myteam",
                    "protocol_version": 1,
                    "capabilities": {"write_allowed_ciphers": ["none"]},
                })
                return

            if token == "duplicate-key-token":
                # json.dumps() can't produce a duplicate key from a dict
                # (dicts can't have one) — hand-build the raw text so the
                # SECOND "credential_id" is what a naive `.get()`-based
                # parser would silently keep (python's own json.loads also
                # keeps only the last occurrence unless duplicate-key
                # detection is deliberately added).
                self._send_raw(200, """{
                    "credential": "session-credential-xyz",
                    "credential_id": "cred-visible-in-review",
                    "credential_id": "cred-smuggled-in-second-copy",
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "remote_team_name": "myteam",
                    "protocol_version": 1,
                    "capabilities": {"write_allowed_ciphers": ["none"]}
                }""")
                return

            if token == "unknown-field-token":
                self._send_json(200, {
                    "credential": "session-credential-xyz",
                    "credential_id": "cred-unknown-field",
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "remote_team_name": "myteam",
                    "protocol_version": 1,
                    "capabilities": {"write_allowed_ciphers": ["none"]},
                    "unexpected_extra_field": "smuggled-value",
                })
                return

            if token == "control-char-credential-token":
                # A tab in the credential is what previously survived the
                # newline-only check and then broke the hand-rolled
                # sed-based JSON escaping in _remote_commit (E3) — reject
                # it at the validator instead of relying only on the
                # downstream write being fixed.
                self._send_json(200, {
                    "credential": "session-credential\twith-a-tab",
                    "credential_id": "cred-control-char",
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "remote_team_name": "myteam",
                    "protocol_version": 1,
                    "capabilities": {"write_allowed_ciphers": ["none"]},
                })
                return

            ciphers = ["age-v1"] if token == "good-token-enc" else ["none"]
            credential_id = "cred-" + re.sub(r"[^A-Za-z0-9_-]", "-", token)
            ISSUED_CREDENTIAL_IDS.add(credential_id)
            self._send_json(200, {
                "credential": "session-credential-" + token,
                "credential_id": credential_id,
                "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                "remote_team_name": "myteam",
                "protocol_version": 1,
                "capabilities": {
                    "protocol_version": 1,
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "team_name": "myteam",
                    "accepted_envelope_versions": [1],
                    "write_allowed_ciphers": ciphers,
                    "policy_revision": "0",
                    "effective_from_seq": "1",
                    "current_seq": "0",
                    "next_sequence_boundary": "1",
                    "min_available_seq": "0",
                    "max_blob_bytes": "1048576",
                    "policy_history": [{
                        "policy_revision": "0",
                        "effective_from_seq": "1",
                        "accepted_envelope_versions": [1],
                        "write_allowed_ciphers": ciphers,
                    }],
                },
            })
            return

        if self.path.startswith("/v1/credentials/") and self.path.endswith("/revoke"):
            if REVOKE_FAIL:
                self._send_json(500, {"error": "simulated failure"})
                return
            cred_id = self.path.split("/")[3]
            if cred_id in ISSUED_CREDENTIAL_IDS:
                REVOKED_CREDENTIAL_IDS.append(cred_id)
                self._send_json(200, {
                    "protocol_version": 1,
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "credential_id": cred_id,
                    "revoked": True,
                    "revoked_at": "2026-01-01T00:00:00Z",
                })
            else:
                self._send_json(404, {"error": "unknown credential_id"})
            return

        self._send_json(404, {"error": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
