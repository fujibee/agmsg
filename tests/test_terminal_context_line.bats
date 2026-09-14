#!/usr/bin/env bats

# agmsg_terminal_context_line (scripts/lib/terminal-context-line.sh) — renders
# where.sh's key=value line into the one sentence a session-start hook injects
# into an agent's own context, so it never has to guess its terminal driver or
# capabilities from env vars/grep (the #1171-class incident this line exists
# to prevent). See where.sh's own header and test_where.bats for the
# machine-readable contract this only reformats, never reimplements.

load test_helper

setup() {
  setup_test_env
  export AGMSG_PLUGIN_DIRS=""
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$FAKEBIN"
  : > "$ARGV_LOG"
  export HERDR_SOCKET_PATH="$TEST_SKILL_DIR/herdr.sock"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/terminal-context-line.sh"
}

teardown() { teardown_test_env; }

@test "terminal context line: plain (no addressable pane) names the driver, capabilities and its SKILL.md" {
  run agmsg_terminal_context_line "" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  grep -qF 'AGMSG terminal: plain (no addressable pane)' <<<"$output"
  grep -qF 'capabilities=spawn despawn peek poke' <<<"$output"
  grep -qF "notes: $TEST_SKILL_DIR/scripts/drivers/terminals/plain/SKILL.md" <<<"$output"
}

@test "terminal context line: herdr with a live pane names the pane id, not a generic placeholder" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p4
  run agmsg_terminal_context_line "" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  grep -qF "AGMSG terminal: herdr (pane $TEST_SKILL_DIR/herdr.sock:w1:p4)" <<<"$output"
  grep -qF 'capabilities=spawn despawn peek poke where arrange name' <<<"$output"
  grep -qF "notes: $TEST_SKILL_DIR/scripts/drivers/terminals/herdr/SKILL.md" <<<"$output"
}

@test "terminal context line: tmux with a live pane names the socket-qualified pane id" {
  agmsg_install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4"
  run agmsg_terminal_context_line "" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  grep -qF 'AGMSG terminal: tmux (pane /tmp/sock:%4)' <<<"$output"
  grep -qF "notes: $TEST_SKILL_DIR/scripts/drivers/terminals/tmux/SKILL.md" <<<"$output"
}

# The required RED control: where.sh's own failure (present terminal, unresolvable
# pane — #1171's exact shape) must still produce a VISIBLE sentence, never an
# empty line silently swallowed into the hook's output.
@test "terminal context line: a where.sh failure renders as a visible failure sentence, never silence" {
  export TMUX="/tmp/sock,1,0"
  unset TMUX_PANE
  run agmsg_terminal_context_line "" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF 'AGMSG terminal: could not be determined' <<<"$output"
  grep -qF 'TMUX_PANE' <<<"$output"
}

# The earlier version branched on the SHAPE of where.sh's
# stdout (did it start with "resolved=false"?) rather than its exit code. A
# where.sh that exits non-zero with EMPTY stdout -- a crash before any printf,
# a kill, a truncated write; not the documented resolved=false contract --
# fell through to the success-path parser and printed a line shaped like a
# real answer ("AGMSG terminal: unknown (pane ) capabilities=none"),
# discarding the actual failure. rc must be checked on its own, independent of
# what (if anything) is in $out.
@test "terminal context line: a where.sh that exits non-zero with EMPTY stdout still renders a visible failure, never a fake success line" {
  local fake_skill="$TEST_SKILL_DIR/broken-where"
  mkdir -p "$fake_skill/scripts"
  cat > "$fake_skill/scripts/where.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$fake_skill/scripts/where.sh"
  run agmsg_terminal_context_line "" "$fake_skill"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF 'AGMSG terminal: could not be determined' <<<"$output"
  # the load-bearing negative: the old bug's exact wrong output must not appear.
  refute grep -qF 'AGMSG terminal: unknown (pane )' <<<"$output"
}
