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

# Read back the recorded project for (team, agent).
recorded_project() {
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_get "$1" "$2" project
}

@test "codex record: project arg is optional -- defaults to \$PWD, canonical form" {
  local proj want; proj="$(mktemp -d)"
  want="$(cd "$proj" && pwd -P)"
  ( cd "$proj" && CODEX_THREAD_ID="pwd-thread-1" \
      bash "$TYPES/codex/codex-record-session.sh" team alice )
  [ "$(recorded_uuid team alice)" = "pwd-thread-1" ]
  [ "$(recorded_project team alice)" = "$want" ]
}

@test "codex record: no project arg + no env still finds the rollout via \$PWD" {
  local proj; proj="$(mktemp -d)"
  make_rollout "pwd-fallback-uuid" "$proj"
  ( unset CODEX_THREAD_ID; cd "$proj" && \
      bash "$TYPES/codex/codex-record-session.sh" team alice )
  [ "$(recorded_uuid team alice)" = "pwd-fallback-uuid" ]
}

# The lone `\` a PowerShell-parsed \"$PWD\" collapses to (see the script
# header). On MSYS it IS a real directory that canonicalizes to a drive root;
# on POSIX it fails the -d check. Either way: no record.
@test "codex record: backslash project (PowerShell quoting damage) records nothing" {
  CODEX_THREAD_ID="poison-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice '\'
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: filesystem-root project records nothing" {
  CODEX_THREAD_ID="root-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice /
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: drive-root project records nothing" {
  # /c exists on MSYS (caught by the root check); on POSIX it usually doesn't
  # (caught by -d). Both paths must end in "no record".
  CODEX_THREAD_ID="drive-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice /c
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: nonexistent project records nothing" {
  CODEX_THREAD_ID="ghost-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice /no/such/dir
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: symlinked project is recorded in canonical (physical) form" {
  local real link want; real="$(mktemp -d)"
  link="$HOME/proj-link"
  ln -s "$real" "$link" 2>/dev/null || skip "symlinks unavailable"
  [ -L "$link" ] || skip "ln -s fell back to copy (MSYS default)"
  want="$(cd "$real" && pwd -P)"
  CODEX_THREAD_ID="sym-thread" \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$link"
  [ "$(recorded_uuid team alice)" = "sym-thread" ]
  [ "$(recorded_project team alice)" = "$want" ]
}
