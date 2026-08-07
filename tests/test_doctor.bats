#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export PROJ="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
  rm -rf "$PROJ"
}

@test "doctor: exits 0 and reports no warnings when nothing is registered as locked" {
  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"no warnings."* ]]
  [[ "$output" == *"team/alice"* ]]
  [[ "$output" == *"lock=none"* ]]
}

@test "doctor: exits non-zero and names a stale lock (composite owner, dead pid, no cc-instance)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale lock: team/alice"* ]]
  [[ "$output" == *"cc-instance=absent"* ]]
}

@test "doctor: a live lock with a confirming cc-instance record and a running watcher is not a warning" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  # watch.sh's pidfile is keyed on the same token actas-claim.sh records as
  # the lock owner -- see doctor.sh's comment on TYPE_HAS_ROLE_RUNTIME.
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/watch.$owner.pid"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  # Plain output shows the owner token in FULL -- shortening only applies
  # under --redacted (see doctor.sh's comment on _redact_owner: #605 was
  # resolved by matching this exact value against a bridge log line).
  [[ "$output" == *"lock=owner(alive)=$owner cc-instance=present watcher=running"* ]]
  [[ "$output" == *"no warnings."* ]]
}

@test "doctor: an alive lock with no watcher pidfile is a warning (claims exclusivity, not receiving)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  # No watch.<owner>.pid: the lock is legitimately live, but nothing is
  # watching for it -- exclusivity claimed, nothing receiving. #605's report
  # was exactly this shape.

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"lock=owner(alive)=$owner cc-instance=present watcher=none"* ]]
  [[ "$output" == *"actas lock held but no watcher: team/alice"* ]]
}

@test "doctor: a stale lock with no watcher does not double-warn about the missing watcher" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale lock: team/alice"* ]]
  [[ "$output" != *"actas lock held but no watcher"* ]]
}

@test "doctor: codex's per-role bridge line already covers this, so no separate watcher= field is added" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "livetoken.$$" > "$TEST_SKILL_DIR/run/actas.team__bob.session"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" codex
  [[ "$output" != *"watcher="* ]]
}

@test "doctor: --redacted hides the project path, team/agent names, and most of the owner token" {
  local home_proj="$HOME/redact-me"
  mkdir -p "$home_proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$home_proj" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" "$home_proj" claude-code --redacted
  [ "$status" -ne 0 ]
  [[ "$output" == *"project: ~/redact-me"* ]]
  [[ "$output" != *"team/alice"* ]]
  [[ "$output" == *"team1/agent1"* ]]
  [[ "$output" == *"...999999"* ]]
  [[ "$output" != *"deadtoken.999999"* ]]
}

@test "doctor: owner is shown in full by default, and --redacted splits a composite token on its last dot (not a fixed tail length)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  # A short pid, deliberately not 6 digits: a fixed-tail-length shortener
  # would cut into the sid (e.g. "...02.42"); splitting on the last "."
  # always lands exactly on the pid, whatever its length.
  local owner="459d8198-3fcf-4c9e-a4ff-5f8fbd18c802.42"

  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [[ "$output" == *"lock=owner(STALE)=$owner"* ]]

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code --redacted
  [[ "$output" == *"lock=owner(STALE)=...42 "* ]]
  [[ "$output" != *"$owner"* ]]
}

@test "doctor: warns when more than one registration exists under turn-mode delivery" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"registrations for this (project, type) under turn-mode delivery"* ]]
}

@test "doctor: multiple registrations under monitor mode is not a warning" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *"under turn-mode delivery"* ]]
}

# --- the delivery-status block is QUOTED from delivery.sh, not formatted by
#     doctor.sh itself -- --redacted has to run it through the same
#     substitutions or its only promise ("safe to paste") is broken. codex's
#     per-role bridge line is real-world proof: it names team/agent directly. -
@test "doctor: --redacted also redacts the embedded delivery-status block, not just its own formatting" {
  local home_proj="$HOME/embedded-leak-check"
  mkdir -p "$home_proj"
  bash "$SCRIPTS/join.sh" agmsg advisor codex "$home_proj" >/dev/null
  # A live codex bridge for agmsg/advisor, minimal enough for
  # _delivery.sh's agmsg_delivery_runtime_status to report it "alive": a
  # pidfile naming a real (this test's own) pid, and a matching metafile.
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.agmsg.advisor.pid"
  {
    echo "pid=$$"
    echo "project=$home_proj"
    echo "type=codex"
  } > "$TEST_SKILL_DIR/run/codex-bridge.agmsg.advisor.meta"

  run bash "$SCRIPTS/doctor.sh" "$home_proj" codex --redacted
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team1/agent1 alive"* ]]
  [[ "$output" != *"agmsg/advisor"* ]]
  [[ "$output" != *"$HOME"* ]]
}
