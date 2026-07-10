#!/usr/bin/env bats

# Unit tests for the tmux-resurrect post-restore hook (#339 PR-D):
#   scripts/internal/resurrect-panes.sh
# Exercise the pure parse + command-construction core (agmsg_resurrect_plan)
# against a fixture save file. The live send-keys / kill-server path is a manual
# checklist item in the PR, not CI.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # Source the hook for its functions (guarded: sourcing does not run main).
  # shellcheck disable=SC1090
  source "$SCRIPTS/internal/resurrect-panes.sh"
  export FIXTURE="$TEST_SKILL_DIR/resurrect.txt"
}

teardown() { teardown_test_env; }

# Write a role-session record straight to run/ (bypasses actas-claim).
put_record() {
  local team="$1" agent="$2" uuid="$3" proj="$4" type="${5:-claude-code}"
  agmsg_role_session_record "$team" "$agent" "$uuid" "$proj" "$type"
}

# Append a tmux-resurrect pane line to the fixture. Tab-separated; matches the
# 11-field layout the parser expects.
pane_line() {
  local session="$1" windex="$2" pindex="$3" title="$4" path="$5" cmd="$6" full="$7"
  printf 'pane\t%s\t%s\t1\t:*\t%s\t%s\t:%s\t1\t%s\t:%s\n' \
    "$session" "$windex" "$pindex" "$title" "$path" "$cmd" "$full" >> "$FIXTURE"
}

# Create the transcript Claude Code would have for (uuid, project) so the resume
# gate fires. Mirrors the driver munging.
make_transcript() {
  local uuid="$1" project="$2" munged
  munged="$(printf '%s' "$project" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
  mkdir -p "$HOME/.claude/projects/$munged"
  : > "$HOME/.claude/projects/$munged/$uuid.jsonl"
}

@test "resurrect-panes.sh is executable (tmux-resurrect execs the hook directly)" {
  # The hook is the @resurrect-hook-post-restore-all target, run directly (not
  # via `bash <path>`), so a missing exec bit makes it die with Permission denied
  # -- the restore succeeds but no pane gets seated. Guard the committed mode.
  [ -x "$SCRIPTS/internal/resurrect-panes.sh" ]
}

@test "plan: seats a role pane matched by its saved title" {
  put_record agmsg aggie "sess-1" /proj
  pane_line agmsg 0 0 "* agmsg-aggie" /proj bash "claude -n agmsg-aggie /agmsg actas aggie"

  run agmsg_resurrect_plan "$FIXTURE"
  [ "$status" -eq 0 ]
  # <target>\t<command>: target is session:window.pane
  [[ "$output" == "agmsg:0.0"* ]]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"-n agmsg-aggie"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "plan: skips a role whose actas lock is held by a live session (#339)" {
  # The role's owner is alive elsewhere (its record may have been sown from a
  # still-running session in another process). Reseating would resume a uuid that
  # is already open -> the CLI rejects the double-launch and the pane dies to a
  # shell. The lock -- not "pane is a shell" -- is the source of truth here.
  put_record agmsg aggie "sess-1" /proj
  pane_line agmsg 0 0 "* agmsg-aggie" /proj bash "claude -n agmsg-aggie /agmsg actas aggie"
  # A live actas-lock owner: cc-instance for this test's pid holds the owner sid.
  echo "live-owner" > "$RUN_DIR/cc-instance.$$"
  echo "live-owner" > "$(actas_lock_path agmsg aggie)"

  run agmsg_resurrect_plan "$FIXTURE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plan: still reseats when the lock is stale (owner sid dead) (#339)" {
  # A dead owner (no live cc-instance references the sid) is a stale lock ->
  # actas_lock_state reports free -> the role really needs reseating.
  put_record agmsg aggie "sess-1" /proj
  pane_line agmsg 0 0 "* agmsg-aggie" /proj bash "claude -n agmsg-aggie /agmsg actas aggie"
  echo "dead-owner" > "$(actas_lock_path agmsg aggie)"   # no cc-instance -> not alive

  run agmsg_resurrect_plan "$FIXTURE"
  [[ "$output" == "agmsg:0.0"* ]]
  [[ "$output" == *"-n agmsg-aggie"* ]]
}

@test "plan: matches by the -n role marker in the saved argv when the title is generic" {
  put_record agmsg worker "sess-2" /proj
  pane_line agmsg 1 2 "zsh" /proj zsh "claude -n agmsg-worker /agmsg actas worker"

  run agmsg_resurrect_plan "$FIXTURE"
  [[ "$output" == "agmsg:1.2"* ]]
  [[ "$output" == *"-n agmsg-worker"* ]]
}

@test "plan: adds --resume <uuid> when the recorded transcript still exists" {
  put_record agmsg aggie "sess-1" /proj
  make_transcript "sess-1" /proj
  pane_line agmsg 0 0 "* agmsg-aggie" /proj bash "claude -n agmsg-aggie /agmsg actas aggie"

  run agmsg_resurrect_plan "$FIXTURE"
  [[ "$output" == *"--resume sess-1"* ]]
}

@test "plan: falls back to fresh (no --resume) when the transcript is gone" {
  put_record agmsg aggie "sess-1" /proj   # record but no transcript
  pane_line agmsg 0 0 "* agmsg-aggie" /proj bash "claude -n agmsg-aggie /agmsg actas aggie"

  run agmsg_resurrect_plan "$FIXTURE"
  [[ "$output" != *"--resume"* ]]
  [[ "$output" == *"-n agmsg-aggie"* ]]   # still seated, just fresh
}

@test "plan: ignores panes that are not a role seat" {
  put_record agmsg aggie "sess-1" /proj
  pane_line agmsg 0 0 "vim" /proj vim "vim README.md"

  run agmsg_resurrect_plan "$FIXTURE"
  [ -z "$output" ]
}

@test "plan: a title that matches no record is not seated" {
  put_record agmsg aggie "sess-1" /proj
  pane_line agmsg 0 0 "* agmsg-ghost" /proj bash "bash"

  run agmsg_resurrect_plan "$FIXTURE"
  [ -z "$output" ]
}

@test "plan: empty when there are no role-session records" {
  pane_line agmsg 0 0 "* agmsg-aggie" /proj bash "claude -n agmsg-aggie /agmsg actas aggie"
  run agmsg_resurrect_plan "$FIXTURE"
  [ -z "$output" ]
}

@test "plan: empty when the save file is missing" {
  put_record agmsg aggie "sess-1" /proj
  run agmsg_resurrect_plan "$TEST_SKILL_DIR/does-not-exist.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plan: multiple role panes each get their own seat line" {
  put_record agmsg aggie  "sess-1" /proj
  put_record agmsg worker "sess-2" /proj
  pane_line agmsg 0 0 "* agmsg-aggie"  /proj bash "claude -n agmsg-aggie /agmsg actas aggie"
  pane_line agmsg 0 1 "* agmsg-worker" /proj bash "claude -n agmsg-worker /agmsg actas worker"

  run agmsg_resurrect_plan "$FIXTURE"
  [ "$(printf '%s\n' "$output" | grep -c 'agmsg:0')" -eq 2 ]
  [[ "$output" == *"agmsg:0.0"* ]]
  [[ "$output" == *"agmsg:0.1"* ]]
}

@test "save_file: prefers AGMSG_RESURRECT_SAVE override" {
  : > "$FIXTURE"
  AGMSG_RESURRECT_SAVE="$FIXTURE" run agmsg_resurrect_save_file
  [ "$status" -eq 0 ]
  [ "$output" = "$FIXTURE" ]
}

@test "save_file: fails when nothing exists" {
  AGMSG_RESURRECT_SAVE="" HOME="$TEST_SKILL_DIR/empty-home" run agmsg_resurrect_save_file
  [ "$status" -ne 0 ]
}
