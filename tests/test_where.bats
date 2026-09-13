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
}

@test "where: herdr with a live HERDR_PANE_ID resolves to that pane, terminal name is diagnostic only" {
  export HERDR_ENV=1 HERDR_PANE_ID=w1:p4
  run bash "$SCRIPTS/where.sh"
  [ "$status" -eq 0 ]
  grep -q '^resolved=true' <<<"$output"
  grep -q 'placement=herdr:w1:p4' <<<"$output"
  # container is best-effort context, never absent outright — its failure
  # (no herdr on PATH here) must say why, not just vanish.
  grep -q 'container=' <<<"$output"
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
