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

_write_named_record() {
  local name="$1" ref="$2" path
  path="$(bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path testteam "$1"' _ "$name")"
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

@test "peek: a plain record is a dead end — and does NOT point at a native channel" {
  _write_record "plain:-"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 13 ]
  _out_has "unsupported: plain terminal has no addressable pane"
  # The peek/poke asymmetry is measured, not stylistic: SendMessage gives poke
  # a native write path, but today's CLI has no read path (`claude logs` is
  # background-only; `agents --json` carries status, not screen content). A
  # native-channel pointer here would send the reader chasing a door that does
  # not exist — assert its absence so adding one back is a conscious decision.
  [ "$(printf '%s\n' "$output" | grep -c 'native channel' || true)" -eq 0 ]
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

@test "poke: a plain record is unsupported as a TERMINAL answer, and points at the type's native channel (peek deliberately does not — no CLI read path)" {
  _write_record "plain:-"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 13 ]
  _out_has "unsupported: plain terminal has no addressable pane"
  _out_has "agent type may offer a native channel"
}

@test "poke: unquoted multi-word text is refused, not silently truncated" {
  _install_fake_tmux
  _write_record "tmux:%5"
  run bash "$SCRIPTS/poke.sh" testteam alice hello world
  [ "$status" -ne 0 ]
  _out_has "quote the text as one argument"
  [ ! -s "$ARGV_LOG" ]
}

@test "poke: --body-file delivers a shell-hostile body verbatim (#507's class)" {
  _install_fake_herdr
  _write_record "herdr:wC:p4"
  # Backtick, $( ), quotes, $VAR — none of it may execute or change: the body
  # never crosses the caller's shell. Equality against the argv line is the
  # assertion; a vanished span (what #507 did to send bodies) changes the line.
  printf '%s' 'check `whoami` and $(hostname) plus "quotes" and $HOME here' > "$TEST_SKILL_DIR/body.txt"
  run bash "$SCRIPTS/poke.sh" testteam alice --body-file "$TEST_SKILL_DIR/body.txt"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via herdr"
  [ "$(sed -n '1p' "$ARGV_LOG")" = 'herdr [agent] [prompt] [wC:p4] [check `whoami` and $(hostname) plus "quotes" and $HOME here]' ]
  [ "$(grep -c '^herdr ' "$ARGV_LOG")" -eq 1 ]
}

@test "poke: --body - reads stdin; a missing file and an empty body refuse before any terminal runs" {
  _install_fake_tmux
  _write_record "tmux:%5"
  printf 'from stdin' | { run bash "$SCRIPTS/poke.sh" testteam alice --body -; \
    [ "$status" -eq 0 ]; }
  grep -q '\[send-keys\] \[-l\] \[-t\] \[%5\] \[--\] \[from stdin\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  run bash "$SCRIPTS/poke.sh" testteam alice --body-file "$TEST_SKILL_DIR/does-not-exist"
  [ "$status" -ne 0 ]
  _out_has "cannot read body file"
  : > "$TEST_SKILL_DIR/empty.txt"
  run bash "$SCRIPTS/poke.sh" testteam alice --body-file "$TEST_SKILL_DIR/empty.txt"
  [ "$status" -ne 0 ]
  _out_has "the body is empty"
  run bash "$SCRIPTS/poke.sh" testteam alice --body not-a-dash
  [ "$status" -ne 0 ]
  _out_has "--body accepts only '-'"
  [ ! -s "$ARGV_LOG" ]
}

@test "poke: no placement record refuses loudly and runs no terminal binary" {
  _install_fake_tmux
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -ne 0 ]
  _out_has "no placement record for 'testteam/alice'"
  [ ! -s "$ARGV_LOG" ]
}

# --- peek exit taxonomy: UNREACHABLE (10) vs pane-gone (12) vs unsupported (13) ---
# The value 13 must mean ONE thing to the template — a driver with no peek path at all
# (plain). A terminal that is momentarily unreachable (its CLI not on PATH) is 10;
# an answered-but-no-content failure (the pane is gone) is 12. Both peek-capable
# backends (tmux, herdr) must answer with the SAME taxonomy, so the two failures
# are tested on BOTH.

# A PATH with coreutils but deliberately NO tmux/herdr, so `command -v <cli>` in the
# driver fails and the UNREACHABLE arm (10) is reached. Built from scratch (not a
# filtered real PATH) so a stray tmux/herdr elsewhere cannot sneak back in.
_terminal_less_path() {
  local dir tool
  dir="$(mktemp -d)"
  for tool in bash sh dirname basename readlink uname sed grep awk cat tr \
              mktemp rm cp mv mkdir printf head tail wc sort cut date id sqlite3; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$dir/$tool" 2>/dev/null || true
    fi
  done
  printf '%s' "$dir"
}

# tmux whose capture-pane FAILS (the pane is gone), erroring to stderr.
_install_fake_tmux_gone() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$1" in
  capture-pane) echo "can't find pane: %5" >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"; export PATH="$FAKEBIN:$PATH"
}

# herdr whose `pane read` FAILS, writing its error JSON to STDOUT (herdr's real
# failure shape) and exiting non-zero.
_install_fake_herdr_gone() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf '{"error":{"code":"pane_not_found","pane":"%s"}}\n' "\$3"
  exit 1
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

@test "peek taxonomy: tmux NOT on PATH -> 10 (unreachable), not 13 (plain-unsupported)" {
  _write_record "tmux:%5"
  local hp; hp="$(_terminal_less_path)"
  run env PATH="$hp" bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 10 ]
  _out_has "tmux: not on PATH"
}

@test "peek taxonomy: tmux capture-pane fails (pane gone) -> 12, not 13" {
  _install_fake_tmux_gone
  _write_record "tmux:%5"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 12 ]
  _out_has "could not capture pane '%5'"
}

@test "peek taxonomy: herdr NOT on PATH -> 10 (unreachable), not 13" {
  _write_record "herdr:w1:p4"
  local hp; hp="$(_terminal_less_path)"
  run env PATH="$hp" HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 10 ]
  _out_has "herdr: not on PATH"
}

@test "peek taxonomy: herdr pane read fails -> 12, and its error JSON is NOT on stdout" {
  _install_fake_herdr_gone
  _write_record "herdr:w1:p4"
  local outf errf rc=0; outf="$TEST_SKILL_DIR/o"; errf="$TEST_SKILL_DIR/e"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>"$errf" || rc=$?
  [ "$rc" -eq 12 ]
  # the failure body is a diagnostic (stderr), never the caller's pane content
  [ ! -s "$outf" ]
  grep -q "pane_not_found" "$errf"
  grep -q "could not read pane 'w1:p4'" "$errf"
}

# --- peek READ contract: content reaches stdout VERBATIM --------------
# herdr's content is captured to a temp file and cat'd, NOT round-tripped through a
# command substitution (which strips every trailing newline) + printf '%s\n' (which
# invents exactly one back). Assert the BYTES, since `run`/$output would itself hide
# a trailing-newline change.

_install_fake_herdr_catfile() {
  cat > "$FAKEBIN/herdr" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = pane ] && [ "$2" = read ]; then
  cat "$HERDR_CONTENT_FILE"
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

@test "peek verbatim: EMPTY pane content stays empty (0 bytes), not a lone newline" {
  _install_fake_herdr_catfile
  export HERDR_CONTENT_FILE="$TEST_SKILL_DIR/content"
  printf '' > "$HERDR_CONTENT_FILE"
  _write_record "herdr:w1:p4"
  local outf; outf="$TEST_SKILL_DIR/o"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>/dev/null; local rc=$?
  [ "$rc" -eq 0 ]
  [ "$(wc -c < "$outf")" -eq 0 ]
}

@test "peek verbatim: content with NO final newline is not given one" {
  _install_fake_herdr_catfile
  export HERDR_CONTENT_FILE="$TEST_SKILL_DIR/content"
  printf 'abc' > "$HERDR_CONTENT_FILE"    # 3 bytes, no newline
  _write_record "herdr:w1:p4"
  local outf; outf="$TEST_SKILL_DIR/o"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>/dev/null
  [ "$(wc -c < "$outf")" -eq 3 ]
  cmp -s "$HERDR_CONTENT_FILE" "$outf"
}

@test "peek verbatim: content with MULTIPLE final newlines keeps all of them" {
  _install_fake_herdr_catfile
  export HERDR_CONTENT_FILE="$TEST_SKILL_DIR/content"
  printf 'abc\n\n\n' > "$HERDR_CONTENT_FILE"    # 6 bytes, three trailing newlines
  _write_record "herdr:w1:p4"
  local outf; outf="$TEST_SKILL_DIR/o"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>/dev/null
  [ "$(wc -c < "$outf")" -eq 6 ]
  cmp -s "$HERDR_CONTENT_FILE" "$outf"
}

# --- caller guard: an unresolvable ref must REACH its contract, not die silent ---
# peek.sh/poke.sh run under `set -e`; a bare `VAR="$(ref-parser ...)"` would take the
# shell down AT the assignment (the parser fails closed on a corrupt/unknown ref),
# so the "did not resolve" die below was unreachable. watch.sh must give the same
# ref its own logged branch rather than a misleading "belongs to someone else".

@test "peek: a corrupt ref REACHES the resolve die (not a silent set -e exit)" {
  _install_fake_tmux
  _write_record "bogus:xyz"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -ne 0 ]
  _out_has "did not resolve to a terminal and pane id (ref: 'bogus:xyz')"
  [ ! -s "$ARGV_LOG" ]    # never reached a terminal binary
}

@test "poke: a corrupt ref REACHES the resolve die (not a silent set -e exit)" {
  _install_fake_tmux
  _write_record "tmux:%9;kill"
  run bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -ne 0 ]
  _out_has "did not resolve to a terminal and pane id (ref: 'tmux:%9;kill')"
  [ ! -s "$ARGV_LOG" ]
}

# --- poke exit taxonomy: UNREACHABLE (10) vs no-live-agent / pane-gone (12) vs
#     unsupported (13) --------------------------------------------------------
# The same 13-conflation caught in peek was still in poke: a herdr pane
# whose agent has EXITED returned 13, which the template reads as plain's permanent
# "no addressable pane". poke now uses the SAME taxonomy as peek across both backends.
# This also makes the peek/poke asymmetry concrete: peek reads a pane with no live
# agent, poke needs a running agent, so poke has a "no one to receive" (12) that peek
# does not.

# herdr whose `agent prompt` FAILS (pane exists, no live agent to receive).
_install_fake_herdr_poke_fails() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = agent ] && [ "\$2" = prompt ]; then echo "no live agent in pane" >&2; exit 1; fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

# tmux whose send-keys FAILS (the pane is gone).
_install_fake_tmux_poke_fails() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$1" in send-keys) echo "can't find pane: %5" >&2; exit 1 ;; esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"; export PATH="$FAKEBIN:$PATH"
}

@test "poke taxonomy: herdr NOT on PATH -> 10 (unreachable), not 13" {
  _write_record "herdr:w1:p4"
  local hp; hp="$(_terminal_less_path)"
  run env PATH="$hp" HERDR_ENV=1 bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -eq 10 ]
  _out_has "herdr: not on PATH"
}

@test "poke taxonomy: herdr pane has no live agent -> 12, not 13 (peek/poke asymmetry)" {
  _install_fake_herdr_poke_fails
  _write_record "herdr:w1:p4"
  run env HERDR_ENV=1 bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -eq 12 ]
  _out_has "no live agent to receive"
  _out_has "poke needs a running agent"
}

@test "poke taxonomy: tmux NOT on PATH -> 10 (unreachable), not 13" {
  _write_record "tmux:%5"
  local hp; hp="$(_terminal_less_path)"
  run env PATH="$hp" bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -eq 10 ]
  _out_has "tmux: not on PATH"
}

@test "poke taxonomy: tmux send-keys fails (pane gone) -> 12, not 13" {
  _install_fake_tmux_poke_fails
  _write_record "tmux:%5"
  run bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -eq 12 ]
  _out_has "could not send to pane '%5'"
}

# --- poke entry: on `unsupported` (13) the driver's guidance is the LAST line ----
# For plain, the driver says "not a dead end — the type template says which native
# channel"; poke.sh must not cover that with a generic "could not poke", which would be
# the last line the operator reads. Only 13 (unsupported) suppresses the entry line;
# a real delivery failure (12) still gets it.

@test "poke entry: plain unsupported (13) keeps the driver's native-channel guidance as the last word" {
  _write_record "plain:-"
  run bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -eq 13 ]
  _out_has "native channel"
  # the generic entry line must NOT be added on top of the driver's guidance
  refute _out_has "could not poke"
}

@test "poke entry: a real delivery failure (12) DOES get the entry's summary line" {
  _install_fake_herdr_poke_fails
  _write_record "herdr:w1:p4"
  run env HERDR_ENV=1 bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -eq 12 ]
  _out_has "could not poke 'testteam/alice'"
}

# --- arrange ---------------------------------------------------------------

_install_fake_tmux_arrange() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = list-panes ]; then printf '%s\n' "\$TMUX_LAYOUT"; fi
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"; export PATH="$FAKEBIN:$PATH"
}

@test "arrange: a missing source record remains the final reason" {
  _write_named_record bob 'tmux:%2'
  run bash "$SCRIPTS/arrange.sh" testteam alice place_below bob
  [ "$status" -ne 0 ]
  [ "$output" = "arrange: no placement record for 'testteam/alice'" ]
  refute _out_has "terminal '' cannot arrange"
}

@test "arrange: public identity join rejects different recorded terminals" {
  _write_named_record alice 'tmux:%1'
  _write_named_record bob 'herdr:wA:p2'
  run bash "$SCRIPTS/arrange.sh" testteam alice place_below bob
  [ "$status" -ne 0 ]
  _out_has "members are in different terminals"
}

@test "arrange: public entry preserves unchanged and moved from the driver" {
  _install_fake_tmux_arrange
  _write_named_record alice 'tmux:%1'
  _write_named_record bob 'tmux:%2'
  export TMUX_LAYOUT=$'%1|@7|11|0|80|10\n%2|@7|0|0|80|10'
  run bash "$SCRIPTS/arrange.sh" testteam alice place_below bob
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  export TMUX_LAYOUT=$'%1|@7|0|0|40|10\n%2|@7|12|0|40|10'
  run bash "$SCRIPTS/arrange.sh" testteam alice place_below bob
  [ "$status" -eq 0 ]
  [ "$output" = moved ]
}
