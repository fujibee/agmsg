#!/usr/bin/env bats

# Unit tests for the role->session record (#339 PR-A):
#   - scripts/lib/role-session.sh primitives (record / read / lookup)
#   - actas-claim.sh writes a record on successful claim, none on held
# The record is advisory runtime state keyed on the BARE session id (stable
# across resume generations), sharing the actas-lock filename encoding + run/ dir.

load test_helper

setup() {
  setup_test_env
  # Pin bare instance-id keying (#93) so actas-claim records the raw session_id
  # these tests pass, deterministic whether the suite runs under an agent
  # process (composite) or in CI (bare).
  export AGMSG_AGENT_PID=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
}

teardown() { teardown_test_env; }

# Register a (team, agent) pair for the test project under claude-code.
fake_register() {
  local team="$1" agent="$2" proj="${3:-/tmp/p1}"
  bash "$SKILL_DIR/scripts/join.sh" "$team" "$agent" claude-code "$proj"
}

# Fake that this test process owns a session_id (its own pid → live).
fake_session() {
  local sid="$1"
  echo "$sid" > "$RUN_DIR/cc-instance.$$"
}

# --- path encoding (shares the actas-lock sanitizer) ---

@test "record path: sits in run/ with role-session. prefix and __ separator" {
  local p
  p=$(_agmsg_role_session_path "T" "alice")
  [[ "$p" == "$RUN_DIR/role-session.T__alice" ]]
}

@test "record path: percent-encodes special bytes like the actas lock" {
  local p
  p=$(_agmsg_role_session_path "team/foo" "ag ent")
  [[ "$p" == "$RUN_DIR/role-session.team%2Ffoo__ag%20ent" ]]
}

@test "record path: encodes non-ASCII (UTF-8) team names" {
  local p
  p=$(_agmsg_role_session_path "チーム" alice)
  [[ "$p" == *"%E3%83%81%E3%83%BC%E3%83%A0"* ]]
}

# --- write / read roundtrip ---

@test "record then uuid: roundtrips the bare session id" {
  agmsg_role_session_record T alice "sid-abc" /tmp/p1
  [ "$(agmsg_role_session_uuid T alice)" = "sid-abc" ]
}

@test "record: stores session/name/team/agent/type/project/updated_at fields" {
  agmsg_role_session_record T alice "sid-abc" /tmp/proj claude-code
  local f; f=$(_agmsg_role_session_path T alice)
  grep -q "^session=sid-abc$"    "$f"
  grep -q "^name=T-alice$"       "$f"
  grep -q "^team=T$"             "$f"
  grep -q "^agent=alice$"        "$f"
  grep -q "^type=claude-code$"   "$f"
  grep -q "^project=/tmp/proj$"  "$f"
  grep -q "^updated_at="         "$f"
}

@test "record: type is empty when omitted (back-compat 4-arg call)" {
  agmsg_role_session_record T alice "sid-abc" /tmp/proj
  local f; f=$(_agmsg_role_session_path T alice)
  grep -q "^type=$" "$f"
}

@test "get: reads back an arbitrary field (type)" {
  agmsg_role_session_record T alice "sid-abc" /tmp/proj claude-code
  [ "$(agmsg_role_session_get T alice type)" = "claude-code" ]
  [ "$(agmsg_role_session_get T alice team)" = "T" ]
}

@test "record: name= joins team and agent whole (halves may contain '-')" {
  agmsg_role_session_record "team-x" "ag-1" "sid-1" /tmp/p
  local f; f=$(_agmsg_role_session_path "team-x" "ag-1")
  grep -q "^name=team-x-ag-1$" "$f"
}

@test "record: latest write wins (overwrites prior record)" {
  agmsg_role_session_record T alice "sid-old" /tmp/p1
  agmsg_role_session_record T alice "sid-new" /tmp/p1
  [ "$(agmsg_role_session_uuid T alice)" = "sid-new" ]
}

@test "record: unicode team name roundtrips" {
  agmsg_role_session_record "チーム" alice "sid-jp" /tmp/p1
  [ "$(agmsg_role_session_uuid "チーム" alice)" = "sid-jp" ]
}

@test "uuid: empty when no record exists" {
  [ -z "$(agmsg_role_session_uuid T nobody)" ]
}

# --- best-effort / fail-open ---

@test "record: empty sid is a no-op (writes nothing)" {
  agmsg_role_session_record T alice "" /tmp/p1
  [ ! -f "$(_agmsg_role_session_path T alice)" ]
}

@test "record: always returns 0 even when the run dir cannot be created" {
  # Point SKILL_DIR at a path whose 'run' parent is a FILE, so mkdir -p fails.
  local blocker="$TEST_SKILL_DIR/blocker"
  : > "$blocker"                       # a regular file where a dir is needed
  SKILL_DIR="$blocker" run agmsg_role_session_record T alice "sid-x" /tmp/p1
  [ "$status" -eq 0 ]
}

# --- lookups (for PR-D / PR-E) ---

@test "lookup_by_name: returns the record whose name= matches" {
  agmsg_role_session_record T alice "sid-a" /tmp/p1
  agmsg_role_session_record T bob   "sid-b" /tmp/p1
  local out; out=$(agmsg_role_session_lookup_by_name "T-bob")
  echo "$out" | grep -q "^session=sid-b$"
  echo "$out" | grep -q "^agent=bob$"
}

@test "lookup_by_name: empty when no record matches" {
  agmsg_role_session_record T alice "sid-a" /tmp/p1
  [ -z "$(agmsg_role_session_lookup_by_name "T-nobody")" ]
}

@test "lookup_by_sid: returns the record whose session= matches" {
  agmsg_role_session_record T alice "sid-a" /tmp/p1
  agmsg_role_session_record T bob   "sid-b" /tmp/p1
  local out; out=$(agmsg_role_session_lookup_by_sid "sid-b")
  echo "$out" | grep -q "^name=T-bob$"
  echo "$out" | grep -q "^team=T$"
  echo "$out" | grep -q "^agent=bob$"
}

@test "lookup_by_sid: empty when no record matches" {
  agmsg_role_session_record T alice "sid-a" /tmp/p1
  [ -z "$(agmsg_role_session_lookup_by_sid "sid-none")" ]
}

# --- actas-claim.sh integration ---

@test "actas-claim: writes a role-session record on successful claim" {
  fake_register T alice
  fake_session "sid-me"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=ok" ]]
  [ "$(agmsg_role_session_uuid T alice)" = "sid-me" ]
  # The claim knows the type, so the record captures it (for the resurrect hook).
  [ "$(agmsg_role_session_get T alice type)" = "claude-code" ]
}

@test "actas-claim: records the BARE sid when handed a composite instance id" {
  fake_register T alice
  # A live composite owner: cc-instance for our pid holds the composite token.
  echo "sid-me.$$" > "$RUN_DIR/cc-instance.$$"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me.$$"
  [ "$status" -eq 0 ]
  # The record must strip the .<pid> — the bare sid is what survives resume.
  [ "$(agmsg_role_session_uuid T alice)" = "sid-me" ]
}

@test "actas-claim: held claim does NOT write a record for the thief" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_register T alice
  fake_session "sid-owner"                       # this process is the live owner
  echo "sid-owner" > "$(actas_lock_path T alice)"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-thief"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "status=held" ]]
  # No record was written (the thief never held the role).
  [ ! -f "$(_agmsg_role_session_path T alice)" ]
}

@test "actas-claim: record survives release + re-claim with the same sid" {
  fake_register T alice
  fake_session "sid-me"

  bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me" >/dev/null
  [ "$(agmsg_role_session_uuid T alice)" = "sid-me" ]

  # Release the lock, then re-claim as the same session (resume keeps the sid).
  actas_lock_release T alice "sid-me"
  bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me" >/dev/null
  [ "$(agmsg_role_session_uuid T alice)" = "sid-me" ]
}
