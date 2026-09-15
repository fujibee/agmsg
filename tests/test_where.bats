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

# #1254: a Codex seat whose shell commands run inside a SHARED, reused
# per-project app-server inherits that server's own birth environment (the
# FIRST seat's HERDR_PANE_ID/TMUX_PANE), not its own. where.sh must report
# unresolved through that inherited env, never the wrong pane -- and a
# LEAKED copy of the marker (its claimed pid genuinely not an ancestor of
# this process, e.g. carried by something that has since moved into its own
# real pane) must NOT be treated as evidence of a shared context either;
# both outcomes of the same detection are pinned in one test.
_marker_for_pid() {   # <pid> -> "<pid>.<witness>", or empty if unreadable
  local pid="$1" w
  w="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s '[:space:]' '_')"
  w="${w#_}"; w="${w%_}"
  [ -n "$w" ] || return 1
  printf '%s.%s\n' "$pid" "$w"
}

@test "where: herdr under a Codex marker whose pid is a REAL ancestor reports unresolved, not the inherited pane; a leaked marker whose pid is NOT an ancestor does not (#1254)" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p4 HERDR_SOCKET_PATH="$TEST_SKILL_DIR/herdr.sock"
  export CODEX_THREAD_ID=fake-thread
  local real_marker
  real_marker="$(_marker_for_pid "$$")"
  [ -n "$real_marker" ] || skip "could not read this test shell's own process start time (ps -o lstart=)"

  # A pid that is genuinely NOT in this process's ancestry, but IS alive and
  # readable: a throwaway background sleep, a SIBLING of this test shell,
  # never an ancestor of a later `bash where.sh` child.
  sleep 5 & local sibling_pid=$!
  local leaked_marker
  leaked_marker="$(_marker_for_pid "$sibling_pid")" || leaked_marker=""

  AGMSG_CODEX_SHARED_APP_SERVER="$real_marker" run bash "$SCRIPTS/where.sh"
  [ "$status" -ne 0 ]
  grep -q '^resolved=false' <<<"$output"

  if [ -n "$leaked_marker" ]; then
    AGMSG_CODEX_SHARED_APP_SERVER="$leaked_marker" run bash "$SCRIPTS/where.sh"
    kill "$sibling_pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    grep -q '^resolved=true' <<<"$output"
    grep -q "placement=herdr:$TEST_SKILL_DIR/herdr.sock:w1:p4" <<<"$output"
  else
    kill "$sibling_pid" 2>/dev/null || true
  fi
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
