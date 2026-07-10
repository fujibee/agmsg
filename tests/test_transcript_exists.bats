#!/usr/bin/env bats

# Unit tests for the claude-code transcript-existence driver hook (#339 PR-C):
#   scripts/drivers/types/claude-code/_transcript-exists.sh
# It answers "does a resumable session transcript exist for <uuid>?" by locating
# ~/.claude/projects/<munged-project>/<uuid>.jsonl. The munging (every char
# outside [A-Za-z0-9-] -> '-') is CLI-internal knowledge that lives in the driver.

load test_helper

setup() {
  setup_test_env
  # HOME is already sandboxed to $TEST_SKILL_DIR/home by setup_test_env.
  # shellcheck disable=SC1090
  source "$TYPES/claude-code/_transcript-exists.sh"
}

teardown() { teardown_test_env; }

# Create the transcript file Claude Code would write for (uuid, project) under
# the sandboxed HOME, replicating the driver's munging so the paths line up.
make_transcript() {
  local uuid="$1" project="$2" munged
  munged="$(printf '%s' "$project" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
  mkdir -p "$HOME/.claude/projects/$munged"
  : > "$HOME/.claude/projects/$munged/$uuid.jsonl"
}

@test "transcript_exists: true when the <uuid>.jsonl file is present" {
  make_transcript "uuid-123" "/Users/me/proj"
  agmsg_transcript_exists "uuid-123" "/Users/me/proj"
}

@test "transcript_exists: false when the file is absent" {
  ! agmsg_transcript_exists "no-such-uuid" "/Users/me/proj"
}

@test "transcript_exists: munges '/', '.', and '_' all to '-'" {
  # /tmp/munge_Test.dir -> -tmp-munge-Test-dir (case preserved, _ and . -> -).
  local proj="/tmp/munge_Test.dir"
  mkdir -p "$HOME/.claude/projects/-tmp-munge-Test-dir"
  : > "$HOME/.claude/projects/-tmp-munge-Test-dir/u1.jsonl"
  agmsg_transcript_exists "u1" "$proj"
}

@test "transcript_exists: does not collapse runs of special chars" {
  # A leading '.' after '/' yields '--' (verified against the real CLI layout).
  local proj="/Users/me/.cfg"
  mkdir -p "$HOME/.claude/projects/-Users-me--cfg"
  : > "$HOME/.claude/projects/-Users-me--cfg/u2.jsonl"
  agmsg_transcript_exists "u2" "$proj"
}

@test "transcript_exists: empty uuid or project is not found" {
  make_transcript "uuid-123" "/Users/me/proj"
  ! agmsg_transcript_exists "" "/Users/me/proj"
  ! agmsg_transcript_exists "uuid-123" ""
}

@test "transcript_exists: unset HOME is not found (fail-open)" {
  make_transcript "uuid-123" "/Users/me/proj"
  HOME="" run agmsg_transcript_exists "uuid-123" "/Users/me/proj"
  [ "$status" -ne 0 ]
}
