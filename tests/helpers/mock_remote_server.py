#!/usr/bin/env python3
"""Minimal mock of the remote-connect pairing-exchange + revoke endpoints, for
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

credential_id is a deterministic canonical UUIDv7 derived from the token
for every other token value, so a test can reconnect
with a fresh/different token and assert the OLD credential_id (tied to
the OLD token) specifically got revoked before the new one was issued.

Revoke: POST /v1/credentials/<id>/revoke -> 200 if <id> is one this
server has ever issued, else 404; each revoked id is recorded so tests
can assert on it via GET /_test/revoked. Set MOCK_REVOKE_FAIL=1 to make
every revoke call fail (returns 500) for the server-unreachable test.
"""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import TCPServer

REVOKE_FAIL = os.environ.get("MOCK_REVOKE_FAIL") == "1"
REVOKE_BAD_HEADER = os.environ.get("MOCK_REVOKE_BAD_HEADER") == "1"
REVOKE_BAD_BODY = os.environ.get("MOCK_REVOKE_BAD_BODY") == "1"
REVOKE_LARGE_BODY = os.environ.get("MOCK_REVOKE_LARGE_BODY") == "1"
PULL_MIXED = os.environ.get("MOCK_PULL_MIXED") == "1"
PULL_AGE = os.environ.get("MOCK_PULL_AGE") == "1"
PULL_AGE_ENVELOPE_FILE = os.environ.get("MOCK_PULL_AGE_ENVELOPE_FILE", "")
CONNECT_CIPHERS = (["none"] if os.environ.get("MOCK_CONNECT_NO_AGE") == "1"
                   else ["none", "age-v1"])
ISSUED_CREDENTIAL_IDS = set()
REVOKED_CREDENTIAL_IDS = []

# POST /v1/connect registers a client-owned team once. No credential is issued
# or returned — reaching the server is the permission. A team_id already
# registered is refused 409 (a uniqueness conflict, like a non-fast-forward).
CONNECT_SERVER_ID = "018f3f7e-3333-7000-8000-000000000001"
REGISTERED_TEAM_IDS = set()


PULL_SERVER_ID = CONNECT_SERVER_ID
PULL_TEAM_ID = (
    os.environ.get("MOCK_PULL_TEAM_ID")
    or "018f3f7e-2222-7000-8000-000000000002"
)
PULL_MEMBERS = [
    {"member_id": "018f3f7e-4444-7000-8000-000000000001",
     "name": "member-1", "registrations": []},
]
# cipher "none" carries the message as the base64 of its canonical JSON, which
# is what the client decodes on import.
def _blob(from_agent, to_agent, body, at):
    import base64
    payload = json.dumps({"body": body, "created_at": at,
                          "from_agent": from_agent, "to_agent": to_agent},
                         separators=(",", ":"), sort_keys=True)
    return base64.b64encode(payload.encode()).decode()

def _roster_blob(index):
    import base64
    payload = json.dumps({
        "kind": "member_joined",
        "mutation_id": "018f3f7e-3333-7000-8000-%012d" % (index + 1),
        "member_id": "018f3f7e-4444-7000-8000-%012d" % (index + 1),
        "name": "member-%d" % (index + 1),
        "occurred_at": "2026-01-01T00:00:%02d.000000Z" % index,
    }, separators=(",", ":"))
    return base64.b64encode(payload.encode()).decode()

BASE_PULL_MESSAGES = [
    {"id": "11111111-1111-4111-8111-111111111111", "server_seq": "1",
     "server_received_at": "2026-01-01T00:00:00.000000Z",
     "envelope": {"v": 1, "cipher": "none", "key_id": None,
                  "blob": _blob("alice", "bob", "history one", "2026-01-01T00:00:00.000000Z")}},
    {"id": "22222222-2222-4222-8222-222222222222", "server_seq": "2",
     "server_received_at": "2026-01-02T00:00:00.000000Z",
     "envelope": {"v": 1, "cipher": "none", "key_id": None,
                  "blob": _blob("bob", "alice", "history two", "2026-01-02T00:00:00.000000Z")}},
]

if PULL_AGE:
    age_envelope = (
        json.load(open(PULL_AGE_ENVELOPE_FILE, encoding="utf-8"))
        if PULL_AGE_ENVELOPE_FILE else
        {"v": 1, "cipher": "age-v1", "key_id": "epoch-0",
         "blob": "ZW5jcnlwdGVk"}
    )
    PULL_MESSAGES = [
        {"id": "10000000-0000-4000-8000-000000000001",
         "server_seq": "1",
         "server_received_at": "2026-01-01T00:00:00.000000Z",
         "envelope": {"v": 1, "cipher": "none", "key_id": None,
                      "blob": _roster_blob(0)}},
        {"id": "20000000-0000-4000-8000-000000000001",
         "server_seq": "2",
         "server_received_at": "2026-01-02T00:00:00.000000Z",
         "envelope": age_envelope},
    ]
elif PULL_MIXED:
    PULL_MESSAGES = [
        {"id": "10000000-0000-4000-8000-%012d" % (index + 1),
         "server_seq": str(index + 1),
         "server_received_at": "2026-01-01T00:00:%02d.000000Z" % index,
         "envelope": {"v": 1, "cipher": "none", "key_id": None,
                      "blob": _roster_blob(index)}}
        for index in range(7)
    ] + [
        {"id": "20000000-0000-4000-8000-%012d" % (index + 1),
         "server_seq": str(index + 8),
         "server_received_at": "2026-01-02T00:00:00.000000Z",
         "envelope": {"v": 1, "cipher": "none", "key_id": None,
                      "blob": _blob("member-1", "member-2",
                                    "mixed history %d" % (index + 1),
                                    "2026-01-02T00:00:00.000000Z")}}
        for index in range(73)
    ]
else:
    PULL_MESSAGES = BASE_PULL_MESSAGES
PUSHED_MESSAGES = []


class LoopbackHTTPServer(HTTPServer):
    """HTTPServer without a reverse-DNS lookup during fixture startup."""

    def server_bind(self):
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep test output quiet

    def _send_json(self, code, obj, protocol="1", oversized_header=False):
        self._send_raw(code, json.dumps(obj), protocol, oversized_header)

    def _send_raw(self, code, text, protocol="1", oversized_header=False):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        if protocol is not None:
            self.send_header("Agmsg-Protocol-Version", protocol)
        if oversized_header:
            self.send_header("X-Oversized-Header", "x" * 70_000)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v1/health":
            self._send_json(200, {
                "status": "ok",
                "database": "ok",
                "server_instance_id": CONNECT_SERVER_ID,
            })
            return
        if self.path == "/v1/capabilities":
            team_id = self.headers.get("Agmsg-Team-ID", "")
            current_seq = (len(PULL_MESSAGES) + len(PUSHED_MESSAGES)
                           if team_id == PULL_TEAM_ID else 0)
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
                "current_seq": str(current_seq),
                "next_sequence_boundary": str(current_seq + 1),
                "min_available_seq": "0",
                "accepted_envelope_versions": [1],
                "write_allowed_ciphers": CONNECT_CIPHERS,
                "policy_revision": "0",
                "effective_from_seq": "1",
                "max_blob_bytes": "1048576",
                "policy_history": [{
                    "policy_revision": "0",
                    "effective_from_seq": "1",
                    "accepted_envelope_versions": [1],
                    "write_allowed_ciphers": CONNECT_CIPHERS,
                }],
            })
            return
        if self.path == "/_test/revoked":
            self._send_json(200, {"revoked": REVOKED_CREDENTIAL_IDS})
            return
        if self.path == "/_test/pushed":
            self._send_json(200, {"messages": PUSHED_MESSAGES})
            return
        parts = self.path.split("?", 1)
        route = parts[0]
        query = parts[1] if len(parts) > 1 else ""
        if route == "/v1/members":
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_id": PULL_TEAM_ID,
                "min_available_seq": "0",
                "members_revision": "0",
                "members": PULL_MEMBERS,
            })
            return
        if route == "/v1/messages":
            after = 0
            for pair in query.split("&"):
                if pair.startswith("after="):
                    after = int(pair[len("after="):])
            page = [m for m in PULL_MESSAGES + PUSHED_MESSAGES
                    if int(m["server_seq"]) > after]
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_id": PULL_TEAM_ID,
                "messages": page,
                "next_after": page[-1]["server_seq"] if page else str(after),
                "has_more": False,
            })
            return
        # The pull side: a machine that has none of this asking for a team by
        # id. No credential, matching /v1/connect -- reaching the server is the
        # permission.
        if route == "/v1/teams":
            # MOCK_DUPLICATE_NAME makes the lookup answer with two teams sharing
            # the requested name, which is the branch the client cannot resolve
            # on its own.
            wanted = ""
            for pair in query.split("&"):
                if pair.startswith("name="):
                    from urllib.parse import unquote
                    wanted = unquote(pair[len("name="):])
            # A server the client must not believe. Each mode carries a marker
            # that would be visible on a terminal if the value reached one, so a
            # test can assert on its absence rather than on an exit status
            # alone. MOCK_LOOKUP_BAD names which field goes wrong.
            bad = os.environ.get("MOCK_LOOKUP_BAD", "")
            if bad and wanted:
                poison = "\x1b[2K\rMARKER-INJECTED"
                good = {"team_id": PULL_TEAM_ID, "team_name": wanted,
                        "registered_at": "2026-07-29T00:00:00.000000Z",
                        "current_seq": "2"}
                other = dict(good, team_id="018f3f7e-2222-7000-8000-0000000000ff",
                             registered_at="2026-07-12T00:00:00.000000Z")
                teams, root = [good], {}
                if bad == "team_id":
                    teams = [dict(good, team_id="not-a-uuid" + poison)]
                elif bad == "name_mismatch":
                    teams = [dict(good, team_name=wanted + poison)]
                elif bad == "timestamp":
                    teams = [dict(good, registered_at="2026-07-29" + poison)]
                elif bad == "sequence":
                    teams = [dict(good, current_seq="-1" + poison)]
                elif bad == "extra_field":
                    teams = [dict(good, roster=poison)]
                elif bad == "multiple":
                    teams = [good, dict(other, registered_at="2026-07-12" + poison)]
                elif bad == "flood":
                    teams = [dict(good, team_id="018f3f7e-%04d-7000-8000-0000000000ff" % i)
                             for i in range(40)]
                elif bad == "protocol":
                    root = {"protocol_version": 2}
                elif bad == "server_id":
                    root = {"server_instance_id": "not-a-uuid" + poison}
                elif bad == "root_name":
                    root = {"team_name": wanted + poison}
                self._send_json(200, {
                    **{"protocol_version": 1,
                       "server_instance_id": PULL_SERVER_ID,
                       "team_name": wanted,
                       "teams": teams},
                    **root,
                })
                return
            if os.environ.get("MOCK_DUPLICATE_NAME") == wanted and wanted:
                self._send_json(200, {
                    "protocol_version": 1,
                    "server_instance_id": PULL_SERVER_ID,
                    "team_name": wanted,
                    "teams": [
                        {"team_id": PULL_TEAM_ID, "team_name": wanted,
                         "registered_at": "2026-07-29T00:00:00.000000Z",
                         "current_seq": "2"},
                        {"team_id": "018f3f7e-2222-7000-8000-0000000000ff",
                         "team_name": wanted,
                         "registered_at": "2026-07-12T00:00:00.000000Z",
                         "current_seq": "4"},
                    ],
                })
                return
            teams = []
            if wanted == "pulled-team":
                teams = [{"team_id": PULL_TEAM_ID, "team_name": wanted,
                          "registered_at": "2026-07-29T00:00:00.000000Z",
                          "current_seq": str(len(PULL_MESSAGES))}]
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_name": wanted,
                "teams": teams,
            })
            return
        if route == "/v1/teams/%s" % PULL_TEAM_ID:
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_id": PULL_TEAM_ID,
                "team_name": "pulled-team",
                "min_available_seq": "0",
                "current_seq": str(len(PULL_MESSAGES) + len(PUSHED_MESSAGES)),
                "policy_revision": "0",
                "accepted_envelope_versions": [1],
                "write_allowed_ciphers": CONNECT_CIPHERS,
                "policy_history": [{
                    "policy_revision": "0", "effective_from_seq": "1",
                    "accepted_envelope_versions": [1],
                    "write_allowed_ciphers": ["none", "age-v1"],
                }],
                "members_revision": 0,
                "members": PULL_MEMBERS,
            })
            return
        if route == "/v1/teams/%s/messages" % PULL_TEAM_ID:
            after = 0
            for pair in query.split("&"):
                if pair.startswith("after="):
                    try:
                        after = int(pair[len("after="):])
                    except ValueError:
                        after = 0
            page = [m for m in PULL_MESSAGES if int(m["server_seq"]) > after]
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_id": PULL_TEAM_ID,
                "team_name": "pulled-team",
                "min_available_seq": "0",
                "messages": page,
                "next_after": page[-1]["server_seq"] if page else str(after),
                "has_more": False,
            })
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""

        if self.path == "/v1/messages":
            try:
                messages = json.loads(raw).get("messages", [])
            except Exception:
                self._send_json(400, {"error": "bad json"})
                return
            acks = []
            for message in messages:
                stored = {
                    "id": message.get("id"),
                    "server_seq": str(len(PULL_MESSAGES) + len(PUSHED_MESSAGES) + 1),
                    "server_received_at": "2026-01-03T00:00:00.000000Z",
                    "envelope": message.get("envelope"),
                }
                PUSHED_MESSAGES.append(stored)
                acks.append({
                    "id": message.get("id"),
                    "server_seq": stored["server_seq"],
                    "disposition": "stored",
                })
            self._send_json(200, {"acks": acks})
            return

        if self.path == "/v1/read-state/sync":
            current = str(len(PULL_MESSAGES) + len(PUSHED_MESSAGES))
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_id": PULL_TEAM_ID,
                "min_available_seq": "0",
                "current_seq": current,
                "items": [
                    {"kind": "frontier", "member_id": member["member_id"],
                     "server_seq": "0"}
                    for member in PULL_MEMBERS
                ],
                "next_page_after": None,
                "has_more": False,
            })
            return

        if self.path == "/v1/connect":
            try:
                data = json.loads(raw) if raw else {}
            except Exception:
                self._send_json(400, {"error": {"code": "invalid-request"}})
                return
            team_id = data.get("team_id", "")
            if team_id in REGISTERED_TEAM_IDS:
                self._send_json(409, {"protocol_version": 1,
                                      "error": {"code": "team-already-exists"}})
                return
            REGISTERED_TEAM_IDS.add(team_id)
            # The capability snapshot the client reads back into its binding.
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
                "team_name": data.get("team_name", ""),
                "min_available_seq": "0",
                "current_seq": "0",
                "next_sequence_boundary": "1",
                "accepted_envelope_versions": [1],
                "write_allowed_ciphers": CONNECT_CIPHERS,
                "policy_revision": "0",
                "effective_from_seq": "1",
                "max_blob_bytes": "1048576",
                "policy_history": [{"policy_revision": "0",
                                    "effective_from_seq": "1",
                                    "accepted_envelope_versions": [1],
                                    "write_allowed_ciphers": CONNECT_CIPHERS}],
            })
            return

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
            if token == "large-body-token":
                self._send_raw(200, "x" * (2 * 1024 * 1024 + 1))
                return
            if token == "large-header-token":
                self._send_json(200, {"unexpected": "body"}, oversized_header=True)
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
                    "credential_id": "018f3f7e-7777-7000-8000-000000000007",
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "remote_team_name": "myteam",
                    "protocol_version": 1,
                    "capabilities": {"write_allowed_ciphers": ["none"]},
                })
                return

            ciphers = ["age-v1"] if token == "good-token-enc" else ["none"]
            digest = hashlib.sha256(token.encode()).hexdigest()
            credential_id = (
                f"018f3f7e-{digest[:4]}-7{digest[4:7]}-8{digest[7:10]}-{digest[10:22]}"
            )
            ISSUED_CREDENTIAL_IDS.add(credential_id)
            capabilities = {
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
            }
            if token == "max-blob-zero-token":
                capabilities["max_blob_bytes"] = "0"
            elif token == "max-blob-over-token":
                capabilities["max_blob_bytes"] = "1048577"
            elif token == "future-policy-boundary-token":
                capabilities["policy_revision"] = "1"
                capabilities["effective_from_seq"] = "2"
                capabilities["policy_history"].append({
                    "policy_revision": "1",
                    "effective_from_seq": "2",
                    "accepted_envelope_versions": [1],
                    "write_allowed_ciphers": ciphers,
                })
            response = {
                "credential": "session-credential-" + token,
                "credential_id": credential_id,
                "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                "remote_team_id": "018f3f7e-2222-7000-8000-000000000002",
                "remote_team_name": "myteam",
                "protocol_version": 1,
                "capabilities": capabilities,
            }
            if token == "missing-protocol-header-token":
                self._send_json(200, response, protocol=None)
            elif token == "wrong-protocol-header-token":
                self._send_json(200, response, protocol="2")
            else:
                self._send_json(200, response)
            return

        if self.path.startswith("/v1/credentials/") and self.path.endswith("/revoke"):
            if REVOKE_FAIL:
                self._send_json(500, {"error": "simulated failure"})
                return
            cred_id = self.path.split("/")[3]
            if cred_id in ISSUED_CREDENTIAL_IDS:
                REVOKED_CREDENTIAL_IDS.append(cred_id)
                response = {
                    "protocol_version": 1,
                    "server_instance_id": "018f3f7e-1111-7000-8000-000000000001",
                    "team_id": "018f3f7e-2222-7000-8000-000000000002",
                    "credential_id": cred_id,
                    "revoked": True,
                    "revoked_at": "2026-01-01T00:00:00.000000Z",
                }
                if REVOKE_BAD_BODY:
                    response["team_id"] = "018f3f7e-9999-7000-8000-000000000009"
                if REVOKE_LARGE_BODY:
                    response["padding"] = "x" * 70_000
                self._send_json(200, response, protocol=None if REVOKE_BAD_HEADER else "1")
            else:
                self._send_json(404, {"error": "unknown credential_id"})
            return

        self._send_json(404, {"error": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = LoopbackHTTPServer(("127.0.0.1", port), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
