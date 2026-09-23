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

# #1321: poke's own input-box check now peeks before typing. These delivery
# tests are about the SUBMISSION mechanism (argv shape, body escaping), not
# about the box-emptiness check itself (that has its own dedicated test
# below) -- so their fake terminals must present a genuinely empty Claude
# Code box (the same measured shape: a rule line, "❯", a rule line), or the
# check correctly refuses generic placeholder text it was never designed to
# read. Loosening the check to accept arbitrary fake output would be the
# wrong fix (review, #1321) -- these fixtures are shaped to the real box
# instead.
_install_fake_tmux_empty_box() {
  local rule
  rule="$(printf '─%.0s' $(seq 1 60))"
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf '\''tmux'\''; for a in "$@"; do printf '\'' [%%s]'\'' "$a"; done; printf '\''\\n'\''; } >> "%s"\n' "$ARGV_LOG"
    printf 'case "$1" in\n'
    printf "  capture-pane) printf '%%s\\\\n' '%s testteam-alice ─' '❯' '%s' ;;\n" "$rule" "$rule"
    printf 'esac\n'
    printf 'exit 0\n'
  } > "$FAKEBIN/tmux"
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

_install_fake_herdr_empty_box() {
  local rule
  rule="$(printf '─%.0s' $(seq 1 60))"
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf '\''herdr'\''; for a in "$@"; do printf '\'' [%%s]'\'' "$a"; done; printf '\''\\n'\''; } >> "%s"\n' "$ARGV_LOG"
    printf 'if [ "$1" = pane ] && [ "$2" = read ]; then\n'
    printf "  printf '%%s\\\\n' '%s testteam-alice ─' '❯' '%s'\n" "$rule" "$rule"
    printf 'fi\n'
    printf 'exit 0\n'
  } > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

# #1384 (herdr only): a real, stalled draft with NOBODY focused on the pane
# -- `pane list` answers focused=false unconditionally (one pane, asked
# about twice: once before clearing, once right after -- #1384's own two
# re-reads), and `pane read --format ansi` answers STATEFULLY, by counting
# this SAME fake's own prior calls in $ARGV_LOG (review: the first version
# of this fixture answered the identical draft no matter what happened,
# which could not tell a clear that actually worked apart from one that
# did not, or a restore that landed apart from one that failed):
#   - no `agent send-keys` (clear) logged yet -> the real, non-dim draft
#     ("hello draft"), so `agmsg_input_box_is_real_draft` reads it as real
#     on the very first snapshot.
#   - a clear IS logged, and $FAKEBIN/.clear_empties exists -> empty box.
#   - a clear is logged but $FAKEBIN/.clear_empties does NOT exist -> still
#     the draft (simulates a clear that sent keys but did not actually
#     empty the box -- too long a draft, a key that did not land).
#   - a `pane send-text` (restore) is ALSO logged -> the draft again
#     (retyped successfully), UNLESS $FAKEBIN/.restore_fails exists, in
#     which case `pane send-text` itself exits 1 and the box stays empty.
# Each test controls behavior by touching/removing those two files before
# each `run`, and truncating $ARGV_LOG between scenarios so the call
# counts this fake reads are scoped to that one scenario.
_install_fake_herdr_real_draft_unfocused() {
  local rule
  rule="$(printf '─%.0s' $(seq 1 60))"
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf '\''herdr'\''; for a in "$@"; do printf '\'' [%%s]'\'' "$a"; done; printf '\''\\n'\''; } >> "%s"\n' "$ARGV_LOG"
    printf 'if [ "$1" = pane ] && [ "$2" = read ]; then\n'
    printf '  sends=$(grep -c '\''^herdr \\[pane\\] \\[send-text\\]'\'' "%s" 2>/dev/null)\n' "$ARGV_LOG"
    printf '  clears=$(grep -c '\''^herdr \\[agent\\] \\[send-keys\\]'\'' "%s" 2>/dev/null)\n' "$ARGV_LOG"
    printf '  if [ "$sends" -gt 0 ]; then\n'
    printf '    if [ -f "%s/.restore_fails" ]; then draft=0; else draft=1; fi\n' "$FAKEBIN"
    printf '  elif [ "$clears" -gt 0 ]; then\n'
    printf '    if [ -f "%s/.clear_empties" ]; then draft=0; else draft=1; fi\n' "$FAKEBIN"
    printf '  else\n'
    printf '    draft=1\n'
    printf '  fi\n'
    printf '  if [ "$draft" = 1 ]; then\n'
    printf "    printf '%%s\\\\n' '%s testteam-alice ─' '❯ hello draft' '%s'\n" "$rule" "$rule"
    printf '  else\n'
    printf "    printf '%%s\\\\n' '%s' '❯' '%s'\n" "$rule" "$rule"
    printf '  fi\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [ "$1" = pane ] && [ "$2" = send-text ]; then\n'
    printf '  [ -f "%s/.restore_fails" ] && exit 1\n' "$FAKEBIN"
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [ "$1" = pane ] && [ "$2" = list ]; then\n'
    printf '  if [ -f "%s/.focus_on_second_check" ]; then\n' "$FAKEBIN"
    printf '    lists=$(grep -c '\''^herdr \\[pane\\] \\[list\\]'\'' "%s" 2>/dev/null)\n' "$ARGV_LOG"
    printf '    if [ "$lists" -ge 2 ]; then\n'
    printf '      printf '\''{"result":{"panes":[{"pane_id":"wC:p4","focused":true}]}}\\n'\''\n'
    printf '      exit 0\n'
    printf '    fi\n'
    printf '  fi\n'
    printf '  printf '\''{"result":{"panes":[{"pane_id":"wC:p4","focused":false}]}}\\n'\''\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'exit 0\n'
  } > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

_install_fake_osascript() {
  cat > "$FAKEBIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
  cat > "$FAKEBIN/osascript" <<EOF
#!/usr/bin/env bash
{ printf 'osascript'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$2" in
  probe) printf 'supported\n' ;;
  peek) printf 'plain visible text\n' ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/uname" "$FAKEBIN/osascript"
  export PATH="$FAKEBIN:$PATH"
}

_write_sweep_config() {
  local project="$1"
  mkdir -p "$SKILL_DIR/teams/testteam"
  cat > "$SKILL_DIR/teams/testteam/config.json" <<EOF
{"agents":{
  "approval-seat":{"registrations":[{"type":"claude-code","project":"$project"}]},
  "working-seat":{"registrations":[{"type":"codex","project":"$project"}]},
  "idle-seat":{"registrations":[{"type":"codex","project":"$project"}]},
  "gone-seat":{"registrations":[{"type":"codex","project":"$project"}]},
  "unplaced":{"registrations":[{"type":"codex","project":"$project"}]},
  "other-seat":{"registrations":[{"type":"codex","project":"$SKILL_DIR/other"}]},
  "remote-seat":{"registrations":[]}
}}
EOF
  _write_named_record approval-seat 'tmux:%1'
  _write_named_record working-seat 'tmux:%2'
  _write_named_record idle-seat 'tmux:%3'
  _write_named_record gone-seat 'tmux:%4'
  _write_named_record other-seat 'tmux:%5'
}

_install_fake_tmux_sweep() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case " \$* " in
  *' %1 '*) printf 'Do you want to proceed\n'; printf '%080000d\n' 0; printf 'choice detail below prompt\n' ;;
  *' %2 '*) printf 'Running command\nlast working line\n' ;;
  *' %3 '*) printf 'ordinary output\nquiet prompt\n' ;;
  *' %4 '*) printf "can't find pane: %%4\n" >&2; exit 1 ;;
  *' %5 '*) printf 'must not be read\n' ;;
esac
EOF
  chmod +x "$FAKEBIN/tmux"
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

@test "peek: herdr record forwards the requested scrollback depth (#1121)" {
  _install_fake_herdr
  _write_record "herdr:w1:p5"
  run bash "$SCRIPTS/peek.sh" testteam alice --lines 40
  [ "$status" -eq 0 ]
  _out_has "herdr visible text"
  grep -q '^herdr \[pane\] \[read\] \[w1:p5\] \[--source\] \[recent\] \[--lines\] \[40\]$' "$ARGV_LOG"
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

@test "peek: a plain record with no live actas lock falls through to the driver's own unsupported message" {
  # #1229 gave peek an agent-native substitute for a bare plain:- claude-code
  # target (its own session transcript) -- but only when this session's OWN
  # actas lock for the target resolves to a live owner. This fixture never
  # ran actas, so no lock exists, the substitute is unavailable, and peek
  # falls through to the driver's plain "unsupported" message, which (unlike
  # poke's) has never carried native-channel wording.
  _write_record "plain:-"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 13 ]
  _out_has "unsupported: plain terminal has no addressable pane"
  [ "$(printf '%s\n' "$output" | grep -c 'native channel' || true)" -eq 0 ]
}

@test "peek: a bare plain:- claude-code target with a live actas lock reads its own session transcript instead (#1229)" {
  _write_record "plain:-"
  local owner_bare="owner-sid" owner="owner-sid.$$"
  mkdir -p "$SKILL_DIR/run"
  printf '%s\n' "$owner" > "$SKILL_DIR/run/cc-instance.$$"
  bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; printf %s "$1" > "$(actas_lock_path testteam alice)"' _ "$owner"
  local munged="-tmp-project-a"
  mkdir -p "$HOME/.claude/projects/$munged"
  printf '{"type":"user","text":"one"}\n{"type":"assistant","text":"two"}\n' \
    > "$HOME/.claude/projects/$munged/$owner_bare.jsonl"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 0 ]
  _out_has "AGMSG-NATIVE-RECORD: claude-code session transcript"
  _out_has '"text":"two"'
}

@test "peek: an emulator-qualified plain record reads through its adapter" {
  _install_fake_osascript
  _write_record "plain:iterm:/dev/ttys040"
  run bash "$SCRIPTS/peek.sh" testteam alice
  [ "$status" -eq 0 ]
  _out_has "plain visible text"
  [ "$(grep -c ' \[probe\] \[/dev/ttys040\]' "$ARGV_LOG")" -eq 1 ]
  [ "$(grep -c ' \[peek\] \[/dev/ttys040\]' "$ARGV_LOG")" -eq 1 ]
}

@test "peek: --lines rejects a non-number instead of passing it through" {
  _install_fake_tmux
  _write_record "tmux:%5"
  run bash "$SCRIPTS/peek.sh" testteam alice --lines many
  [ "$status" -ne 0 ]
  _out_has "--lines must be a whole number"
  [ ! -s "$ARGV_LOG" ]
}

@test "peek team: classifies the full screen approval before working before idle" {
  _install_fake_tmux_sweep
  local project="$TEST_SKILL_DIR/project-a"
  mkdir -p "$project"
  _write_sweep_config "$project"
  run env AGMSG_RESOLVE_PROJECT=0 bash -c 'cd "$1" && bash "$2" testteam' _ "$project" "$SCRIPTS/peek.sh"
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -Eq '^approval-se +%1 +approval +choice detail below prompt *$' || return 1
  printf '%s\n' "$output" | grep -Eq '^working-sea +%2 +working +last working line *$' || return 1
  printf '%s\n' "$output" | grep -Eq '^idle-seat +%3 +idle +quiet prompt *$' || return 1
}

@test "peek team: states remote and other-project exclusions and never reads them" {
  _install_fake_tmux_sweep
  local project="$TEST_SKILL_DIR/project-a"
  mkdir -p "$project"
  _write_sweep_config "$project"
  run env AGMSG_RESOLVE_PROJECT=0 bash -c 'cd "$1" && bash "$2" testteam' _ "$project" "$SCRIPTS/peek.sh"
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -Eq '^other-seat +- +excluded:project ' || return 1
  printf '%s\n' "$output" | grep -Eq '^remote-seat +- +excluded:remote +no_local_registration *$' || return 1
  printf '%s\n' "$output" | grep -Eq '^unplaced +- +no_record +no_placement_record *$' || return 1
  [ "$(grep -c '\[%5\]' "$ARGV_LOG" || true)" -eq 0 ] || return 1
}

@test "peek team: preserves a member read failure as its driver rc" {
  _install_fake_tmux_sweep
  local project="$TEST_SKILL_DIR/project-a"
  mkdir -p "$project"
  _write_sweep_config "$project"
  run env AGMSG_RESOLVE_PROJECT=0 bash -c 'cd "$1" && bash "$2" testteam' _ "$project" "$SCRIPTS/peek.sh"
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -Eq "^gone-seat +%4 +read_rc_12 +tmux: could not capture pane '%4'" || return 1
}

@test "peek team: a roster query failure is rc 10, never an empty team" {
  mkdir -p "$SKILL_DIR/teams/testteam"
  printf '%s\n' '{not json' > "$SKILL_DIR/teams/testteam/config.json"
  run bash "$SCRIPTS/peek.sh" testteam
  [ "$status" -eq 10 ] || return 1
  _out_has "team roster query failed (rc 1)" || return 1
  [ "$(printf '%s\n' "$output" | grep -c '^MEMBER ' || true)" -eq 0 ] || return 1
}

# --- poke ----------------------------------------------------------------

@test "poke: tmux text and Enter arrive in SEPARATE bursts, arrow in the second (#619)" {
  _install_fake_tmux_empty_box
  _write_record "tmux:%5"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello there"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via tmux"
  # Exactly FOUR tmux invocations: the #1322 two-snapshot input-box check
  # (capture-pane, capture-pane), then the #619 two-burst submission. A
  # merged single send-keys burst (the #619 regression), a missing peek, or
  # a fifth stray call all change this count.
  [ "$(grep -c '^tmux ' "$ARGV_LOG")" -eq 4 ]
  local peek1 peek2 first second
  peek1="$(sed -n '1p' "$ARGV_LOG")"
  peek2="$(sed -n '2p' "$ARGV_LOG")"
  first="$(sed -n '3p' "$ARGV_LOG")"
  second="$(sed -n '4p' "$ARGV_LOG")"
  # -e, not plain: tmux now offers terminal_peek_styled (#1389), so poke.sh's
  # own STYLED dispatch (declare -F terminal_peek_styled) picks it for BOTH
  # snapshots here, the same as it already did for herdr -- tmux pokes get
  # the #1322 round-2 real-draft protection too, not just the round-1
  # two-snapshot check this test originally pinned before that existed.
  [ "$peek1" = 'tmux [capture-pane] [-e] [-p] [-t] [%5]' ]
  [ "$peek2" = 'tmux [capture-pane] [-e] [-p] [-t] [%5]' ]
  # Burst 1 is the literal text and carries NO Enter — the equality is what
  # goes red if the Enter ever rejoins the text burst (an Enter appended to
  # this line makes the string differ).
  [ "$first" = 'tmux [send-keys] [-l] [-t] [%5] [--] [hello there]' ]
  # Burst 2 ends paste classification with an arrow key, THEN submits.
  [ "$second" = 'tmux [send-keys] [-t] [%5] [Right] [Enter]' ]
}

@test "poke: herdr submits in ONE call (agent prompt) with no Enter dance" {
  _install_fake_herdr_empty_box
  _write_record "herdr:wC:p4"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via herdr"
  # Three herdr invocations: the #1322 two-snapshot input-box check (pane
  # read, pane read -- styled, since terminal_peek_styled exists for herdr),
  # then the single agent-prompt submission call.
  [ "$(grep -c '^herdr ' "$ARGV_LOG")" -eq 3 ]
  [ "$(grep -c '^herdr \[pane\] \[read\] \[wC:p4\] \[--source\] \[visible\] \[--format\] \[ansi\]$' "$ARGV_LOG")" -eq 2 ]
  # The inner ':' of the herdr pane id must survive the record round-trip.
  grep -q '^herdr \[agent\] \[prompt\] \[wC:p4\] \[hello\]$' "$ARGV_LOG"
  # No synthesized keystrokes: submission is agent prompt's own.
  [ "$(grep -ci 'enter' "$ARGV_LOG" || true)" -eq 0 ]
}

@test "poke: herdr, unfocused real draft -- clears, pokes, then restores the draft, in that order (#1384)" {
  _install_fake_herdr_real_draft_unfocused
  _write_record "herdr:wC:p4"

  # --- 1) happy path: clear actually empties the box, restore actually
  # lands -- clears, pokes, then restores, in that order, and the saved
  # draft file is removed once the restore verifies byte-for-byte.
  : > "$FAKEBIN/.clear_empties"
  rm -f "$FAKEBIN/.restore_fails"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via herdr"

  local clear_line poke_line restore_line
  clear_line="$(grep -n '^herdr \[agent\] \[send-keys\] \[wC:p4\]' "$ARGV_LOG" | head -1 | cut -d: -f1)"
  poke_line="$(grep -n '^herdr \[agent\] \[prompt\] \[wC:p4\] \[hello\]$' "$ARGV_LOG" | head -1 | cut -d: -f1)"
  restore_line="$(grep -n '^herdr \[pane\] \[send-text\] \[wC:p4\] \[hello draft\]$' "$ARGV_LOG" | head -1 | cut -d: -f1)"
  [ -n "$clear_line" ]
  [ -n "$poke_line" ]
  [ -n "$restore_line" ]
  [ "$clear_line" -lt "$poke_line" ]
  [ "$poke_line" -lt "$restore_line" ]
  # The draft was saved under run/ with 600, then removed once the restore
  # verified byte-for-byte against the original -- a removal test without a
  # keep-set proves nothing, but here the survive/remove question is the
  # test itself: none should remain after a clean run.
  [ -z "$(find "$TEST_SKILL_DIR/run" -name 'poke-draft.*' 2>/dev/null)" ]

  # --- 2) clear sends the keys but the box reads back with
  # the draft STILL there (too long a draft, a key that did not land) --
  # must not type the poke's own text over it. No `agent prompt` call may
  # appear at all, and the saved draft must survive, not be silently
  # dropped as though nothing had been saved.
  : > "$ARGV_LOG"
  rm -f "$FAKEBIN/.clear_empties"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -ne 0 ]
  refute grep -q '^herdr \[agent\] \[prompt\]' "$ARGV_LOG"
  [ -n "$(find "$TEST_SKILL_DIR/run" -name 'poke-draft.*' 2>/dev/null)" ]
  find "$TEST_SKILL_DIR/run" -name 'poke-draft.*' -delete

  # --- 3) clear DOES empty the box and the poke DOES land,
  # but the retype back fails (`pane send-text` itself errors) -- the
  # message still delivered (this is not a poke failure), but the saved
  # draft file must NOT be deleted just because terminal_input_type was
  # merely CALLED; only a verified, matching restore may remove it.
  : > "$ARGV_LOG"
  : > "$FAKEBIN/.clear_empties"
  : > "$FAKEBIN/.restore_fails"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 0 ]
  grep -q '^herdr \[agent\] \[prompt\] \[wC:p4\] \[hello\]$' "$ARGV_LOG"
  [ -n "$(find "$TEST_SKILL_DIR/run" -name 'poke-draft.*' 2>/dev/null)" ]
  find "$TEST_SKILL_DIR/run" -name 'poke-draft.*' -delete

  # --- 4) (review, round 2) the FIRST focus check (before
  # recovery starts) reads unfocused, clearing sends the keys but the draft
  # is STILL there afterward, and the SECOND focus check (right after
  # clearing) now reads focused -- someone arrived mid-clear. The abort
  # branch must confirm the box is empty BEFORE ever retyping the draft
  # back; here it never is, so `pane send-text` must not be called at all,
  # not even the restore -- a partial clear plus a blind restore would
  # append the whole draft on top of whatever the clear left behind.
  : > "$ARGV_LOG"
  rm -f "$FAKEBIN/.clear_empties" "$FAKEBIN/.restore_fails"
  : > "$FAKEBIN/.focus_on_second_check"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -ne 0 ]
  refute grep -q '^herdr \[pane\] \[send-text\]' "$ARGV_LOG"
  refute grep -q '^herdr \[agent\] \[prompt\]' "$ARGV_LOG"
  [ -n "$(find "$TEST_SKILL_DIR/run" -name 'poke-draft.*' 2>/dev/null)" ]
  find "$TEST_SKILL_DIR/run" -name 'poke-draft.*' -delete
  rm -f "$FAKEBIN/.focus_on_second_check"
}

@test "poke: a plain record is unsupported as a TERMINAL answer, and points at the type's native channel (peek deliberately does not — no CLI read path)" {
  _write_record "plain:-"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 13 ]
  _out_has "unsupported: plain terminal has no addressable pane"
  _out_has "agent type may offer a native channel"
}

@test "poke: an emulator-qualified plain record submits through its adapter" {
  _install_fake_osascript
  _write_record "plain:terminal:/dev/ttys039"
  run bash "$SCRIPTS/poke.sh" testteam alice "one prompt"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via plain"
  [ "$(grep -c ' \[probe\] \[/dev/ttys039\]' "$ARGV_LOG")" -eq 1 ]
  grep -q ' \[poke\] \[/dev/ttys039\] \[one prompt\]' "$ARGV_LOG"
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
  _install_fake_herdr_empty_box
  _write_record "herdr:wC:p4"
  # Backtick, $( ), quotes, $VAR — none of it may execute or change: the body
  # never crosses the caller's shell. Equality against the argv line is the
  # assertion; a vanished span (what #507 did to send bodies) changes the line.
  printf '%s' 'check `whoami` and $(hostname) plus "quotes" and $HOME here' > "$TEST_SKILL_DIR/body.txt"
  run bash "$SCRIPTS/poke.sh" testteam alice --body-file "$TEST_SKILL_DIR/body.txt"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via herdr"
  # Lines 1-2 are the #1322 two-snapshot input-box check; the submission is line 3.
  [ "$(sed -n '3p' "$ARGV_LOG")" = 'herdr [agent] [prompt] [wC:p4] [check `whoami` and $(hostname) plus "quotes" and $HOME here]' ]
  [ "$(grep -c '^herdr ' "$ARGV_LOG")" -eq 3 ]
}

@test "poke: --body - reads stdin; a missing file and an empty body refuse before any terminal runs" {
  _install_fake_tmux_empty_box
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
# filtered real PATH) so a stray tmux/herdr elsewhere cannot sneak back in. `paste`
# is here because poke.sh's #1229 plain fallback sources type-registry.sh (via
# detect-cli-type.sh), which needs it at source time -- a REAL dependency
# whoami.sh/identities.sh's callers already carry, not one this fixture should
# hide by omission.
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

# herdr whose `pane read` fails with a DIFFERENT error whose message merely
# mentions the word pane_not_found (#1169). A substring reader called this gone.
_install_fake_herdr_other_error_mentioning_gone() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf '{"error":{"code":"read_failed","message":"pane_not_found is not what happened; the read timed out","pane":"%s"}}\n' "\$3"
  exit 1
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

# herdr that says a pane is gone -- a DIFFERENT pane than the one asked for.
_install_fake_herdr_gone_other_pane() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf '{"error":{"code":"pane_not_found","pane":"w9:p9"}}\n'
  exit 1
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

@test "peek taxonomy: another error whose MESSAGE mentions pane_not_found is 11, not gone (#1169)" {
  _install_fake_herdr_other_error_mentioning_gone
  _write_record "herdr:w1:p4"
  local outf errf rc=0; outf="$TEST_SKILL_DIR/o"; errf="$TEST_SKILL_DIR/e"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>"$errf" || rc=$?
  [ "$rc" -eq 11 ]
  [ ! -s "$outf" ]
  grep -q "read_failed" "$errf"                       # the real body is forwarded
  refute grep -q "no longer exists" "$errf"           # and no absence is claimed
}

@test "peek taxonomy: a pane_not_found about a DIFFERENT pane is 11, and says which pane (#1169)" {
  _install_fake_herdr_gone_other_pane
  _write_record "herdr:w1:p4"
  local outf errf rc=0; outf="$TEST_SKILL_DIR/o"; errf="$TEST_SKILL_DIR/e"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>"$errf" || rc=$?
  [ "$rc" -eq 11 ]
  grep -q "pane 'w9:p9' does not exist -- a different pane" "$errf"
  refute grep -q "no longer exists" "$errf"
}

@test "peek taxonomy: a renamed error code is 11 with the body forwarded, never a silent gone (#1169)" {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
if [ "\$1" = pane ] && [ "\$2" = read ]; then printf '{"error":{"code":"PaneNotFound","pane":"%s"}}\n' "\$3"; exit 1; fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
  _write_record "herdr:w1:p4"
  local outf errf rc=0; outf="$TEST_SKILL_DIR/o"; errf="$TEST_SKILL_DIR/e"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>"$errf" || rc=$?
  [ "$rc" -eq 11 ]
  grep -q "PaneNotFound" "$errf"
  refute grep -q "no longer exists" "$errf"
}

# herdr whose `pane read` fails with an OS-level error on its REAL stderr — no
# JSON body at all, and no claim from herdr that the pane is gone. Modeled on
# the measured case (#1158): a sandbox that denies socket operations returns
# `PermissionDenied (Operation not permitted)` this way, not as pane_not_found.
_install_fake_herdr_denied() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = pane ] && [ "\$2" = read ]; then
  echo "PermissionDenied (Operation not permitted)" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

@test "peek taxonomy: herdr pane read fails with no absence claim -> 11, not 12 (#1158)" {
  _install_fake_herdr_denied
  _write_record "herdr:w1:p4"
  local outf errf rc=0; outf="$TEST_SKILL_DIR/o"; errf="$TEST_SKILL_DIR/e"
  HERDR_ENV=1 bash "$SCRIPTS/peek.sh" testteam alice >"$outf" 2>"$errf" || rc=$?
  [ "$rc" -eq 11 ]
  [ ! -s "$outf" ]
  # the real diagnostic is forwarded, not discarded by the old `2>/dev/null`
  grep -q "PermissionDenied" "$errf"
  grep -q "could not read pane 'w1:p4'" "$errf"
  # and the driver must not assert a cause it has not established
  # `! cmd` never fails a bats test unless it is the last statement (#670), so
  # both lines go through the refute helper; the second one only "worked" for
  # being last, and the next line added below it would have silenced it.
  refute grep -q "no longer exist" "$errf"
  refute grep -q "it may be" "$errf"
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
# `pane read` returns the real empty-input-box shape so the #1321 pre-check
# passes and the submission failure is what actually surfaces (an empty
# read is NOT itself proof of "no draft" -- see poke.sh's own comment on
# this -- so the fixture must show a genuinely empty box, not blank output).
_install_fake_herdr_poke_fails() {
  local rule
  rule="$(printf '─%.0s' $(seq 1 60))"
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf '\''herdr'\''; for a in "$@"; do printf '\'' [%%s]'\'' "$a"; done; printf '\''\\n'\''; } >> "%s"\n' "$ARGV_LOG"
    printf 'if [ "$1" = pane ] && [ "$2" = read ]; then\n'
    printf "  printf '%%s\\\\n' '%s testteam-alice ─' '❯' '%s'\n" "$rule" "$rule"
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'if [ "$1" = agent ] && [ "$2" = prompt ]; then echo "no live agent in pane" >&2; exit 1; fi\n'
    printf 'exit 0\n'
  } > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

# tmux whose send-keys FAILS (the pane is gone). `capture-pane` returns the
# real empty-input-box shape for the same reason as the herdr fixture above.
_install_fake_tmux_poke_fails() {
  local rule
  rule="$(printf '─%.0s' $(seq 1 60))"
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf '\''tmux'\''; for a in "$@"; do printf '\'' [%%s]'\'' "$a"; done; printf '\''\\n'\''; } >> "%s"\n' "$ARGV_LOG"
    printf 'case "$1" in\n'
    printf "  capture-pane) printf '%%s\\\\n' '%s testteam-alice ─' '❯' '%s' ;;\n" "$rule" "$rule"
    printf '  send-keys) echo "can'\''t find pane: %%5" >&2; exit 1 ;;\n'
    printf 'esac\n'
    printf 'exit 0\n'
  } > "$FAKEBIN/tmux"
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
  # the real diagnostic is forwarded now, not discarded by the old
  # `>/dev/null 2>&1` (#1158's sweep of the same file)
  _out_has "no live agent in pane"
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

# #1229: a bare plain:- claude-code target has no pane to type into or
# retry. When the CALLER is also claude-code, its own local session
# messaging (ListAgents/SendMessage) is a strictly better substitute than
# anything this script can do (no shell path to that channel exists, #1229
# review) -- so poke.sh names the route and refuses rather than silently
# falling back to something worse.
@test "poke: bare plain:- claude-code target + claude-code caller names ListAgents/SendMessage, never falls back to a message" {
  _write_record "plain:-"
  run env CLAUDE_CODE_SESSION_ID=caller-sid bash "$SCRIPTS/poke.sh" testteam alice "hi"
  [ "$status" -eq 13 ]
  _out_has "ListAgents"
  _out_has "SendMessage"
  _out_has "testteam-alice"
  refute _out_has "poked 'testteam/alice' via an agmsg message"
}

# Otherwise (here: the caller is not claude-code) poke.sh itself delivers the
# body as an ordinary agmsg message — the same store send.sh writes to —
# resolving 'from' the same way whoami.sh/identities.sh already do (this
# session's own (project, type) registration in the target's team). Widened
# (#1229 review) to also cover identities.sh returning SEVERAL matches for
# one (project, type) in the same team — this fleet's own real shape, many
# same-type seats sharing one project checkout — where 'from' must narrow to
# this session's own actas lock among the ambiguous candidates, or refuse.
@test "poke: bare plain:- target + non-claude-code caller delivers as an agmsg message from the caller's own identity, narrowed by actas lock when identities.sh alone is ambiguous" {
  _write_record "plain:-"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob codex "$PWD" >/dev/null
  bash "$SCRIPTS/join.sh" testteam carol codex "$PWD" >/dev/null
  # Two codex identities registered to this SAME project in testteam:
  # identities.sh alone cannot tell bob and carol apart.
  [ "$(bash "$SCRIPTS/identities.sh" "$PWD" codex | awk -F'\t' '$1=="testteam"' | grep -c .)" -eq 2 ]
  # This session's own actas lock is bob's; carol has one too, but owned by
  # a DIFFERENT session -- if the owner match were dropped, both would count
  # and this would refuse instead of picking bob.
  bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; printf %s "$1" > "$(actas_lock_path testteam bob)"' _ caller-thread
  bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; printf %s "$1" > "$(actas_lock_path testteam carol)"' _ someone-elses-thread
  run env CODEX_THREAD_ID=caller-thread bash "$SCRIPTS/poke.sh" testteam alice "hi from bob"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via an agmsg message from 'bob'"
  run bash "$SCRIPTS/history.sh" testteam alice
  _out_has "bob"
  _out_has "hi from bob"
  # And the SAME ambiguity with no actas lock narrowing it (carol un-owned,
  # bob's lock removed) refuses rather than guessing -- one test, both
  # outcomes of the same setup.
  run bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; rm -f "$(actas_lock_path testteam bob)"'
  run env CODEX_THREAD_ID=caller-thread bash "$SCRIPTS/poke.sh" testteam alice "hi again"
  [ "$status" -eq 13 ]
  _out_has "not be resolved to exactly one"
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
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  _write_named_record alice 'tmux:%1'
  run bash "$SCRIPTS/arrange.sh" testteam alice place_below herdr:wA:p2
  [ "$status" -ne 0 ]
  _out_has "source and anchor are in different terminals"
}

@test "arrange: public entry preserves unchanged and moved from the driver" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  _install_fake_tmux_arrange
  _write_named_record alice 'tmux:%1'
  export TMUX_LAYOUT=$'%1|@7|11|0|80|10\n%2|@7|0|0|80|10'
  run bash "$SCRIPTS/arrange.sh" testteam alice place_below tmux:%2
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  export TMUX_LAYOUT=$'%1|@7|0|0|40|10\n%2|@7|12|0|40|10'
  run bash "$SCRIPTS/arrange.sh" testteam alice place_below tmux:%2
  [ "$status" -eq 0 ]
  [ "$output" = moved ]
}

@test "arrange: source must still be a roster member, anchor need not be one" {
  _install_fake_tmux_arrange
  _write_named_record alice 'tmux:%1'
  export TMUX_LAYOUT=$'%1|@7|0|0|40|10\n%2|@7|12|0|40|10'
  run bash "$SCRIPTS/arrange.sh" testteam alice swap tmux:%2
  [ "$status" -ne 0 ]
  [ "$output" = "arrange: source 'testteam/alice' is not a registered member" ]
}

@test "arrange: an invalid anchor reference is distinct from terminal and layout failures" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  _write_named_record alice 'tmux:%1'
  run bash "$SCRIPTS/arrange.sh" testteam alice swap tmux:not-a-pane
  [ "$status" -ne 0 ]
  [ "$output" = "arrange: anchor reference 'tmux:not-a-pane' did not resolve to a terminal and pane id" ]
}

@test "arrange: place intents reject the source pane as anchor before driver mutation" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  _install_fake_tmux_arrange
  _write_named_record alice 'tmux:%1'
  export TMUX_LAYOUT='%1|@7|0|0|40|10'
  local intent
  for intent in place_below place_right; do
    : > "$ARGV_LOG"
    run bash "$SCRIPTS/arrange.sh" testteam alice "$intent" tmux:%1
    [ "$status" -ne 0 ]
    [ "$output" = "arrange: source and anchor must be different panes" ]
    [ ! -s "$ARGV_LOG" ]
  done
}

@test "arrange: a terminal without arrange capability stays distinct from bad references" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  _write_named_record alice 'plain:-'
  run bash "$SCRIPTS/arrange.sh" testteam alice swap plain:-
  [ "$status" -ne 0 ]
  [ "$output" = "arrange: terminal 'plain' cannot arrange panes" ]
}

@test "arrange: swap accepts a non-member pane reference" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  _install_fake_tmux_arrange
  _write_named_record alice 'tmux:%1'
  export TMUX_LAYOUT=$'%1|@7|0|0|40|10\n%2|@7|0|41|40|10'
  run bash "$SCRIPTS/arrange.sh" testteam alice swap tmux:%2
  [ "$status" -eq 0 ]
  [ "$output" = moved ]
  grep -q '^tmux \[swap-pane\] \[-s\] \[%1\] \[-t\] \[%2\]$' "$ARGV_LOG"
}

@test "arrange: legacy bare tmux anchor references remain accepted" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  _install_fake_tmux_arrange
  _write_named_record alice 'tmux:%1'
  export TMUX_LAYOUT=$'%1|@7|0|0|40|10\n%2|@7|0|41|40|10'
  run bash "$SCRIPTS/arrange.sh" testteam alice swap %2
  [ "$status" -eq 0 ]
  [ "$output" = moved ]
  grep -q '^tmux \[swap-pane\] \[-s\] \[%1\] \[-t\] \[%2\]$' "$ARGV_LOG"
}

# #1321/#1322: poke.sh must not type over someone actively typing, but must
# NOT refuse just because the box holds non-blank text that isn't a draft at
# all (Claude Code's own candidate/suggestion text, or Codex's "Ask Codex to
# do anything" placeholder — #1322). The check now takes two snapshots ~1s
# apart and refuses only when they differ, so every fixture below must
# answer TWO "pane read" calls per poke.sh attempt, not one.
#
# _install_fake_herdr_screen_sequence <screen1> [<screen2> ...]: each "pane
# read" call consumes the next screen in order; a call past the last one
# given keeps repeating the LAST screen (so a caller that wants "both reads
# identical" only has to pass one). State lives in a file, not a subshell
# variable, since each herdr invocation below is a genuinely separate
# process.
_install_fake_herdr_screen_sequence() {
  local state="$BATS_TEST_TMPDIR/screen-seq-idx" i=0 s
  printf '0' > "$state"
  for s in "$@"; do
    printf '%s' "$s" > "$BATS_TEST_TMPDIR/screen-seq-$i.txt"
    i=$((i + 1))
  done
  local last=$((i - 1))
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf '\''herdr'\''; for a in "$@"; do printf '\'' [%%s]'\'' "$a"; done; printf '\''\\n'\''; } >> "%s"\n' "$ARGV_LOG"
    printf 'if [ "$1" = pane ] && [ "$2" = read ]; then\n'
    printf '  idx="$(cat "%s")"\n' "$state"
    printf '  [ "$idx" -le %d ] || idx=%d\n' "$last" "$last"
    printf '  cat "%s/screen-seq-$idx.txt"\n' "$BATS_TEST_TMPDIR"
    printf '  printf "%%s" "$((idx + 1))" > "%s"\n' "$state"
    printf 'fi\n'
    printf 'exit 0\n'
  } > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

_write_codex_record() {
  local name="$1" ref="$2" path
  path="$(bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path testteam "$1"' _ "$name")"
  [ -n "$path" ]
  printf '%s\t/tmp/project-a\tcodex' "$ref" > "$path"
}

# Builds one boxed-shape (Claude Code) screen: top rule + label, the marker
# line's own <tail>, bottom rule. Mirrors a real pane's shape (measured live
# 2026-09-18). RULE60 is built, not hand-typed, so its length (60 >= the
# 20-character run the checker requires) is provable, not eyeballed.
#
# <dim> (yes|"") wraps <tail> in SGR faint (ESC[2m...ESC[0m) or leaves it
# plain -- matches how Claude Code actually draws candidate/suggestion text
# (dim) versus a person's own typed characters (not dim), measured live
# 2026-09-21/22 (#1322 round 2). The marker itself and the space after it
# are never dim, same as every real capture.
_boxed_screen() {
  local tail="$1" dim="$2" rule esc
  rule="$(printf '─%.0s' $(seq 1 60))"
  esc="$(printf '\033')"
  if [ "$dim" = yes ]; then
    printf '%s testteam-alice ─\n❯ %s[0m%s[2m%s%s[0m\n%s\n' \
      "$rule" "$esc" "$esc" "$tail" "$esc" "$rule"
  else
    printf '%s testteam-alice ─\n❯%s\n%s\n' "$rule" "${tail:+ $tail}" "$rule"
  fi
}

# Builds one flat-shape (Codex) screen: marker line's own <tail>, one
# "blank" line (carrying Codex's own decorative Braille noise, measured live
# on a real stuck pane 2026-09-21 -- it draws there too, not just on the
# marker line, so the structural check must braille-strip THIS line before
# judging it blank, or every read of a genuinely idle Codex pane fails to
# confirm the live widget at all), a status footer containing "·" -- the
# live-widget triplet #1321 requires to confirm this is the real box.
#
# <dim>, same meaning as _boxed_screen's -- matches Codex's own placeholder
# (dim) versus a real typed draft (not dim), measured live 2026-09-22.
_flat_screen() {
  local tail="$1" dim="$2" esc
  esc="$(printf '\033')"
  if [ "$dim" = yes ]; then
    printf 'some transcript line\n›%s[0m%s[2m%s%s[0m\n    ⠈   ⠁  ⠐    ⠄\n  gpt-5.6-sol low · ~/projects/esota/agmsg-dev · task\n' \
      "$esc" "$esc" "$tail" "$esc"
  else
    printf 'some transcript line\n›%s\n    ⠈   ⠁  ⠐    ⠄\n  gpt-5.6-sol low · ~/projects/esota/agmsg-dev · task\n' "${tail:+ $tail}"
  fi
}

@test "poke.sh types over empty/candidate/placeholder input boxes but refuses a real draft, styled or not, stalled or actively typed (#1321, #1322)" {
  # Claude Code, genuinely empty, unchanged across both reads.
  _install_fake_herdr_screen_sequence "$(_boxed_screen '' '')"
  _write_record "herdr:w1:p5"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 0 ]
  _out_has "poked 'testteam/alice' via herdr"

  # Claude Code, Claude's OWN candidate/suggestion text sitting in the box
  # (drawn dim, matching a real measured capture), unchanged across both
  # reads — #1322 round 1's own motivating case. A content-pattern check
  # would have refused this (non-blank marker line); dim styling plus an
  # unchanged read both agree it is safe.
  : > "$ARGV_LOG"
  _install_fake_herdr_screen_sequence "$(_boxed_screen 'suggested next step' yes)"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 0 ]
  grep -q '^herdr \[agent\] \[prompt\]' "$ARGV_LOG"

  # Claude Code, a REAL draft sitting STALLED (not dim -- matches a real
  # captured draft, unlike candidate text) but otherwise unchanged across
  # both reads: #1322 round 1 alone would have let this through (nothing
  # changed); round 2's style classification refuses it on the very FIRST
  # read, before a second read is even taken.
  : > "$ARGV_LOG"
  _install_fake_herdr_screen_sequence "$(_boxed_screen 'a real stalled draft' '')"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 14 ]
  _out_has "input in progress"
  [ "$(grep -c '^herdr \[pane\] \[read\]' "$ARGV_LOG")" -eq 1 ]
  [ "$(grep -c '^herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 0 ]

  # Claude Code, someone STARTS typing between the two reads: the first read
  # shows dim candidate text (safe on its own), the second shows real,
  # non-dim characters -- refused by the SECOND read's own classification,
  # not by a content diff.
  : > "$ARGV_LOG"
  _install_fake_herdr_screen_sequence "$(_boxed_screen 'suggested next step' yes)" "$(_boxed_screen 'h' '')"
  run bash "$SCRIPTS/poke.sh" testteam alice "hello"
  [ "$status" -eq 14 ]
  [ "$(grep -c '^herdr \[pane\] \[read\]' "$ARGV_LOG")" -eq 2 ]
  [ "$(grep -c '^herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 0 ]

  # Codex, genuinely empty (its own placeholder, drawn dim -- matches a real
  # measured capture), unchanged across both reads. Real Codex panes draw a
  # decorative Braille animation OVER this exact placeholder that changes on
  # every redraw even though nothing was typed and it is never dim itself
  # (measured live, 2026-09-21/22, see scripts/lib/input-box.sh) — using the
  # identical screen for both reads here is deliberate: that decoration is
  # covered by the dedicated normalization test below, not this one.
  : > "$ARGV_LOG"
  _install_fake_herdr_screen_sequence "$(_flat_screen 'Ask Codex to do anything' yes)"
  _write_codex_record codex1 "herdr:w1:p6"
  run bash "$SCRIPTS/poke.sh" testteam codex1 "hello"
  [ "$status" -eq 0 ]
  grep -q '^herdr \[agent\] \[prompt\]' "$ARGV_LOG"

  # Codex, a real draft (not dim), refused on the first read alone.
  : > "$ARGV_LOG"
  _install_fake_herdr_screen_sequence "$(_flat_screen 'a real draft' '')"
  run bash "$SCRIPTS/poke.sh" testteam codex1 "hello"
  [ "$status" -eq 14 ]
  [ "$(grep -c '^herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 0 ]

  # Codex, stale/off-screen marker on BOTH reads: a blank "›" with blank
  # lines after it and NO footer at all -- the exact shape the previous
  # "near the bottom" guess accepted as empty, because proximity alone
  # cannot tell a live box from a leftover one. Neither read can confirm
  # this is the live widget, so it refuses even though the two reads are
  # identical -- "cannot tell" still fails toward refusing (#1321), and as
  # its own code, 15, not 14: this is "could not locate the box", not
  # "found it and it looks occupied" (#1391/#1402).
  : > "$ARGV_LOG"
  _install_fake_herdr_screen_sequence "$(printf '›\n\n\n')"
  run bash "$SCRIPTS/poke.sh" testteam codex1 "hello"
  [ "$status" -eq 15 ]
  [ "$(grep -c '^herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 0 ]

  # plain (#1321 review): the input-box check must not block plain's
  # existing agent-registration -- but see #1229 for what plain does with a
  # real Claude Code caller (a hard refusal, no fallback needed here since
  # this run has no ambient caller identity, matching the earlier `unset`
  # in setup()); the point of this assertion is only that it did NOT come
  # back as exit 14 (the input-box refusal), proving the check was skipped.
  _write_named_record plaintarget 'plain:-'
  run bash "$SCRIPTS/poke.sh" testteam plaintarget "hello"
  [ "$status" -ne 14 ]
}

@test "input-box: Codex's own decorative Braille animation is stripped before comparing, but a real (Japanese) edit still shows as changed" {
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/input-box.sh"

  # Two REAL raw lines captured live from a stuck Codex pane
  # (2026-09-21) 2 seconds apart, showing its idle "Ask Codex to do anything"
  # placeholder -- unchanged in substance, but Codex's own decorative
  # Braille animation (U+2800-U+28FF) drew differently across the two
  # reads. A naive raw-text comparison would see these as different forever
  # and never let a poke through to any idle Codex pane.
  local codex_a codex_b
  codex_a='›⠁Ask Codex to do anything⡀        ⠈ ⠂  ⠁ ⠁                  ⠈             ⠂         ⠐  ⠈'
  codex_b='› Ask Codex to do anything   ⠈            ⠁                           ⠄             ⠁  ⠁        ⠁'
  [ "$(_agmsg_strip_decorative_braille "$codex_a")" = "$(_agmsg_strip_decorative_braille "$codex_b")" ]

  # A real edit -- two Japanese lines that differ only in real (non-Braille)
  # characters -- must still compare as different. Without this half, an
  # implementation that stripped ALL non-ASCII (not just the Braille block)
  # would also pass the assertion above, but would blind the guard to
  # someone typing in Japanese entirely (rejected on review, #1322).
  local ja_a='❯ こんにちは、これは'
  local ja_b='❯ こんにちは、これは書きかけ'
  [ "$(_agmsg_strip_decorative_braille "$ja_a")" != "$(_agmsg_strip_decorative_braille "$ja_b")" ]
}

@test "input-box: a real (unstyled) draft is a real draft; dim candidate text and Codex's placeholder are not (#1322 round 2)" {
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/input-box.sh"
  local esc; esc="$(printf '\033')"

  # Claude Code candidate/suggestion text, captured live from a real pane
  # (2026-09-22): marker, a non-breaking space, then the suggestion
  # wrapped in SGR faint (dim, code 2). Must NOT read as a real draft.
  local cc_marker cc_ghost
  cc_marker='❯'
  cc_ghost="${cc_marker}$(printf '\xc2\xa0')${esc}[0m${esc}[2m承認する${esc}[0m"
  refute agmsg_input_box_is_real_draft "$cc_marker" "$cc_ghost"

  # Claude Code, a genuinely real draft, captured live from a real pane
  # (2026-09-21): marker, a non-breaking space, then plain
  # unstyled text -- no SGR at all. MUST read as a real draft; this is the
  # exact shape #1322 round 1 alone let poke type over (measured live: a
  # maintainer's stalled draft and a poke's own body landed as one
  # submitted message).
  local cc_real
  cc_real="${cc_marker}$(printf '\xc2\xa0')実際の入力文字"
  agmsg_input_box_is_real_draft "$cc_marker" "$cc_real"

  # Codex's own "Ask Codex to do anything" placeholder, captured live from a
  # real pane (2026-09-21): bold + background codes, THEN the
  # placeholder text wrapped in dim, THEN Codex's own decorative Braille
  # animation drawn in a plain foreground color (not dim) -- the exact shape
  # that would misread as a real draft if Braille weren't stripped BEFORE
  # the dim check (the animation is not dim itself, so left in place it
  # counts as real, non-dim, visible content). Must NOT read as a real
  # draft.
  local codex_marker codex_placeholder
  codex_marker='›'
  codex_placeholder="${esc}[0m${esc}[1m${esc}[48;2;65;65;65m$(printf '\xe2\xa2\x80')${esc}[0m${esc}[48;2;65;65;65m ${esc}[0m${esc}[2m${esc}[48;2;65;65;65mAsk Codex to do anything${esc}[0m${esc}[48;2;65;65;65m                                 ${esc}[0m"
  refute agmsg_input_box_is_real_draft "$codex_marker" "$codex_placeholder"
}
