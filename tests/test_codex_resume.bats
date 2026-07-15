#!/usr/bin/env bats

# Unit tests for codex session resume wiring (#339):
#   scripts/drivers/types/codex/_transcript-exists.sh
#   scripts/drivers/types/codex/codex-record-session.sh
# Codex resumes via `codex resume <SESSION_ID>` (subcommand) and, unlike
# claude-code, records its role->session at actas time (it never runs actas-claim).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export CODEX_SESSIONS="$HOME/.codex/sessions"
}

teardown() { teardown_test_env; }

# Write a codex rollout file with a session_meta first line carrying id + cwd.
make_rollout() {
  local uuid="$1" cwd="$2" day="${3:-2026/07/05}" ts="${4:-2026-07-05T10-00-00}"
  local dir="$CODEX_SESSIONS/$day"
  mkdir -p "$dir"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$uuid" "$cwd" \
    > "$dir/rollout-$ts-$uuid.jsonl"
}

# --- _transcript-exists.sh ---

@test "codex transcript_exists: true when a rollout with the uuid exists" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "abc-uuid" "/proj"
  agmsg_transcript_exists "abc-uuid" "/proj"
}

@test "codex transcript_exists: false when no rollout carries the uuid" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "other-uuid" "/proj"
  ! agmsg_transcript_exists "abc-uuid" "/proj"
}

@test "codex transcript_exists: finds the rollout regardless of the date dir" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "deep-uuid" "/proj" "2026/06/01" "2026-06-01T09-09-09"
  agmsg_transcript_exists "deep-uuid" "/anything"   # project is not part of the lookup
}

@test "codex transcript_exists: empty uuid / unset HOME are not found" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "abc-uuid" "/proj"
  ! agmsg_transcript_exists "" "/proj"
  HOME="" run agmsg_transcript_exists "abc-uuid" "/proj"
  [ "$status" -ne 0 ]
}

# --- codex-record-session.sh ---

# Read back the recorded uuid for (team, agent).
recorded_uuid() {
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_uuid "$1" "$2"
}

@test "codex record: prefers CODEX_THREAD_ID (unambiguous env path)" {
  local proj; proj="$(mktemp -d)"
  CODEX_THREAD_ID="env-thread-1" \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "env-thread-1" ]
  # type is recorded as codex.
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  [ "$(agmsg_role_session_get team alice type)" = "codex" ]
}

@test "codex record: moving one thread to a new role removes its old same-project seat" {
  local proj; proj="$(mktemp -d)"
  CODEX_THREAD_ID="shared-thread" \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj"
  CODEX_THREAD_ID="shared-thread" \
    bash "$TYPES/codex/codex-record-session.sh" team reviewer "$proj"

  [ -z "$(recorded_uuid team alice)" ]
  [ "$(recorded_uuid team reviewer)" = "shared-thread" ]
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  local record
  record="$(agmsg_role_session_lookup_unique_by_sid shared-thread)"
  [[ "$record" == *$'agent=reviewer'* ]]
}

@test "codex record: monitor mode uses only its fresh generation-bound bridge thread" {
  local proj; proj="$(mktemp -d)"
  local generation="record-generation" tui bridge
  tui="$(SKILL_DIR="$TEST_SKILL_DIR" RUN_DIR="$RUN_DIR" bash -c \
    '. "$1/lib/codex-lease.sh"; codex_write_tui_lease team alice exact-monitor-thread "$2" "$3" ws://127.0.0.1:1 $$' \
    _ "$SCRIPTS" "$generation" "$proj")"
  bridge="$(SKILL_DIR="$TEST_SKILL_DIR" RUN_DIR="$RUN_DIR" bash -c \
    '. "$1/lib/codex-lease.sh"; codex_bridge_lease_path team alice' _ "$SCRIPTS")"
  cat >"$bridge" <<EOF
format_version=1
owner_kind=bridge
bound_thread_id=exact-monitor-thread
bound_generation=$generation
updated_at=$(date +%s)
EOF

  AGMSG_CODEX_BRIDGE_LAUNCHER=1 AGMSG_CODEX_TUI_GENERATION="$generation" \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "exact-monitor-thread" ]
  [ -f "$tui" ]
}

@test "codex record: monitor mode never substitutes an old same-cwd rollout" {
  local proj; proj="$(mktemp -d)"
  make_rollout "wrong-old-thread" "$proj"
  AGMSG_CODEX_BRIDGE_LAUNCHER=1 AGMSG_CODEX_TUI_GENERATION="missing-generation" \
    AGMSG_CODEX_ROLLOUT_MAX_AGE=999999 \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj"
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: falls back to the unique matching-cwd rollout when env is unset" {
  local proj; proj="$(mktemp -d)"
  make_rollout "fallback-uuid" "$proj"
  ( unset CODEX_THREAD_ID; bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ "$(recorded_uuid team alice)" = "fallback-uuid" ]
}

@test "codex record: records NOTHING when two recent rollouts share the cwd (ambiguous)" {
  local proj; proj="$(mktemp -d)"
  make_rollout "uuid-A" "$proj" "2026/07/05" "2026-07-05T10-00-00"
  make_rollout "uuid-B" "$proj" "2026/07/05" "2026-07-05T11-00-00"
  ( unset CODEX_THREAD_ID; bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: ignores a unique but stale same-cwd rollout" {
  local proj; proj="$(mktemp -d)"
  make_rollout "stale-uuid" "$proj"
  find "$CODEX_SESSIONS" -type f -name '*stale-uuid*' -exec touch -t 200001010000 {} \;
  ( unset CODEX_THREAD_ID; AGMSG_CODEX_ROLLOUT_MAX_AGE=300 \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: records nothing when no rollout matches the cwd" {
  local proj; proj="$(mktemp -d)"
  make_rollout "elsewhere-uuid" "/some/other/cwd"
  ( unset CODEX_THREAD_ID; bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: missing args are a no-op" {
  run bash "$TYPES/codex/codex-record-session.sh" team "" /proj
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}
