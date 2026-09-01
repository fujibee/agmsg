#!/usr/bin/env bats

# peek.sh / poke.sh — the terminal-driver entry points, against fake
# tmux/herdr binaries on PATH that record their argv (same frame as
# test_terminal_registry.bats: the machine's real tmux server must not start,
# and no real herdr pane is touched).
#
# What the poke tests pin is the argv SHAPE, per the #619 lesson: the text and
# the Enter must arrive in SEPARATE tmux invocations, with the arrow key in the
# Enter's burst — a fake binary cannot verify that the real Codex reads the
# result as a submission (the live matrix does), but it CAN prove the calls did
# not collapse back into one burst, which is exactly the regression #619 was.
# The gap between the bursts is a sleep the argv log cannot see; only the live
# matrix observes timing.
#
# Assertions use grep/[ ]/case throughout — no non-last [[ ]] or `! cmd`,
# which the enforced-assertions baseline counts (#670).

load test_helper

# Assert <needle> is a substring of $output (enforceable on both shells).
_out_has() { printf '%s\n' "$output" | grep -qF -- "$1"; }

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_PLUGIN_DIRS=""
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$FAKEBIN" "$TEST_SKILL_DIR/run"
  : > "$ARGV_LOG"
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID AGMSG_TERMINAL AGMSG_TERMINAL_DRIVER
}

teardown() { teardown_test_env; }

# Write a placement record for (testteam, alice) with the given ref, at the
# exact path the entry scripts resolve (agmsg_spawn_path), so a drift between
# writer and reader fails here instead of passing on a hand-made path.
_write_record() {
  local ref="$1" path
  path="$(bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path testteam alice')"
  [ -n "$path" ]
  printf '%s\t/tmp/project-a\tclaude-code' "$ref" > "$path"
}

_install_fake_tmux() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$1" in
  capture-pane) printf 'boot prompt line\nsecond line\n' ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

_install_fake_herdr() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf 'herdr visible text\n'
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

# --- peek ----------------------------------------------------------------

@test "peek: tmux record reads the pane verbatim; --lines forwards scrollback" {
  _install_fake_tmux
  _write_record "tmux:%5"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 0 ]
  _out_has "boot prompt line"
  grep -q '^tmux \[capture-pane\] \[-p\] \[-t\] \[%5\]$' "$ARGV_LOG"
  : > "$ARGV_LOG"
  run bash "$SCRIPTS/peek.sh" testteam alice --lines 40
  [ "$status" -eq 0 ]
  grep -q '^tmux \[capture-pane\] \[-p\] \[-t\] \[%5\] \[-S\] \[-40\]$' "$ARGV_LOG"
}

@test "peek: a legacy bare tmux id in the record still resolves as tmux" {
  _install_fake_tmux
  _write_record "%7"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 0 ]
  grep -q '\[capture-pane\] \[-p\] \[-t\] \[%7\]' "$ARGV_LOG"
}

@test "peek: no placement record refuses loudly and runs no terminal binary" {
  _install_fake_tmux
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -ne 0 ]
  _out_has "no placement record for 'testteam/alice'"
  # The refusal must come from the record check, not from a driver poking a
  # terminal about a member we cannot even locate.
  [ ! -s "$ARGV_LOG" ]
}

@test "peek: a plain record is unsupported — non-zero with a reason, never a quiet 0" {
  _write_record "plain:-"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 13 ]
  _out_has "unsupported: plain terminal has no addressable pane"
}

@test "peek: --lines rejects a non-number instead of passing it through" {
  _install_fake_tmux
  _write_record "tmux:%5"
  run bash "$SCRIPTS/peek.sh" testteam alice --lines many
  [ "$status" -ne 0 ]
  _out_has "--lines must be a whole number"
  [ ! -s "$ARGV_LOG" ]
}

# --- poke ----------------------------------------------------------------

@test "poke: tmux text and Enter arrive in SEPARATE bursts, arrow in the second (#619)" {
  _install_fake_tmux
  _write_record "tmux:%5"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello there"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via tmux"
  # Exactly TWO tmux invocations: a merged single burst (the #619 regression)
  # or a third stray call both change this count.
  [ "$(grep -c '^tmux ' "$ARGV_LOG")" -eq 2 ]
  local first second
  first="$(sed -n '1p' "$ARGV_LOG")"
  second="$(sed -n '2p' "$ARGV_LOG")"
  # Burst 1 is the literal text and carries NO Enter — the equality is what
  # goes red if the Enter ever rejoins the text burst (an Enter appended to
  # this line makes the string differ).
  [ "$first" = 'tmux [send-keys] [-l] [-t] [%5] [--] [hello there]' ]
  # Burst 2 ends paste classification with an arrow key, THEN submits.
  [ "$second" = 'tmux [send-keys] [-t] [%5] [Right] [Enter]' ]
}

@test "poke: herdr submits in ONE call (agent prompt) with no Enter dance" {
  _install_fake_herdr
  _write_record "herdr:wC:p4"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via herdr"
  [ "$(grep -c '^herdr ' "$ARGV_LOG")" -eq 1 ]
  # The inner ':' of the herdr pane id must survive the record round-trip.
  grep -q '^herdr \[agent\] \[prompt\] \[wC:p4\] \[hello\]$' "$ARGV_LOG"
  # No synthesized keystrokes: submission is agent prompt's own.
  [ "$(grep -ci 'enter' "$ARGV_LOG" || true)" -eq 0 ]
}

@test "poke: a plain record is unsupported — non-zero with a reason" {
  _write_record "plain:-"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 13 ]
  _out_has "unsupported: plain terminal has no addressable pane"
}

@test "poke: unquoted multi-word text is refused, not silently truncated" {
  _install_fake_tmux
  _write_record "tmux:%5"
  run bash "$SCRIPTS/poke.sh" testteam alice hello world
  [ "$status" -ne 0 ]
  _out_has "quote the text as one argument"
  [ ! -s "$ARGV_LOG" ]
}

@test "poke: no placement record refuses loudly and runs no terminal binary" {
  _install_fake_tmux
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -ne 0 ]
  _out_has "no placement record for 'testteam/alice'"
  [ ! -s "$ARGV_LOG" ]
}
