#!/usr/bin/env python3
"""Minimal mock of the remote sync endpoints, for bats tests exercising
scripts/remote.sh without a real server. Not part of the shipped product --
test-only.

Covers /v1/connect, /v1/capabilities, /v1/members, /v1/messages and
/v1/read-state/sync. No credential is issued or checked anywhere: reaching the
server is the permission, the same as the real one (docs/design/remote-sync.md).
"""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import TCPServer

PULL_MIXED = os.environ.get("MOCK_PULL_MIXED") == "1"
PULL_AGE = os.environ.get("MOCK_PULL_AGE") == "1"
PULL_AGE_ENVELOPE_FILE = os.environ.get("MOCK_PULL_AGE_ENVELOPE_FILE", "")
CONNECT_CIPHERS = (["none"] if os.environ.get("MOCK_CONNECT_NO_AGE") == "1"
                   else ["none", "age-v1"])
# The name /v1/connect answers with. Empty means "echo back what was asked
# for", which is the real server's behaviour and what every other case wants.
CONNECT_TEAM_NAME = os.environ.get("MOCK_CONNECT_TEAM_NAME", "")

# Force /v1/connect to answer with a given HTTP status. Only a test that needs
# the client's non-200 branch sets this; everything else leaves it unset and
# gets the normal handler. Owning the status here is what makes such a test
# hermetic -- the alternative, pointing the client at a port nobody is listening
# on, depends on a port being free, which no test owns.
CONNECT_STATUS = os.environ.get("MOCK_CONNECT_STATUS", "")

# What the server DECLARES this team uses, as distinct from CONNECT_CIPHERS
# above, which is what it would accept. Empty means "no machine has declared
# it" and is sent as JSON null — the state a team connected by an older client
# is in, and the one `pull` must not read as "unencrypted".
TEAM_CIPHER_PROFILE = os.environ.get("MOCK_TEAM_CIPHER_PROFILE", "age-v1")


# POST /v1/connect registers a client-owned team once. No credential is issued
# or returned — reaching the server is the permission. A team_id already
# registered is refused 409 (a uniqueness conflict, like a non-fast-forward).
CONNECT_SERVER_ID = "018f3f7e-3333-7000-8000-000000000001"
# What /v1/health reports as the team. Empty means "echo the requested one",
# which is what a per-team edge does; a test sets it via /_test/health-team= to
# make the server disagree with the client's binding.
HEALTH_TEAM_ID = os.environ.get("MOCK_HEALTH_TEAM_ID", "")
REGISTERED_TEAM_IDS = set()
# team_id -> {"team_name": str, "members": [...]}, what /v1/connect was sent.
REGISTERED_TEAMS = {}
# Armed by GET /_test/drop-next-connect, consumed by the next /v1/connect:
# commit the registration, answer nothing. Armed through a route rather than an
# env var because the registration has to SURVIVE into the retry, and a restart
# to change the env would take it with it.
DROP_NEXT_CONNECT = False
# Armed by GET /_test/fail-next?route=<capabilities|members>: every request to
# that route answers 500 until the server is restarted. Lets a test drive the
# client's "could not read it" branches, which a fixture that always succeeds
# cannot reach.
#
# Sticky, not one-shot: a connected team has a sync engine polling in the
# background, and it would consume a single armed failure before the command
# under test ever issued its request. The test then saw a success it had asked
# to fail. Each test starts its own server, so nothing has to clear this.
FAIL_NEXT = set()


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
# A history of any size, one wire-shaped message per JSONL line, as
# tests/perf/gen-history.py writes it. It replaces the built-in fixtures so a
# harness can hand this server 17,300 messages without a 17,300-line module.
PULL_FILE = os.environ.get("MOCK_PULL_FILE", "")
if PULL_FILE:
    with open(PULL_FILE, encoding="utf-8") as handle:
        PULL_MESSAGES = [json.loads(line) for line in handle if line.strip()]
PUSHED_MESSAGES = []
# Per team, because the sequence space is per team (server/spec/v1.md: "team
# sequence", allocated inside the team row's lock). The flat list above stays
# for /_test/pushed and for the pulled-team view, which predate this.
PUSHED_BY_TEAM = {}
# id -> stored row, per team: the duplicate check on POST must not scan the
# team's whole history for every new message, or the fixture adds an N^2 of
# its own to the stage that times the POST (the real server looks ids up in
# the database, server/src/storage.ts).
PUSHED_INDEX = {}


def _log_for(team_id):
    """The messages this server holds for `team_id`, in sequence order.

    The pull fixture's team holds the served history plus what it pushed; a
    team registered through /v1/connect holds only what it pushed -- and its
    first push gets sequence 1, which is what its client's pull cursor expects.
    Before this, every team saw one shared log and a connected team's first
    pull failed contiguity (or capability coverage) against it.
    """
    own = PUSHED_BY_TEAM.get(team_id, [])
    if team_id == PULL_TEAM_ID:
        return PULL_MESSAGES + own
    return own


def _page(messages, query):
    """One page of `messages`, the way the reference server pages.

    Mirrors server/src/storage.ts getMessages (v1.2.2) so a client measured
    against this fixture sees the pages it would see in production:
      - `after` is required in the spec; an unparsable one reads as 0 here, as
        this fixture always did.
      - `limit` defaults to 100 and must be 1..1000 (server/src/protocol.ts
        messagesQuerySchema); outside that the real server answers 400, and so
        does this.
      - the query is `LIMIT limit + 1`: `has_more` is whether a row past the
        page existed, `next_after` is the last returned seq, or the supplied
        `after` when the page is empty (server/spec/v1.md, GET /v1/messages).
    Returns (status, body_fields).
    """
    after = 0
    limit = 100
    for pair in query.split("&"):
        if pair.startswith("after="):
            try:
                after = int(pair[len("after="):])
            except ValueError:
                after = 0
        elif pair.startswith("limit="):
            raw = pair[len("limit="):]
            if not raw.isdigit() or raw.startswith("0") or not 1 <= int(raw) <= 1000:
                return 400, {"error": {"code": "invalid-request"}}
            limit = int(raw)
    rows = [m for m in messages if int(m["server_seq"]) > after][:limit + 1]
    has_more = len(rows) > limit
    page = rows[:limit]
    return 200, {
        "messages": page,
        "next_after": page[-1]["server_seq"] if page else str(after),
        "has_more": has_more,
    }


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

    def _strip_capability_prefix(self):
        """Serve the API beneath a `/t/<token>` prefix, like a hosted endpoint.

        A hosted endpoint is `https://host/t/<token>` and the routes live under
        it. Without this the fixture can only be reached at the bare root, so a
        test cannot drive a real flow through a capability-bearing URL -- and
        the thing worth asserting about such a URL is that the token never
        reaches the terminal. The token is not checked: this server issues and
        verifies no credential, exactly like the real one.
        """
        if self.path.startswith("/t/"):
            rest = self.path[len("/t/"):]
            cut = rest.find("/")
            self.path = rest[cut:] if cut != -1 else "/"

    def do_GET(self):
        self._strip_capability_prefix()
        # Declared for the whole method: /_test/health-team assigns it, and
        # Python requires the declaration to precede the first mention anywhere
        # in the function — including the read in the /v1/health branch below.
        global HEALTH_TEAM_ID, CONNECT_SERVER_ID, DROP_NEXT_CONNECT, FAIL_NEXT
        if self.path == "/v1/health":
            # Echo the team the caller asked about, the way a real per-team edge
            # answers. MOCK_HEALTH_TEAM_ID overrides it so a test can make the
            # server disagree with the local binding.
            team_id = HEALTH_TEAM_ID or self.headers.get("Agmsg-Team-ID", "")
            self._send_json(200, {
                "status": "ok",
                "database": "ok",
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
            })
            return
        if self.path == "/_test/drop-next-connect":
            DROP_NEXT_CONNECT = True
            self._send_json(200, {"armed": True})
            return
        if self.path == "/_test/rotate-server-id":
            # Same address, different server. Registrations stay, so a client
            # can only tell by comparing the instance id it recorded.
            CONNECT_SERVER_ID = "018f3f7e-2222-7000-8000-0000000000ff"
            self._send_json(200, {"server_instance_id": CONNECT_SERVER_ID})
            return
        if self.path == "/v1/capabilities" and "capabilities" in FAIL_NEXT:
            self._send_json(500, {"error": {"code": "server-error"}})
            return
        if self.path == "/v1/capabilities":
            team_id = self.headers.get("Agmsg-Team-ID", "")
            current_seq = len(_log_for(team_id))
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
                # The real snapshot carries the name the server holds, and a
                # client rebuilding a lost binding compares against it.
                "team_name": REGISTERED_TEAMS.get(team_id, {}).get(
                    "team_name", CONNECT_TEAM_NAME or ""),
                # And the declaration it holds, which for a registered team is
                # what that team was registered with -- not the env default.
                "cipher_profile": (
                    REGISTERED_TEAMS[team_id]["cipher_profile"]
                    if team_id in REGISTERED_TEAMS
                    else (TEAM_CIPHER_PROFILE or None)),
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
        if self.path == "/_test/pushed":
            self._send_json(200, {"messages": PUSHED_MESSAGES})
            return
        # Change what /v1/health claims the team is, without restarting — a
        # restart moves the port, and a client that already recorded the old one
        # then fails to connect for a reason unrelated to what is under test.
        if self.path.startswith("/_test/health-team"):
            from urllib.parse import unquote
            _, _, override = self.path.partition("=")
            HEALTH_TEAM_ID = unquote(override)
            self._send_json(200, {"health_team_id": HEALTH_TEAM_ID})
            return
        parts = self.path.split("?", 1)
        route = parts[0]
        query = parts[1] if len(parts) > 1 else ""
        if route == "/_test/fail-next":
            for pair in query.split("&"):
                if pair.startswith("route="):
                    FAIL_NEXT.add(pair[len("route="):])
            self._send_json(200, {"armed": sorted(FAIL_NEXT)})
            return
        if route == "/_test/rename-team":
            # Make the server hold a different name for a registered team, so
            # the client's name-mismatch branch can be reached.
            from urllib.parse import unquote_plus as _uqp
            was, now = "", ""
            for pair in query.split("&"):
                if pair.startswith("from="):
                    was = _uqp(pair[len("from="):])
                elif pair.startswith("to="):
                    now = _uqp(pair[len("to="):])
            hit = [tid for tid, rec in REGISTERED_TEAMS.items()
                   if rec["team_name"] == was]
            if hit:
                REGISTERED_TEAMS[hit[0]]["team_name"] = now
                self._send_json(200, {"team_name": now})
            else:
                self._send_json(404, {"error": {"code": "not-registered"}})
            return
        if route == "/v1/members" and "members" in FAIL_NEXT:
            self._send_json(500, {"error": {"code": "server-error"}})
            return
        if route == "/_test/declare-cipher":
            # Set the declaration a registered team carries, without the client
            # having to be able to MAKE that declaration. Declaring age-v1 for
            # real needs a key and so the age binary; the client behaviour
            # under test is only "the server says X and this run asked for Y",
            # so the two are separable and the test stays runnable where age
            # is absent -- which is where CI runs it.
            # Addressed by NAME, so the caller does not have to dig the minted
            # team_id back out of local config -- which for a team whose name
            # contains a quote is its own quoting problem, in the test rather
            # than in the thing under test.
            # Imported here like the other branches that need it: the existing
            # local imports make `unquote` a local name for this whole method,
            # so a module-level one would not be visible.
            # unquote_PLUS: this arrives form-urlencoded, where a space may be
            # '+'. Plain unquote would leave it and the name would not match.
            from urllib.parse import unquote_plus
            want_name, want_profile = "", ""
            for pair in query.split("&"):
                if pair.startswith("team_name="):
                    want_name = unquote_plus(pair[len("team_name="):])
                elif pair.startswith("profile="):
                    want_profile = unquote_plus(pair[len("profile="):])
            hit = [tid for tid, rec in REGISTERED_TEAMS.items()
                   if rec["team_name"] == want_name]
            if hit:
                REGISTERED_TEAMS[hit[0]]["cipher_profile"] = want_profile
                self._send_json(200, {"team_id": hit[0],
                                      "cipher_profile": want_profile})
            else:
                self._send_json(404, {"error": {"code": "not-registered"}})
            return
        if route == "/v1/members":
            team_id = self.headers.get("Agmsg-Team-ID", "")
            if team_id in REGISTERED_TEAMS:
                self._send_json(200, {
                    "protocol_version": 1,
                    "server_instance_id": CONNECT_SERVER_ID,
                    "team_id": team_id,
                    "min_available_seq": "0",
                    "cipher_profile": TEAM_CIPHER_PROFILE or None,
                    "members_revision": "0",
                    # Canonical order, ascending member_id: the client refuses
                    # a roster that is not ("members response is not
                    # canonical"), and the order /v1/connect was sent is the
                    # local config's key order, which is not that.
                    "members": sorted(REGISTERED_TEAMS[team_id]["members"],
                                      key=lambda m: m["member_id"]),
                })
                return
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_id": PULL_TEAM_ID,
                "min_available_seq": "0",
                "cipher_profile": TEAM_CIPHER_PROFILE or None,
                "members_revision": "0",
                "members": PULL_MEMBERS,
            })
            return
        if route == "/v1/messages":
            # The team the caller is bound to, echoed back the way
            # /v1/capabilities does: a CONNECTED team carries its own id, and
            # the client checks every response against its binding. Answering
            # the pull fixture's id here failed every connected team's first
            # pull with "server/team binding mismatch".
            team_id = self.headers.get("Agmsg-Team-ID", "") or PULL_TEAM_ID
            status, page = _page(_log_for(team_id), query)
            if status != 200:
                self._send_json(status, page)
                return
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
                **page,
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
                if bad == "http_error":
                    # Not a 200 with a bad body -- a non-2xx answer whose
                    # error.code itself carries the marker. The negative
                    # control for whether resolve-team's HTTP-error path can
                    # be made to write untrusted server bytes to a terminal
                    # (#726/#728): the status/reason must still reach the
                    # operator, but the raw marker must not.
                    self._send_json(503, {"error": {"code": "server-error" + poison}})
                    return
                if bad == "malformed_json":
                    # Not a well-formed body with a bad field -- not JSON at
                    # all. Node's own JSON.parse SyntaxError can quote a
                    # fragment of the input in its message, which is a
                    # second, independent way an untrusted server's raw bytes
                    # could reach a terminal once resolve-team's stderr is no
                    # longer redirected away (#726/#728) -- distinct from the
                    # error.code path the other cases above exercise.
                    self._send_raw(200, "{not json " + poison)
                    return
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
                "cipher_profile": TEAM_CIPHER_PROFILE or None,
                "current_seq": str(len(_log_for(PULL_TEAM_ID))),
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
            status, page = _page(PULL_MESSAGES, query)
            if status != 200:
                self._send_json(status, page)
                return
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": PULL_SERVER_ID,
                "team_id": PULL_TEAM_ID,
                "team_name": "pulled-team",
                "min_available_seq": "0",
                "cipher_profile": TEAM_CIPHER_PROFILE or None,
                **page,
            })
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        self._strip_capability_prefix()
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""

        # Before routing, on purpose. A capability endpoint is
        # `https://host/t/<token>`, so every request path arrives with that
        # prefix and would miss a check placed inside a `self.path == "/v1/..."`
        # branch. Only a test that needs the client's non-200 branch sets this.
        if CONNECT_STATUS and self.path.endswith("/v1/connect"):
            self._send_json(int(CONNECT_STATUS), {"error": {"code": "forced-by-fixture"}})
            return

        if self.path == "/v1/messages":
            try:
                messages = json.loads(raw).get("messages", [])
            except Exception:
                self._send_json(400, {"error": "bad json"})
                return
            team_id = self.headers.get("Agmsg-Team-ID", "")
            own = PUSHED_BY_TEAM.setdefault(team_id, [])
            index = PUSHED_INDEX.setdefault(team_id, {})
            acks = []
            for message in messages:
                # An id this server already holds answers with its ORIGINAL
                # sequence as `duplicate` (server/spec/v1.md, POST
                # /v1/messages step 2); only a new id allocates. Without this a
                # retried batch would be stored twice and acked twice.
                known = index.get(message.get("id"))
                if known is not None:
                    acks.append({"id": known["id"], "server_seq": known["server_seq"],
                                 "disposition": "duplicate"})
                    continue
                stored = {
                    "id": message.get("id"),
                    "server_seq": str(len(_log_for(team_id)) + 1),
                    "server_received_at": "2026-01-03T00:00:00.000000Z",
                    "envelope": message.get("envelope"),
                }
                own.append(stored)
                index[stored["id"]] = stored
                PUSHED_MESSAGES.append(stored)
                acks.append({
                    "id": message.get("id"),
                    "server_seq": stored["server_seq"],
                    "disposition": "stored",
                })
            # The binding fields the client checks on EVERY response
            # (validateBinding in remote-sync.mjs): without them a push cycle
            # ends in "server/team binding mismatch" after the server has
            # already stored the batch. Same success shape as the spec's
            # example response for this route.
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
                "team_name": REGISTERED_TEAMS.get(team_id, {}).get(
                    "team_name", "pulled-team"),
                "min_available_seq": "0",
                "policy_revision": "0",
                "acks": acks,
            })
            return

        if self.path == "/v1/read-state/sync":
            # Per team, like the pull side: the binding the client checks is
            # the caller's own, and the frontier stream must name exactly that
            # team's members (readStateCycle fails on an omitted frontier), so
            # a registered team answers from what /v1/connect was sent.
            team_id = self.headers.get("Agmsg-Team-ID", "") or PULL_TEAM_ID
            members = sorted(REGISTERED_TEAMS[team_id]["members"]
                             if team_id in REGISTERED_TEAMS else PULL_MEMBERS,
                             key=lambda m: m["member_id"])
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
                "min_available_seq": "0",
                "cipher_profile": TEAM_CIPHER_PROFILE or None,
                "current_seq": str(len(_log_for(team_id))),
                "items": [
                    {"kind": "frontier", "member_id": member["member_id"],
                     "server_seq": "0"}
                    for member in members
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
            # What the server now holds for this team. The real one stores the
            # name and roster it was sent and answers /v1/capabilities and
            # /v1/members from that; reading them back is how a client that
            # lost this response rebuilds its binding, so the mock has to hold
            # them too or that path cannot be tested honestly.
            REGISTERED_TEAMS[team_id] = {
                "team_name": CONNECT_TEAM_NAME or data.get("team_name", ""),
                # The DECLARATION, kept as sent. A repeat connect must not be
                # able to restate it, so reads answer from here, not from
                # whatever the later caller asked for.
                "cipher_profile": data.get("cipher_profile"),
                "members": [{"member_id": m.get("member_id", ""),
                             "name": m.get("name", ""),
                             "registrations": []}
                            for m in data.get("members", [])],
            }
            global DROP_NEXT_CONNECT
            if DROP_NEXT_CONNECT:
                # The registration is committed and the client is told nothing.
                # This is the POST that succeeded on the server and whose
                # response never arrived -- the one case where a retry finds a
                # team it owns and holds no binding for it.
                DROP_NEXT_CONNECT = False
                self.close_connection = True
                try:
                    self.connection.close()
                except Exception:
                    pass
                return
            # The capability snapshot the client reads back into its binding.
            self._send_json(200, {
                "protocol_version": 1,
                "server_instance_id": CONNECT_SERVER_ID,
                "team_id": team_id,
                # Normally the server answers with the name it was given, which
                # is why local and remote names are the same in every other
                # case here. MOCK_CONNECT_TEAM_NAME makes them differ, so a
                # test can see which of the two a message is quoting.
                "team_name": CONNECT_TEAM_NAME or data.get("team_name", ""),
                "min_available_seq": "0",
                "cipher_profile": TEAM_CIPHER_PROFILE or None,
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

        self._send_json(404, {"error": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = LoopbackHTTPServer(("127.0.0.1", port), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
