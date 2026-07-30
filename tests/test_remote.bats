#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Some cases deliberately remove python3 from PATH to verify the control-plane
  # gate. Resolve the fixture interpreter in each test process before that
  # system under test changes its environment.
  MOCK_PYTHON3="$(command -v python3)"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  # Start the mock pairing-exchange/revoke server on an OS-assigned port.
  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" \
  MOCK_REVOKE_BAD_HEADER="${MOCK_REVOKE_BAD_HEADER:-}" \
  MOCK_REVOKE_BAD_BODY="${MOCK_REVOKE_BAD_BODY:-}" \
  MOCK_REVOKE_LARGE_BODY="${MOCK_REVOKE_LARGE_BODY:-}" \
  MOCK_PULL_MIXED="${MOCK_PULL_MIXED:-}" \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
}

teardown() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  teardown_test_env
}

restart_mock_server() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  wait "$MOCK_SERVER_PID" 2>/dev/null || true
  : > "$TEST_SKILL_DIR/server.port"
  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" \
  MOCK_REVOKE_BAD_HEADER="${MOCK_REVOKE_BAD_HEADER:-}" \
  MOCK_REVOKE_BAD_BODY="${MOCK_REVOKE_BAD_BODY:-}" \
  MOCK_REVOKE_LARGE_BODY="${MOCK_REVOKE_LARGE_BODY:-}" \
  MOCK_PULL_MIXED="${MOCK_PULL_MIXED:-}" \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
      </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
}

# --- doctor ------------------------------------------------------------

@test "remote doctor: passes when age is installed" {
  command -v age >/dev/null 2>&1 || skip "age not installed"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"age / age-keygen on PATH"* ]]
  [[ "$output" == *"All checks passed."* ]]
}

@test "remote doctor: is read-only (no token required, no state touched)" {
  run bash "$SCRIPTS/remote.sh" doctor testteam
  run grep -c "remote_binding" "$SCRIPTS/../teams/testteam/config.json"
  [ "$output" -eq 0 ]
}

# --- connect: endpoint/response validation (B6) --------------------------

@test "connect: refuses a non-HTTPS, non-loopback endpoint" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://example.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses an endpoint with no scheme at all" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "example.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must start with https://"* ]]
}

@test "connect: http://127.0.0.1 (loopback) is accepted without https" {
  # Loopback passes endpoint validation, then connect proceeds to register a
  # real local team. testteam was minted with a team_id in setup().
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
}

@test "connect: requires the response protocol header" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" missing-protocol-header-token myteam
  [ "$status" -ne 0 ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" wrong-protocol-header-token myteam
  [ "$status" -ne 0 ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
}

@test "connect: rejects capability limits that differ from the engine validator" {
  for token in max-blob-zero-token max-blob-over-token future-policy-boundary-token; do
    run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
    [ "$status" -ne 0 ]
    [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
  done
}

@test "connect: bounds response body and header capture before validation" {
  for token in large-body-token large-header-token; do
    run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
    [ "$status" -ne 0 ]
    [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
  done
}

@test "connect: refuses subdomain-suffix bypass of the loopback exception (127.0.0.1.evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://127.0.0.1.evil.invalid:${MOCK_PORT}" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses subdomain-suffix bypass of the loopback exception (localhost.evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://localhost.evil.invalid:${MOCK_PORT}" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses the userinfo bypass of the loopback exception (localhost@evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://localhost@evil.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"userinfo"* ]]
}

# --- connect -------------------------------------------------------------

@test "connect: registers a client-owned team (happy path, Done-when 1)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connected: team 'testteam'"* ]]
  # A binding is recorded on the team config, and it carries no credential:
  # the register model writes none and none is fetched back.
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$SCRIPTS/../teams/testteam/config.json') AS TEXT), '\$.remote_binding.connected_at');")" != "" ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/testteam.json" ]
}

@test "connect: moves the team into its own per-team store (Done-when 2)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # A connected team's rows are migrated out of the shared store into a
  # per-team one; connect exits non-zero if that migration fails.
  run find "$TEST_SKILL_DIR" -path '*teams/testteam/messages.db'
  [ -n "$output" ]
}

@test "connect: starts a background sync engine that disconnect stops (Done-when 4)" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  local pidfile="$SCRIPTS/../run/remote-sync.testteam.pid"
  wait_for_file "$pidfile"
  bash "$SCRIPTS/remote.sh" disconnect testteam
  wait_for_missing "$pidfile"
}

@test "connect: mints team_id and member_ids for a team that predates local ids" {
  # A legacy team: agents but no team_id, members with no member_id. Give it an
  # initialized store so the connect-time migration has something to move.
  mkdir -p "$TEST_SKILL_DIR/teams/legacyteam"
  printf '{"name":"legacyteam","agents":{"alice":{"type":"claude-code"},"bob":{"type":"codex"}},"created_at":"2026-01-01T00:00:00Z"}\n' \
    > "$TEST_SKILL_DIR/teams/legacyteam/config.json"
  bash -c '. "$1/scripts/lib/storage.sh"; agmsg_storage_load; storage_init "$2" >/dev/null' \
    x "$SCRIPTS/.." legacyteam
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" legacyteam
  [ "$status" -eq 0 ]
  local cfg="$TEST_SKILL_DIR/teams/legacyteam/config.json"
  # The whole roster is now id-holding (all-or-none): a team_id and a member_id
  # for every member, minted at connect.
  [[ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.team_id');")" =~ ^[0-9a-f]{8}- ]]
  [ -n "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents.alice.member_id');")" ]
  [ -n "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents.bob.member_id');")" ]
}

@test "connect: refuses a second connect for the same team_id with 409 (Done-when 5)" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  # The mock keeps the registered team_id; a repeat is a uniqueness conflict.
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"already registered"* ]]
}

# --- status --------------------------------------------------------------

@test "status: reports 'never connected' for an unknown team" {
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"never been connected"* ]]
}

@test "status: with no <team> lists every locally-known connected team" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  bash "$SCRIPTS/join.sh" secondteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" secondteam >/dev/null
  run bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"testteam"* ]]
  [[ "$output" == *"secondteam"* ]]
}

# --- connect: pending/resume (B5) -----------------------------------------

# --- disconnect ------------------------------------------------------------

@test "disconnect: stops the engine and clears local state" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disconnected 'testteam'. Local sync state cleared"* ]]
  # The binding is marked disconnected locally (no server round-trip is needed
  # to disconnect in the register model). We do NOT assert on the "Revoking
  # credential..." line: it is old-path output that runs with no credential
  # present and is removed with the credential/E2EE cleanup.
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$SCRIPTS/../teams/testteam/config.json') AS TEXT), '\$.remote_binding.disconnected_at');")" != "" ]
}

@test "disconnect: fails for a team that isn't connected" {
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not connected"* ]]
}

# --- status --json (ADR 0007 addendum) --------------------------------------

@test "status --json: reports the strict schema for an active connection" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.local_team');")" = "testteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.endpoint');")" = "$ENDPOINT" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.state');")" = "active" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.server_instance_id');")" != "" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.remote_team_id');")" != "" ]
  # The register binding carries no credential; the field is still emitted for
  # a stable schema, but as null (removed with the credential/E2EE cleanup).
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.credential_id');")" = "" ]
}

@test "status --json: reports state=disconnected after disconnect" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  bash "$SCRIPTS/remote.sh" disconnect testteam
  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.state');")" = "disconnected" ]
}

@test "status --json: errors for a team that has never been connected" {
  run bash "$SCRIPTS/remote.sh" status ghostteam --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"has never been connected"* ]]
}

@test "status --json: with no <team>, empty output when nothing is connected" {
  run bash "$SCRIPTS/remote.sh" status --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "status --json: with no <team>, emits one JSONL line per connected team" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  bash "$SCRIPTS/join.sh" otherteam bob claude-code /tmp/project-b
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" otherteam
  run bash "$SCRIPTS/remote.sh" status --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  local testteam_line otherteam_line
  testteam_line="$(echo "$output" | grep testteam | grep -v otherteam)"
  otherteam_line="$(echo "$output" | grep otherteam)"
  [ -n "$testteam_line" ]
  [ -n "$otherteam_line" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$testteam_line" | sed "s/'/''/g")', '\$.local_team');")" = "testteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$otherteam_line" | sed "s/'/''/g")', '\$.local_team');")" = "otherteam" ]
}

@test "status: a team name containing a single quote doesn't break status or status --json (#87-class / .param set fix)" {
  local team="o'brien-team"
  bash "$SCRIPTS/join.sh" "$team" carol claude-code /tmp/project-c
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$team"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  run bash "$SCRIPTS/remote.sh" status "$team"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  [[ "$output" == *"connected"* ]]
  run bash "$SCRIPTS/remote.sh" status "$team" --json
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.local_team');")" = "$team" ]
}

# --- pending list / abort (ADR 0007 addendum) -------------------------------

_valid_pending_response_json() {
  # A fully-valid exchange response body, matching the shape
  # test_remote.bats's own "resumes from a hand-crafted pending record"
  # test already establishes as this branch's strict-validator baseline.
  local credential_id="$1" server_instance_id="$2" remote_team_id="$3" remote_team_name="$4"
  python3 -c "
import json
response = {
    'credential': 'orphan-test-credential-value',
    'credential_id': '$credential_id',
    'server_instance_id': '$server_instance_id',
    'remote_team_id': '$remote_team_id',
    'remote_team_name': '$remote_team_name',
    'protocol_version': 1,
    'capabilities': {
        'protocol_version': 1,
        'server_instance_id': '$server_instance_id',
        'team_id': '$remote_team_id',
        'team_name': '$remote_team_name',
        'accepted_envelope_versions': [1],
        'write_allowed_ciphers': ['none'],
        'policy_revision': '0', 'effective_from_seq': '1',
        'current_seq': '0', 'next_sequence_boundary': '1',
        'min_available_seq': '0', 'max_blob_bytes': '1048576',
        'policy_history': [{
            'policy_revision': '0', 'effective_from_seq': '1',
            'accepted_envelope_versions': [1],
            'write_allowed_ciphers': ['none'],
        }],
    },
}
print(json.dumps(response))
"
}

_write_pending_record() {
  local key="$1" endpoint="$2" raw_response_text="$3" pending_dir="$4"
  mkdir -p "$pending_dir"
  python3 -c "
import json, sys
raw = sys.stdin.read()
json.dump({'endpoint': '$endpoint', 'protocol_header_verified': True, 'raw_response_text': raw},
          open('$pending_dir/$key.json', 'w'))
" <<< "$raw_response_text"
}

@test "pending list: reports nothing when there are no pending records" {
  run bash "$SCRIPTS/remote.sh" pending list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pending connect records"* ]]
  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pending list --json: reports a valid orphaned record with its metadata, no credential" {
  local token="orphan-test-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  local resp
  resp=$(_valid_pending_response_json \
    "018f3f7e-6666-7000-8000-000000000006" \
    "018f3f7e-3333-7000-8000-000000000003" \
    "018f3f7e-4444-7000-8000-000000000004" \
    "orphanteam")
  _write_pending_record "$key" "$ENDPOINT" "$resp" "$pending_dir"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  local escaped; escaped="$(echo "$output" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.pending_id');")" = "$key" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.endpoint');")" = "$ENDPOINT" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.credential_id');")" = "018f3f7e-6666-7000-8000-000000000006" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.valid');")" = "1" ]
  # The raw credential must never appear anywhere in the listing output.
  [[ "$output" != *"orphan-test-credential-value"* ]]
}

@test "pending list --json: reports valid:false and null metadata for a record whose content fails validation" {
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  local key; key="$(printf 'a%.0s' $(seq 1 64))"
  _write_pending_record "$key" "$ENDPOINT" '{not valid json' "$pending_dir"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  local escaped; escaped="$(echo "$output" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.pending_id');")" = "$key" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.endpoint');")" = "$ENDPOINT" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.valid');")" = "0" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.credential_id');")" = "" ]
}

@test "pending list --json: still reports pending_id even when the envelope itself is corrupt" {
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  mkdir -p "$pending_dir"
  local key; key="$(printf 'b%.0s' $(seq 1 64))"
  printf 'not even json' > "$pending_dir/$key.json"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  local escaped; escaped="$(echo "$output" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.pending_id');")" = "$key" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.endpoint');")" = "" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.valid');")" = "0" ]
}

@test "pending list --json: does not enumerate a quarantined record (only normal <id>.json files)" {
  local token="quarantine-visibility-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  # Legacy 2-key envelope (no protocol_header_verified) — triggers
  # cmd_connect's own quarantine path on resume, exercised here directly by
  # hand-crafting the pre-quarantine legacy file and quarantining it the
  # same way cmd_connect would.
  mkdir -p "$pending_dir"
  python3 -c "
import json
json.dump({'endpoint': '$ENDPOINT', 'raw_response_text': '{}'}, open('$pending_dir/$key.json', 'w'))
"
  mv "$pending_dir/$key.json" "$pending_dir/$key.json.unverified.20260101T000000Z.1"

  run bash "$SCRIPTS/remote.sh" pending list --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$SCRIPTS/remote.sh" pending list
  [[ "$output" == *"No pending connect records"* ]]
}

@test "pending abort: rejects a malformed pending_id" {
  run bash "$SCRIPTS/remote.sh" pending abort "not-a-valid-id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid pending_id"* ]]
  run bash "$SCRIPTS/remote.sh" pending abort "../../escape"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid pending_id"* ]]
}

@test "pending abort: removes a valid pending record" {
  local token="abort-test-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"

  run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted pending connect record $key"* ]]
  [ ! -f "$pending_dir/$key.json" ]
}

@test "pending abort: fails clearly for an unknown pending_id" {
  local key; key="$(printf 'c%.0s' $(seq 1 64))"
  run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pending connect record"* ]]
}

@test "pending abort: aborting the same pending_id twice is not silently treated as success" {
  local token="double-abort-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"

  bash "$SCRIPTS/remote.sh" pending abort "$key"
  run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pending connect record"* ]]
}

# --- pending/connect lock barrier (co1 delta review) ------------------------
#
# Deterministic, single-threaded simulation of the race co1 flagged (see
# feat/remote-connect-onboarding's PR #479): rather than actually racing two
# live processes, pre-insert a row in the runtime `locks` table matching
# exactly what `_remote_pending_lock_acquire` would have written, then
# assert the OTHER operation either blocks (live owner) or reclaims (dead
# owner) as appropriate. AGMSG_PENDING_LOCK_TRIES keeps the timeout fast.

_insert_pending_lock_row() {
  local key="$1" owner_pid="$2" db="$SCRIPTS/../db/messages.db"
  sqlite3 "$db" "
CREATE TABLE IF NOT EXISTS locks (
  resource TEXT PRIMARY KEY,
  owner_pid INTEGER NOT NULL,
  acquired_at TEXT NOT NULL
);
INSERT OR REPLACE INTO locks(resource, owner_pid, acquired_at)
VALUES ('remote-pending.$key', $owner_pid, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
"
}

@test "pending abort: blocks (not deletes) when a concurrent connect resume already holds this pending_id's lock (barrier test)" {
  local token="lock-barrier-abort-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"
  _insert_pending_lock_row "$key" "$$"

  AGMSG_PENDING_LOCK_TRIES=3 run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out acquiring pending lock"* ]]
  [ -f "$pending_dir/$key.json" ]
}

@test "pending abort: reclaims a stale lock left by a dead owner instead of blocking forever (barrier test)" {
  local token="lock-barrier-stale-token"
  local key
  key=$(python3 -c "import hashlib; print(hashlib.sha256('$ENDPOINT'.encode()+b'\x00'+'$token'.encode()).hexdigest())")
  local pending_dir="$SCRIPTS/../run/remote-connect-pending"
  _write_pending_record "$key" "$ENDPOINT" '{}' "$pending_dir"

  ( : ) &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  _insert_pending_lock_row "$key" "$dead_pid"

  AGMSG_PENDING_LOCK_TRIES=20 run bash "$SCRIPTS/remote.sh" pending abort "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted pending connect record $key"* ]]
  [ ! -f "$pending_dir/$key.json" ]
}

@test "remote.sh: unknown pending subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/remote.sh" pending bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- dispatch --------------------------------------------------------------

@test "remote.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/remote.sh" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"pull"* ]]
}

# --- python3 preflight (dependency tiering: remote = +python3) -------------

@test "remote status: fails fast with an install message when python3 is absent, never hangs" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
  [[ "$output" == *"brew install python3"* ]]
}

@test "remote connect: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" connect testteam https://example.invalid tok
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}

@test "remote disconnect: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}

@test "remote pending: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" pending list
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}

@test "remote doctor: still runs without python3, and reports it as a failed check (not a crash)" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] python3 on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote doctor: reports python3 as present when it is available" {
  run bash "$SCRIPTS/remote.sh" doctor
  [[ "$output" == *"[x] python3 on PATH"* ]]
}

# --- co1 delta review P1: doctor must also check node (sync data plane) ----
# Node is a SEPARATE, independent dependency from python3 (remote sync data
# plane vs. remote control plane) -- doctor claiming "All checks passed"
# with age+python3 present but node missing would contradict reality, since
# remote-sync.sh cannot run without node.

@test "remote doctor: reports node as a failed check (not silently ignored) when unusable, and does not claim overall success" {
  run env AGMSG_NODE=/definitely/does/not/exist/node bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] node on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote doctor: reports node as present when it resolves to a usable binary" {
  run bash "$SCRIPTS/remote.sh" doctor
  [[ "$output" == *"[x] node on PATH"* ]]
}

@test "remote doctor: passes with the full toolchain installed" {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
    || skip "all doctor prerequisites are not installed"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed."* ]]
}

PULL_TEAM_ID=018f3f7e-2222-7000-8000-000000000002

@test "remote pull: clones a team, keeping the id the server gave" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  local cmd_name
  cmd_name="$(basename "$TEST_SKILL_DIR")"
  [[ "$output" == *"This team is now local and ready for normal use."* ]]
  [[ "$output" == *"Open your agent and invoke its installed '$cmd_name' command, then join with a new agent name."* ]]
  local cfg
  cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  [ -f "$cfg" ]
  # Not minted here: the id is the one the server answered with.
  [ "$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.team_id');")" = "$PULL_TEAM_ID" ]
}

@test "remote pull: starts a background sync engine that disconnect stops" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  # "Machine two ... pulls the team down, and continues" — continuing IS the
  # engine. A pulled team that only cloned would report a send as "Sent" and
  # stay local while status answered "connected"; pin the engine running and the
  # binding it continues against. This is what a green 56/0 slipped past.
  [[ "$output" == *"Sync engine running."* ]]
  local pidfile="$SCRIPTS/../run/remote-sync.cloned.pid"
  wait_for_file "$pidfile"
  local cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.remote_binding.endpoint');")" = "$ENDPOINT" ]
  bash "$SCRIPTS/remote.sh" disconnect cloned
  wait_for_missing "$pidfile"
}

@test "remote pull: does not take a roster from the server" {
  # The server holds no membership -- it travels inside the envelope, so under
  # e2ee the server cannot read it. A roster invented here would be a guess
  # presented as fact; it is derived by replaying the team journal instead.
  #
  # The mock deliberately still answers with a members array, so this fails if
  # the client starts trusting one again rather than merely because none was
  # offered.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  local cfg agents
  cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  agents="$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.agents');")"
  [ "$agents" = "{}" ]
}

@test "remote pull: refuses a team that already has history" {
  bash "$SCRIPTS/join.sh" occupied alice claude-code /tmp/project-b >/dev/null
  bash "$SCRIPTS/send.sh" occupied alice alice "already mine" >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" occupied
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has history"* ]]
}

@test "remote pull: requires an endpoint, a team id and a local name" {
  run bash "$SCRIPTS/remote.sh" pull --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID"
  [ "$status" -ne 0 ]
}

@test "remote pull: the cloned team can be read with the ordinary commands" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  # The point of the whole step: the history is here, not just the team.
  [[ "$output" == *"2 message(s)"* ]]
  run bash "$SCRIPTS/history.sh" cloned alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"history one"* ]]
  [[ "$output" == *"history two"* ]]
}

@test "remote pull: applies seven roster events alongside seventy-three messages" {
  MOCK_PULL_MIXED=1
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" mixed
  [ "$status" -eq 0 ]
  [[ "$output" == *"80 message(s)"* ]]

  local cfg journal
  cfg="$TEST_SKILL_DIR/teams/mixed/config.json"
  journal="$TEST_SKILL_DIR/teams/mixed/roster.jsonl"
  [ "$(sqlite_mem "SELECT COUNT(*) FROM json_each(
      json_extract(readfile('$(rf "$cfg")'), '\$.agents'));")" -eq 7 ]
  [ "$(jq -s '[.[] | select(.type=="member_joined")] | length' "$journal")" -eq 7 ]
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  [ "$(storage_history mixed | jq -s 'length')" -eq 73 ]
}

@test "remote doctor: age is optional — its absence does not fail the run" {
  # cipher "none" is the base and e2ee is available rather than required, so a
  # new user running doctor must not be told they are missing something they
  # were never obliged to have.
  local no_age; no_age="$(path_without_age)"
  run env PATH="$no_age" bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  [[ "$output" == *"optional"* ]]
  [[ "$output" != *"is required for end-to-end encryption"* ]]
}

@test "remote doctor: python3 stays required while age is optional" {
  # The three are not interchangeable: without python3 the remote control plane
  # does not run at all, so it keeps failing the check.
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] python3 on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote pull: a name is enough — no UUID is carried by hand" {
  # The team_id requirement existed to stand in for authentication, and this
  # server has none to stand in for. The second machine should never need a
  # UUID typed across from the first.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" pulled-team
  [ "$status" -eq 0 ]
  local cfg
  cfg="$TEST_SKILL_DIR/teams/pulled-team/config.json"
  [ -f "$cfg" ]
  # And the id still ends up recorded, resolved rather than typed.
  [ "$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.team_id');")" = "$PULL_TEAM_ID" ]
}

@test "remote pull: an unknown name fails without inventing a team" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" nosuchteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"no team named"* ]]
  [ ! -d "$TEST_SKILL_DIR/teams/nosuchteam" ]
}

@test "remote pull: two teams sharing a name list the candidates and stop" {
  # Not bad data — a question only the operator can answer. The listing has to
  # carry what tells them apart, and must not pull one of them on a guess.
  MOCK_DUPLICATE_NAME=pulled-team restart_mock_server
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" pulled-team
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 teams are named"* ]]
  [[ "$output" == *"$PULL_TEAM_ID"* ]]
  [[ "$output" == *"018f3f7e-2222-7000-8000-0000000000ff"* ]]
  # What distinguishes them, and only from outside the envelope.
  [[ "$output" == *"registered 2026-07-29"* ]]
  [[ "$output" == *"registered 2026-07-12"* ]]
  [[ "$output" == *"messages"* ]]
  [[ "$output" == *"--team-id"* ]]
  # Nothing was pulled on a guess.
  [ ! -d "$TEST_SKILL_DIR/teams/pulled-team" ]
}

@test "remote pull: --team-id still resolves a shared name" {
  MOCK_DUPLICATE_NAME=pulled-team restart_mock_server
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" pulled-team
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/pulled-team/config.json" ]
}

# A lookup answer decides this machine's team identity and gets printed for an
# operator to read, so each of these asserts three things: the command failed,
# no local team was built from the answer, and the poisoned value never reached
# the terminal. The message is pinned too -- a bare non-zero status would also
# be produced by the very fail-open this guards against.
assert_lookup_rejected() {
  local mode="$1"
  MOCK_LOOKUP_BAD="$mode" restart_mock_server
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" pulled-team
  [ "$status" -ne 0 ]
  [[ "$output" == *"its answer was rejected"* ]]
  [[ "$output" != *"MARKER-INJECTED"* ]]
  [ ! -d "$TEST_SKILL_DIR/teams/pulled-team" ]
}

@test "remote pull: a candidate failing field validation is refused, not shown" {
  # team_id/timestamp/sequence are the fields that would reach a terminal or a
  # config; name_mismatch is a server answering about a different team.
  assert_lookup_rejected team_id
  assert_lookup_rejected timestamp
  assert_lookup_rejected sequence
  assert_lookup_rejected name_mismatch
}

@test "remote pull: an otherwise valid candidate with an extra field is refused" {
  # The strongest of these cases: everything the client uses is well formed, so
  # without the key-set check the pull would succeed and the unasked-for field
  # would have travelled with it.
  assert_lookup_rejected extra_field
}

@test "remote pull: a poisoned second candidate is refused before listing" {
  # The duplicate-name path prints candidates, which is exactly where an
  # unvalidated value would be rendered.
  assert_lookup_rejected multiple
}

@test "remote pull: more candidates than the bound are refused, not listed" {
  # Forty candidates. Without the client-side bound this lists all of them.
  assert_lookup_rejected flood
}

@test "remote pull: a wrong protocol, server id, or root name is refused" {
  assert_lookup_rejected protocol
  assert_lookup_rejected server_id
  assert_lookup_rejected root_name
}
