#!/usr/bin/env bats

# where.sh (#1171) — a driver-neutral way for a session to ask its own
# placement, so a caller never has to guess or type a terminal-specific
# command (the #1171 incident: an agent under herdr ran a raw `tmux
# display-message`, and converted the resulting OS error into a false claim
# about its own placement). The load-bearing property this file protects:
# "could not determine" and "there is no pane" must come back as visibly
# different answers — never the same bare negative.

load test_helper

setup() {
  setup_test_env
  export AGMSG_PLUGIN_DIRS=""
}

teardown() { teardown_test_env; }

@test "where: nothing present resolves as a GENUINE no-pane answer (plain)" {
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 0 ]
  grep -q '^resolved=true' <<<"$output"
  grep -q 'placement=none' <<<"$output"
  grep -q 'reason=no_addressable_pane' <<<"$output"
  grep -q 'terminal=plain' <<<"$output"
  # #1082: the manifest's own ceiling reaches the caller verbatim.
  grep -q 'capabilities=spawn despawn peek poke' <<<"$output"
}

@test "where: herdr with a live HERDR_PANE_ID resolves to that pane, terminal name is diagnostic only" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p4 HERDR_SOCKET_PATH="$TEST_SKILL_DIR/herdr.sock"
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 0 ]
  grep -q '^resolved=true' <<<"$output"
  grep -q "placement=herdr:$TEST_SKILL_DIR/herdr.sock:w1:p4" <<<"$output"
  # the resolved driver is also named on its own key, not only as the
  # placement prefix a caller would otherwise have to parse out by hand.
  grep -q 'terminal=herdr' <<<"$output"
  # container is best-effort context, never absent outright — its failure
  # (no herdr on PATH here) must say why, not just vanish.
  grep -q 'container=' <<<"$output"
  # #1082: same ceiling, read from herdr's own terminal.conf.
  grep -q 'capabilities=spawn despawn peek poke where arrange name' <<<"$output"
}

@test "where: the Claude desktop app's Code tab resolves to claude-desktop by session id, never a pane" {
  # #1559/desktop-app-terminal-drivers: CLAUDE_CODE_ENTRYPOINT=claude-desktop
  # is the one marker (measured on a live desktop process; a terminal session
  # carries CLAUDE_CODE_ENTRYPOINT=cli). The placement id is the Claude Code
  # session id -- there is no pane to report instead. CLAUDE_CODE_HOST_SESSION_ID,
  # not CLAUDE_CODE_SESSION_ID, is what actually carries it: measured on a
  # live desktop-spawned process, CLAUDE_CODE_SESSION_ID (what a terminal
  # session carries) was absent there.
  export CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_HOST_SESSION_ID=desktop-sid-123
  unset CLAUDE_CODE_SESSION_ID
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 0 ]
  grep -q '^resolved=true' <<<"$output"
  grep -q 'placement=claude-desktop:desktop-sid-123' <<<"$output"
  grep -q 'terminal=claude-desktop' <<<"$output"
  # No container concept exists for a desktop session -- a decided fact, not
  # an unresolved pane lookup.
  grep -q 'container=n/a:no_container_concept' <<<"$output"
  # #1082: the manifest's own ceiling -- where only, never a pane verb.
  grep -q 'capabilities=where' <<<"$output"
  # The one thing this answer must never look like: a pane-shaped placement
  # from a driver that happened to have a stale env var lying around.
  refute grep -q 'placement=herdr' <<<"$output"
  refute grep -q 'placement=tmux' <<<"$output"
  refute grep -q 'placement=orca' <<<"$output"
}

@test "where: tmux with a live \$TMUX_PANE resolves to that pane, terminal=tmux is explicit" {
  export FAKEBIN="$TEST_SKILL_DIR/fakebin" ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$FAKEBIN"
  : > "$ARGV_LOG"
  agmsg_install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4"
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 0 ]
  grep -q '^resolved=true' <<<"$output"
  grep -q 'placement=tmux:/tmp/sock:%4' <<<"$output"
  # same field, same reason as herdr above: named on its own key, not only
  # as the placement prefix.
  grep -q 'terminal=tmux' <<<"$output"
}

# --- the required RED control (#1171): present-but-unidentifiable must NOT
# collapse into "no pane". tmux's own terminal_detect decides presence from
# $TMUX alone (no tmux binary is invoked for detection), so setting $TMUX and
# leaving $TMUX_PANE unset reproduces "a terminal is present and cannot say
# which pane" without needing a real tmux server — exactly the shape of the
# #1171 incident (asked, and the answer could not be trusted as absence).
@test "where: tmux present but \$TMUX_PANE unset -> resolved=false with a reason, NEVER placement=none (#1171)" {
  export TMUX="/tmp/sock,1,0"
  unset TMUX_PANE
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 1 ]
  grep -q '^resolved=false' <<<"$output"
  grep -q 'reason=' <<<"$output"
  # names WHICH terminal was asked...
  grep -q 'tmux' <<<"$output"
  # ...and WHY it could not answer.
  grep -q 'TMUX_PANE' <<<"$output"
  # the one thing this answer must never say: a bare negative about placement.
  refute grep -q 'placement=none' <<<"$output"
  refute grep -q 'no_addressable_pane' <<<"$output"
}

@test "where: an unknown AGMSG_TERMINAL_DRIVER override fails loudly, naming the bad value" {
  export AGMSG_TERMINAL_DRIVER=tnux
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 1 ]
  grep -q '^resolved=false' <<<"$output"
  grep -q "tnux" <<<"$output"
}

# --- #1082 acceptance: a manifest capability reaches the caller with no doc
# edit anywhere. "frobnicate" names nothing real on purpose — its only
# possible source is this fixture's terminal.conf, never a hand-written
# description that could have drifted from it.
_install_fixture_capability_driver() {
  local d="$TEST_SKILL_DIR/plugins/terminals/probe"
  mkdir -p "$d" "$TEST_SKILL_DIR/db"
  cat > "$d/terminal.conf" <<'EOF'
name=probe
priority=15
backend=test probe
capabilities=name frobnicate
EOF
  cat > "$d/ops.sh" <<'EOF'
terminal_check() { echo ok; }
terminal_describe() { echo name=probe; }
terminal_detect() { printf 'probe-pane\n'; }
terminal_spawn() { printf 'probe-spawned\n'; }
terminal_despawn() { :; }
terminal_pane_state() { echo present; }
terminal_peek() { :; }
terminal_poke() { :; }
terminal_where() { echo probe-container; }
terminal_arrange() { echo unchanged; }
terminal_name() { :; }
EOF
  printf 'terminals/probe\t%s\n' "$d" > "$TEST_SKILL_DIR/db/trusted-plugins"
}

@test "where: a capability added to a fixture driver's manifest alone reaches the caller (#1082)" {
  _install_fixture_capability_driver
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 0 ]
  grep -q 'placement=probe:probe-pane' <<<"$output"
  grep -q 'terminal=probe' <<<"$output"
  grep -q 'capabilities=name frobnicate' <<<"$output"
}
