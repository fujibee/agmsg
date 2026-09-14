#!/usr/bin/env bats

# session-start.sh now leads its emitted directive with a terminal
# self-awareness line (AGMSG terminal: ...) built from where.sh, so a session
# learns its own driver and capabilities before any Monitor-tool instruction
# — instead of having to guess from env vars/grep the way #1171's incident
# agent did. This file pins that the line is present, correct per driver, and
# still visible (never silently dropped) when where.sh itself fails.

load test_helper

setup() {
  setup_test_env
  export AGMSG_PLUGIN_DIRS=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$RUN_DIR" "$FAKEBIN"
  : > "$ARGV_LOG"
  export HERDR_SOCKET_PATH="$TEST_SKILL_DIR/herdr.sock"
  export PROJ="/tmp/agmsg-session-start-terminal-line-proj"
  # A single registered seat: session-start.sh's generic (unfiltered) watcher
  # directive is the branch reached with nothing else to set up, and it is
  # one of the four text-emitting exit points this line was added to.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() { teardown_test_env; }

_run_session_start() {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$1\"}"
}

@test "session-start: plain environment leads with the plain terminal line" {
  run _run_session_start "sid-plain"
  [ "$status" -eq 0 ]
  # the terminal line must be the FIRST line — before the Monitor directive.
  [ "$(head -1 <<<"$output")" = "AGMSG terminal: plain (no addressable pane) capabilities=spawn despawn peek poke; notes: $TEST_SKILL_DIR/scripts/drivers/terminals/plain/SKILL.md" ]
  grep -qF "AGMSG monitor mode" <<<"$output"
}

@test "session-start: herdr environment leads with the herdr terminal line, own pane id" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p9
  run _run_session_start "sid-herdr"
  [ "$status" -eq 0 ]
  [ "$(head -1 <<<"$output")" = "AGMSG terminal: herdr (pane $TEST_SKILL_DIR/herdr.sock:w1:p9) capabilities=spawn despawn peek poke where arrange name; notes: $TEST_SKILL_DIR/scripts/drivers/terminals/herdr/SKILL.md" ]
}

@test "session-start: tmux environment leads with the tmux terminal line, socket-qualified pane id" {
  agmsg_install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%3"
  run _run_session_start "sid-tmux"
  [ "$status" -eq 0 ]
  [ "$(head -1 <<<"$output")" = "AGMSG terminal: tmux (pane /tmp/sock:%3) capabilities=spawn despawn peek poke where arrange name; notes: $TEST_SKILL_DIR/scripts/drivers/terminals/tmux/SKILL.md" ]
}

# The required RED control: a where.sh failure (unresolvable terminal) must
# still surface as a visible sentence at the top of the hook's output, never
# as a silently missing line that reads the same as "no messages" (#1171's own
# "silent = can't tell waiting from broken" hazard, reapplied to this line).
@test "session-start: a where.sh failure is visible at the top of the output, never silence" {
  export AGMSG_TERMINAL_DRIVER=bogus
  run _run_session_start "sid-broken-terminal"
  [ "$status" -eq 0 ]
  [ -n "$(head -1 <<<"$output")" ]
  grep -qF 'AGMSG terminal: could not be determined' <<<"$output"
  grep -qF 'bogus' <<<"$output"
  # delivery still proceeds — a where.sh failure must not take the whole hook
  # down with it.
  grep -qF "AGMSG monitor mode" <<<"$output"
}
