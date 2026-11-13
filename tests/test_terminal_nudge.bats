#!/usr/bin/env bats

# terminal-nudge.sh — agmsgd's entry point into poke.sh for the terminal-poke
# channel (a type with no native delivery channel). Against fake herdr on
# PATH (same frame as test_peek_poke.bats): the machine's real herdr/tmux
# must not start, and no real pane is touched.

load test_helper

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

_out_has() { printf '%s\n' "$output" | grep -qF -- "$1"; }

# A PATH with the core shell tools but no herdr/tmux (same helper
# test_peek_poke.bats uses for its own "driver not on PATH" cases).
_terminal_less_path() {
  local dir tool
  dir="$(mktemp -d)"
  for tool in bash sh dirname basename readlink uname sed grep awk cat tr \
              mktemp rm cp mv mkdir printf head tail wc sort cut date id sqlite3 paste; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$dir/$tool" 2>/dev/null || true
    fi
  done
  printf '%s' "$dir"
}

# A placement record for (testteam, agy1), typed antigravity. antigravity's
# own input_prompt_marker=> / input_prompt_boxed=yes (terminal-poke review,
# 2026-11-13) means poke.sh's input-box check now also reads the pane via
# `herdr pane read ... --format ansi` -- the fake herdr below answers that
# with an idle, empty box (rule / ">" / rule) so these tests exercise the
# readiness gate, not the box check (test_antigravity_input_box.bats covers
# the box check itself, including the confirmation-screen refusal).
_write_agy_record() {
  local ref="$1" path
  path="$(bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path testteam agy1')"
  [ -n "$path" ]
  printf '%s\t/tmp/project-a\tantigravity' "$ref" > "$path"
}

_install_fake_herdr_status() {
  local status="$1" kind="${2:-agy}"
  local rule
  rule="$(printf '─%.0s' $(seq 1 60))"
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf '%s\n>\n%s\n' '$rule' '$rule'
  exit 0
fi
if [ "\$1" = agent ] && [ "\$2" = get ]; then
  printf '{"result":{"agent":{"agent":"$kind","agent_status":"$status"}}}\n'
  exit 0
fi
if [ "\$1" = agent ] && [ "\$2" = prompt ]; then
  echo ok
  exit 0
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

@test "terminal-nudge: no placement record reports no_pane, no poke attempted" {
  run bash "$SCRIPTS/internal/terminal-nudge.sh" testteam agy1 --body -  <<< "hello"
  [ "$status" -eq 0 ]
  _out_has "state=no_pane"
  [ ! -s "$ARGV_LOG" ]
}

@test "terminal-nudge: a record with no id reports pane_gone" {
  local path
  path="$(bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path testteam agy1')"
  printf '\t/tmp/project-a\tantigravity' > "$path"
  run bash "$SCRIPTS/internal/terminal-nudge.sh" testteam agy1 --body-file <(printf 'hello')
  [ "$status" -eq 0 ]
  _out_has "state=pane_gone"
}

@test "terminal-nudge: a blocked herdr agent is not_ready, and poke.sh is never called" {
  _install_fake_herdr_status blocked
  _write_agy_record "herdr:wC:p4"
  run bash "$SCRIPTS/internal/terminal-nudge.sh" testteam agy1 --body-file <(printf 'hello')
  [ "$status" -eq 0 ]
  _out_has "state=not_ready:agent_status_blocked"
  # Readiness was checked (agent get), but the agent was never poked.
  grep -q '^herdr \[agent\] \[get\]' "$ARGV_LOG"
  [ "$(grep -c '^herdr \[agent\] \[prompt\]' "$ARGV_LOG" || true)" -eq 0 ]
}

@test "terminal-nudge: an idle herdr agent is notified via poke.sh" {
  _install_fake_herdr_status idle
  _write_agy_record "herdr:wC:p4"
  run bash "$SCRIPTS/internal/terminal-nudge.sh" testteam agy1 --body-file <(printf 'hello there')
  [ "$status" -eq 0 ]
  _out_has "state=notified"
  grep -q '^herdr \[agent\] \[prompt\] \[wC:p4\] \[hello there\]$' "$ARGV_LOG"
  # Never prints the body itself to stdout.
  [ "$(printf '%s\n' "$output" | grep -c 'hello there' || true)" -eq 0 ]
}

@test "terminal-nudge: a live permission-confirmation screen on herdr (mismatched short/long rules) refuses as box_not_found, never typed over (terminal-poke real-machine round, 2026-11-13)" {
  # herdr's own agent_status stays idle during a confirmation screen (a
  # separate real-machine finding, same date): readiness ALONE cannot catch
  # this case, so this test deliberately answers idle here too -- it is the
  # input-box check that must be the thing refusing, not readiness.
  #
  # Reproduces the REAL screen structure measured live (2026-11-13), not a
  # simplified one: herdr mixes a short ~60-char rule (separates scrollback
  # TURNS) with a long ~120-char rule (bounds the live input box) on the
  # SAME screen. A fixture using one consistent rule length throughout would
  # not have caught the actual bug -- the short/long pair below, with a
  # prior turn's own "> ..." line sitting between them, is exactly the
  # shape that made the original rule-matching logic pick the wrong pair.
  local short long
  short="$(printf '─%.0s' $(seq 1 60))"
  long="$(printf '─%.0s' $(seq 1 120))"
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf '%s\n> Read the file /tmp/x/harmless.txt and tell me its first word.\n\nFile access\n%s\n\nRead: /tmp/x/harmless.txt\n\nAllow access to this file?\n> 1. Yes, allow access\n  2. No, deny access\n' '$short' '$long'
  exit 0
fi
if [ "\$1" = agent ] && [ "\$2" = get ]; then
  printf '{"result":{"agent":{"agent":"agy","agent_status":"idle"}}}\n'
  exit 0
fi
if [ "\$1" = agent ] && [ "\$2" = prompt ]; then
  echo "must never submit into a live confirmation screen" >&2
  exit 1
fi
if [ "\$1" = agent ] && [ "\$2" = send-keys ]; then
  echo "must never clear a live confirmation screen's box (#1384 recovery must not engage on box_not_found)" >&2
  exit 1
fi
if [ "\$1" = pane ] && [ "\$2" = send-text ]; then
  echo "must never retype into a live confirmation screen" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
  _write_agy_record "herdr:wC:p4"
  run bash "$SCRIPTS/internal/terminal-nudge.sh" testteam agy1 --body-file <(printf 'agmsg: you have new messages.')
  [ "$status" -eq 0 ]
  _out_has "state=box_not_found"
  [ "$(grep -c '^herdr \[agent\] \[prompt\]' "$ARGV_LOG" || true)" -eq 0 ]
  [ "$(grep -c '^herdr \[agent\] \[send-keys\]' "$ARGV_LOG" || true)" -eq 0 ]
  [ "$(grep -c '^herdr \[pane\] \[send-text\]' "$ARGV_LOG" || true)" -eq 0 ]
}

@test "terminal-nudge: a working herdr agent is still ready (queues, does not wait for idle)" {
  _install_fake_herdr_status working
  _write_agy_record "herdr:wC:p4"
  run bash "$SCRIPTS/internal/terminal-nudge.sh" testteam agy1 --body-file <(printf 'hi')
  [ "$status" -eq 0 ]
  _out_has "state=notified"
}

@test "terminal-nudge: body via stdin works the same as --body-file" {
  _install_fake_herdr_status idle
  _write_agy_record "herdr:wC:p4"
  run bash -c "printf 'hi there' | bash \"$SCRIPTS/internal/terminal-nudge.sh\" testteam agy1 --body -"
  [ "$status" -eq 0 ]
  _out_has "state=notified"
  grep -q '^herdr \[agent\] \[prompt\] \[wC:p4\] \[hi there\]$' "$ARGV_LOG"
}

@test "terminal-nudge: an unreachable terminal (herdr not on PATH) is caught at the readiness check, before poke.sh ever runs" {
  _write_agy_record "herdr:wC:p4"
  local hp; hp="$(_terminal_less_path)"
  run env PATH="$hp" bash "$SCRIPTS/internal/terminal-nudge.sh" testteam agy1 --body-file <(printf 'hi')
  [ "$status" -eq 0 ]
  _out_has "state=unknown:terminal_unreachable"
}
