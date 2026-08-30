#!/usr/bin/env bats

# Terminal driver axis (v1) — registry resolution, record scheme, and the three
# drivers' ops, exercised against fake `tmux`/`herdr` binaries on PATH that
# record their argv. No real tmux server is started and no real herdr pane is
# touched (frame: the machine's tmux server must not start; live-CLI argv for
# herdr agent-prompt / pane-read is verified separately by the live matrix).
#
# The ops are sourced shell functions, so env is set via export/unset in the
# test (bats runs each test in its own subshell, so it does not leak) rather than
# `env VAR=... func` (env cannot invoke a function).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_PLUGIN_DIRS=""
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$FAKEBIN"
  : > "$ARGV_LOG"
  # A clean env baseline; individual tests opt into TMUX / HERDR_ENV.
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID AGMSG_TERMINAL
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
}

teardown() { teardown_test_env; }

# A fake `tmux` that logs argv and produces the ids/text real tmux would.
_install_fake_tmux() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$1" in
  new-window)   echo '@7' ;;
  split-window) echo '%9' ;;
  capture-pane) printf 'line one\nline two\n' ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

# A fake `herdr` that logs argv and returns canned JSON/text for session <sid>.
_install_fake_herdr() {
  local sid="${1:-}"
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = agent ] && [ "\$2" = list ]; then
  printf '[{"agent_session":"%s","pane_id":"wC:p4"}]\n' "$sid"
elif [ "\$1" = pane ] && [ "\$2" = split ]; then
  echo '{"result":{"pane":{"pane_id":"wC:p9"}}}'
elif [ "\$1" = tab ] && [ "\$2" = create ]; then
  echo '{"result":{"root_pane":{"pane_id":"wD:p1"}}}'
elif [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf 'herdr visible text\n'
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

# --- resolution -------------------------------------------------------------

@test "resolve: falls back to plain when neither tmux nor herdr is present" {
  run agmsg_terminal_resolve "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'plain\t-')" ]
}

@test "resolve: picks tmux from \$TMUX and returns \$TMUX_PANE as the self id" {
  _install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4"
  run agmsg_terminal_resolve "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tmux\t%%4')" ]
}

@test "resolve: picks herdr from HERDR_ENV and resolves the pane from the session id" {
  _install_fake_herdr "sess-abc"
  export HERDR_ENV=1
  run agmsg_terminal_resolve "sess-abc"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\twC:p4')" ]
}

@test "resolve: detection order puts herdr before tmux when both env are present" {
  _install_fake_tmux
  _install_fake_herdr "sess-abc"
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4" HERDR_ENV=1
  run agmsg_terminal_resolve "sess-abc"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\twC:p4')" ]
}

@test "resolve: an explicit override wins over detection" {
  _install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4" AGMSG_TERMINAL=plain
  run agmsg_terminal_resolve "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'plain\t-')" ]
}

@test "selection drives ops: the RESOLVED terminal is the one whose ops run" {
  # Guards the "broken but green" a fixture invites: recording argv proves a
  # binary was CALLED, not that the RIGHT driver was selected. Here both env are
  # present (herdr must win), and we don't just assert the name — we load the
  # resolved terminal and run an op, asserting it reaches the herdr binary and
  # NEVER tmux. A resolver that wrongly returned tmux would load tmux, whose
  # despawn rejects a herdr-shaped id without calling any binary, so the herdr
  # grep fails: the selection error cannot slip through as "argv as expected".
  _install_fake_tmux
  _install_fake_herdr "sess-77"
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4" HERDR_ENV=1
  local res term
  res="$(agmsg_terminal_resolve sess-77)"
  term="$(printf '%s' "$res" | cut -f1)"
  [ "$term" = "herdr" ]
  : > "$ARGV_LOG"
  agmsg_terminal_load "$term"
  terminal_despawn "wC:p9" >/dev/null
  grep -q '^herdr ' "$ARGV_LOG"
  refute grep -q '^tmux ' "$ARGV_LOG"
}

# --- record scheme ----------------------------------------------------------

@test "record: ref composes, and terminal/id split handles scheme, legacy bare, and inner colon" {
  [ "$(agmsg_terminal_ref tmux '%3')" = "tmux:%3" ]
  [ "$(agmsg_terminal_ref_terminal 'tmux:%3')" = "tmux" ]
  [ "$(agmsg_terminal_ref_terminal 'herdr:wC:pN')" = "herdr" ]
  [ "$(agmsg_terminal_ref_terminal '%3')" = "tmux" ]
  [ "$(agmsg_terminal_ref_terminal '@3')" = "tmux" ]
  [ "$(agmsg_terminal_ref_id 'herdr:wC:pN')" = "wC:pN" ]
  [ "$(agmsg_terminal_ref_id '%3')" = "%3" ]
}

# --- conf reader ------------------------------------------------------------

@test "conf: get reads a key, has tests membership, absent key returns default" {
  [ "$(agmsg_terminal_get plain capabilities)" = "spawn" ]
  agmsg_terminal_has plain capabilities spawn
  refute agmsg_terminal_has plain capabilities peek
  [ "$(agmsg_terminal_get plain nonesuch DEFLT)" = "DEFLT" ]
}

# --- plain driver -----------------------------------------------------------

@test "plain: peek and poke are unsupported (exit 13, reason on stderr)" {
  agmsg_terminal_load plain
  run terminal_peek "-"
  [ "$status" -eq 13 ]
  grep -q 'unsupported' <<<"$output"
  run terminal_poke "-" "hi"
  [ "$status" -eq 13 ]
  grep -q 'unsupported' <<<"$output"
}

@test "plain: check ok, describe advertises spawn only" {
  agmsg_terminal_load plain
  run terminal_check
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  run terminal_describe
  grep -q '^capabilities=spawn$' <<<"$output"
}

# --- tmux driver ops (fake tmux argv) --------------------------------------

@test "tmux: spawn a pane emits split-window and returns the captured id" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  export AGMSG_TMUX_SPLIT=-v
  run terminal_spawn alice /proj pane bash -lc boot
  [ "$status" -eq 0 ]
  [ "$output" = "%9" ]
  grep -q 'split-window' "$ARGV_LOG"
  grep -q '\[-v\]' "$ARGV_LOG"
}

@test "tmux: despawn kills a pane vs a window by id shape" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  terminal_despawn '%9' >/dev/null
  grep -q '\[kill-pane\] \[-t\] \[%9\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_despawn '@7' >/dev/null
  grep -q '\[kill-window\] \[-t\] \[@7\]' "$ARGV_LOG"
}

@test "tmux: peek captures the pane, --lines adds scrollback start" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  run terminal_peek '%9'
  [ "$status" -eq 0 ]
  grep -q 'line one' <<<"$output"
  grep -q '\[capture-pane\] \[-p\] \[-t\] \[%9\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_peek '%9' --lines 50 >/dev/null
  grep -q '\[-S\] \[-50\]' "$ARGV_LOG"
}

@test "tmux: poke sends text and the Enter in SEPARATE bursts with an arrow between (#619)" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  export AGMSG_POKE_GAP=0
  run terminal_poke '%9' 'hello world'
  [ "$status" -eq 0 ]
  grep -q '\[send-keys\] \[-l\] \[-t\] \[%9\] \[--\] \[hello world\]' "$ARGV_LOG"
  grep -q '\[send-keys\] \[-t\] \[%9\] \[Right\] \[Enter\]' "$ARGV_LOG"
  [ "$(grep -c 'send-keys' "$ARGV_LOG")" -eq 2 ]
}

@test "tmux: name titles a pane and renames a window" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  terminal_name '%9' teamx alice >/dev/null
  grep -q '\[select-pane\] \[-t\] \[%9\] \[-T\] \[teamx/alice\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_name '@7' teamx alice >/dev/null
  grep -q '\[rename-window\] \[-t\] \[@7\] \[teamx/alice\]' "$ARGV_LOG"
}

# --- herdr driver ops (fake herdr argv; live-verified argv flagged) ---------

@test "herdr: detect resolves the pane for the session id via agent list" {
  _install_fake_herdr "sess-77"
  agmsg_terminal_load herdr
  export HERDR_ENV=1
  run terminal_detect "sess-77"
  [ "$status" -eq 0 ]
  [ "$output" = "wC:p4" ]
  grep -q '\[agent\] \[list\]' "$ARGV_LOG"
}

@test "herdr: spawn splits a pane, renames, runs boot, returns the new id" {
  _install_fake_herdr "sess-77"
  agmsg_terminal_load herdr
  export HERDR_PANE_ID='wC:p1'
  run terminal_spawn alice /proj pane bash -lc boot
  [ "$status" -eq 0 ]
  [ "$output" = "wC:p9" ]
  grep -q '\[pane\] \[split\]' "$ARGV_LOG"
  grep -q '\[pane\] \[rename\] \[wC:p9\] \[alice\]' "$ARGV_LOG"
  grep -q '\[pane\] \[run\] \[wC:p9\]' "$ARGV_LOG"
}

@test "herdr: despawn closes the pane; peek reads visible; name encodes team__name" {
  _install_fake_herdr "sess-77"
  agmsg_terminal_load herdr
  terminal_despawn 'wC:p9' >/dev/null
  grep -q '\[pane\] \[close\] \[wC:p9\]' "$ARGV_LOG"
  run terminal_peek 'wC:p9'
  [ "$status" -eq 0 ]
  grep -q 'herdr visible text' <<<"$output"
  grep -q '\[pane\] \[read\] \[wC:p9\] \[--source\] \[visible\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_name 'wC:p9' teamx alice >/dev/null
  grep -q '\[pane\] \[rename\] \[wC:p9\] \[teamx__alice\]' "$ARGV_LOG"
}
