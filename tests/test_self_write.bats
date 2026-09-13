#!/usr/bin/env bats
# The one path by which a seat writes its own identity cells (scripts/lib/self-write.sh).
#
# The pane arrives as an argument (the channel carries the location); the fence
# is read once, stored in the record, and re-read before each later mutation.
# Every test drives the REAL herdr driver against a fake `herdr` binary that
# answers pane get / agent list / agent get / agent rename / agent prompt from a
# fixture file the test can change mid-run, and logs every argv.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export FAKEBIN="$SKILL_DIR/fakebin"; mkdir -p "$FAKEBIN"
  export ARGV_LOG="$SKILL_DIR/argv.log"; : > "$ARGV_LOG"
  export FIX="$SKILL_DIR/fixture"
  export PATH="$FAKEBIN:$PATH"
  export HERDR_ENV=1 HERDR_SOCKET_PATH=/tmp/herdr/sessions/jugemu/herdr.sock HERDR_PANE_ID=w1:pB
  unset HERDR_SESSION
  unset TMUX TMUX_PANE
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-write.sh"
  # the seat's own registration: type and project come from here, never from args
  agmsg_role_session_record T alice sid-me /proj/alice claude-code
  ME="sid-me.$$"; printf '%s\n' "$ME" > "$RUN_DIR/cc-instance.$$"
  _fixture terminal_id term_AAA title "◐ T-alice" label "" key "" status idle kind claude
  _fake_herdr
}
teardown() { teardown_test_env; }

# fixture: key value pairs -> one file the fake reads on every call
_fixture() { : > "$FIX"; while [ $# -ge 2 ]; do printf '%s=%s\n' "$1" "$2" >> "$FIX"; shift 2; done; }
_fx() { sed -n "s/^$1=//p" "$FIX" | head -1; }

_fake_herdr() {
  cat > "$FAKEBIN/herdr" <<'FAKE'
#!/usr/bin/env bash
{ printf 'herdr'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$ARGV_LOG"
fx() { sed -n "s/^$1=//p" "$FIX" | head -1; }
if [ "$1" = pane ] && [ "$2" = get ]; then
  [ "$3" = "$(fx pane)" ] || [ -z "$(fx pane)" ] || { echo '{"error":"pane_not_found"}'; exit 1; }
  printf '{"result":{"pane":{"agent_status":"%s","label":"%s","terminal_title":"%s","terminal_id":"%s"}}}\n' \
    "$(fx status)" "$(fx label)" "$(fx title)" "$(fx terminal_id)"
elif [ "$1" = agent ] && [ "$2" = list ]; then
  if [ -n "$(fx key)" ]; then
    printf '{"id":"1","result":{"type":"list","agents":[{"pane_id":"w1:pB","name":"%s"}]}}\n' "$(fx key)"
  else
    printf '{"id":"1","result":{"type":"list","agents":[]}}\n'
  fi
elif [ "$1" = agent ] && [ "$2" = get ]; then
  printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "$(fx kind)" "$(fx status)"
elif [ "$1" = pane ] && [ "$2" = rename ]; then
  # the label lands: the fixture now shows it
  sed -i '' -e "s/^label=.*/label=$4/" "$FIX" 2>/dev/null || sed -i "s/^label=.*/label=$4/" "$FIX"
  exit 0
elif [ "$1" = agent ] && [ "$2" = rename ]; then
  sed -i '' -e "s/^key=.*/key=$4/" "$FIX" 2>/dev/null || sed -i "s/^key=.*/key=$4/" "$FIX"
  exit 0
elif [ "$1" = agent ] && [ "$2" = prompt ]; then
  # a /rename lands in the title on the next read (glyph kept)
  case "$4" in "/rename "*) sed -i '' -e "s/^title=.*/title=✳ ${4#/rename }/" "$FIX" 2>/dev/null || sed -i "s/^title=.*/title=✳ ${4#/rename }/" "$FIX" ;; esac
  exit 0
fi
exit 0
FAKE
  chmod +x "$FAKEBIN/herdr"
}

_line() { printf '%s\n' "$output" | grep -E "^$1( |=)" | head -1; }
_rec()  { cat "$(agmsg_spawn_path T alice)"; }

# --- the accepted path -----------------------------------------------------------

@test "accepted: a fresh seat writes its record with the fence, names its pane, renames its session, and policy=accepted" {
  # born under another name, so the rename is a visible DELTA (the already-named
  # case is the next test)
  _fixture terminal_id term_AAA title "◐ claude" label "" key "" status idle kind claude
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  [ "$(_line seat)" = "seat=T/alice sid=$ME pane=herdr:w1:pB" ]
  [ "$(_line fence)" = "fence=/tmp/herdr/sessions/jugemu/herdr.sock:term_AAA" ]
  [ "$(_line record)" = "record attempt=ok readback=verified" ]
  [ "$(_line label)" = "label attempt=ok readback=verified" ]
  [ "$(_line key)" = "key attempt=ok readback=verified" ]
  [ "$(_line session)" = "session attempt=ok readback=verified" ]
  [ "$(_line policy)" = "policy=accepted" ]
  # the record: ref, project, type, fence -- four TAB fields, nothing derived
  [ "$(_rec)" = "$(printf 'herdr:w1:pB\t/proj/alice\tclaude-code\tfence=/tmp/herdr/sessions/jugemu/herdr.sock:term_AAA')" ]
  # exactly one keystroke, into our own pane, the rename command
  [ "$(grep -c 'herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 1 ]
  grep -q 'herdr \[agent\] \[prompt\] \[w1:pB\] \[/rename T-alice\]' "$ARGV_LOG"
  # the done file carries the same lines
  diff <(printf '%s\n' "$output") "$(agmsg_self_write_done_path T alice)"
  # the lock is released
  [ ! -e "$(agmsg_self_write_lock_path T alice)" ]
}

@test "accepted: a session already named gets ONE unconditional rename and reads matched_no_delta (no pre-read skip)" {
  _fixture terminal_id term_AAA title "◐ T-alice" label "" key "" status idle kind claude
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  [ "$(_line session)" = "session attempt=ok readback=matched_no_delta" ]
  [ "$(grep -c 'herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 1 ]
}

# --- the record is the only required cell -----------------------------------------

@test "policy: label/key/session failures leave policy=accepted (decorations), visibly reported" {
  _fixture terminal_id term_AAA title "◐ other" label "" key "" status busy kind claude
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  [ "$(_line record)" = "record attempt=ok readback=verified" ]
  [ "$(_line session)" = "session attempt=skipped:not_ready:agent_status_busy readback=not_attempted" ]
  [ "$(_line policy)" = "policy=accepted" ]
  [ "$(grep -c 'herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 0 ]
}

@test "policy: a record whose fields are missing is repair_incomplete and writes no record (#1137)" {
  rm -f "$(_agmsg_role_session_path T alice 2>/dev/null || echo /nonexistent)"
  agmsg_role_session_record T alice sid-me "" ""
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  [ "$(_line record)" = "record attempt=failed:missing_fields readback=not_attempted" ]
  [ "$(_line policy)" = "policy=repair_incomplete" ]
  [ ! -e "$(agmsg_spawn_path T alice)" ]
}

@test "policy: a record that was written but cannot be read back is accepted_unverified, never accepted and never repair_incomplete" {
  # The readback is the only thing that fails: the write lands (the file is
  # there with the right content), but the read of it errors. `head` is what
  # the readback uses, and only for this file.
  local rec; rec="$(agmsg_spawn_path T alice)"
  head() { if [ "$2" = "$rec" ]; then return 1; fi; command head "$@"; }
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  unset -f head
  [ "$status" -eq 0 ]
  [ "$(_line record)" = "record attempt=ok readback=unavailable:record_unreadable" ]
  [ "$(_line policy)" = "policy=accepted_unverified" ]
  [ "$(cat "$rec")" = "$(printf 'herdr:w1:pB\t/proj/alice\tclaude-code\tfence=/tmp/herdr/sessions/jugemu/herdr.sock:term_AAA')" ]
}

# --- the fence ---------------------------------------------------------------------

@test "fence: a terminal_id that changes after the record refuses label/key and session, visibly, and the record keeps the fence it was written on" {
  # the pane get answering the LABEL fence re-read sees a different terminal_id:
  # model it by rewriting the fixture right after the record is written, i.e. at
  # the first `agent list` call (which only the label/key readback makes) -- too
  # late. Instead: make the fake flip terminal_id on the SECOND pane get.
  cat >> "$FAKEBIN/herdr" <<'FAKE'
FAKE
  # simplest faithful model: count pane gets in the argv log inside the fake
  sed -i '' -e 's|^fx() { sed -n "s/^$1=//p" "$FIX" \| head -1; }$|fx() { if [ "$1" = terminal_id ] \&\& [ "$(grep -c "\\[pane\\] \\[get\\]" "$ARGV_LOG")" -gt 1 ]; then echo term_BBB; return; fi; sed -n "s/^$1=//p" "$FIX" \| head -1; }|' "$FAKEBIN/herdr" 2>/dev/null \
    || sed -i 's|^fx() { sed -n "s/^$1=//p" "$FIX" \| head -1; }$|fx() { if [ "$1" = terminal_id ] \&\& [ "$(grep -c "\\[pane\\] \\[get\\]" "$ARGV_LOG")" -gt 1 ]; then echo term_BBB; return; fi; sed -n "s/^$1=//p" "$FIX" \| head -1; }|' "$FAKEBIN/herdr"
  grep -q 'term_BBB' "$FAKEBIN/herdr"
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  [ "$(_line fence)" = "fence=/tmp/herdr/sessions/jugemu/herdr.sock:term_AAA" ]
  [ "$(_line record)" = "record attempt=ok readback=verified" ]
  [ "$(_line label)" = "label attempt=skipped:fence_mismatch:terminal_id readback=not_attempted" ]
  [ "$(_line key)" = "key attempt=skipped:fence_mismatch:terminal_id readback=not_attempted" ]
  [ "$(_line session)" = "session attempt=skipped:fence_mismatch:terminal_id readback=not_attempted" ]
  [ "$(_line policy)" = "policy=accepted" ]
  [ "$(grep -c 'herdr \[agent\] \[prompt\]' "$ARGV_LOG")" -eq 0 ]
  [ "$(grep -c 'herdr \[pane\] \[rename\]' "$ARGV_LOG")" -eq 0 ]
  case "$(_rec)" in *"fence=/tmp/herdr/sessions/jugemu/herdr.sock:term_AAA") : ;; *) false ;; esac
}

@test "fence: an unreadable fence before any write refuses the whole generation and writes nothing" {
  _fixture terminal_id "" title "x" label "" key "" status idle kind claude
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 2 ]
  [ "$output" = "seat=T/alice sid=$ME pane=herdr:w1:pB none:fence_unreadable:terminal_id_missing" ]
  [ ! -e "$(agmsg_spawn_path T alice)" ]
  [ ! -e "$(agmsg_self_write_done_path T alice)" ]
  [ ! -e "$(agmsg_self_write_lock_path T alice)" ]
}

@test "fence: no socket path in the environment is an unreadable instance half, refused before any write" {
  unset HERDR_SOCKET_PATH
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 2 ]
  case "$output" in *"none:fence_unreadable:"*) : ;; *) false ;; esac
  [ ! -e "$(agmsg_spawn_path T alice)" ]
}

@test "fence: a terminal_id that CONTAINS a colon and does not change lets the later cells proceed (stored and re-read tids compare whole)" {
  # The instance half is guaranteed colon-free by the driver; the terminal_id
  # half is not (a failed read is even spelled unknown:<why>). A stored fence
  # split on the LAST colon truncates such a tid and every re-read compares
  # unequal to it -- a false refusal on every later cell.
  _fixture terminal_id "term:0x5:9" title "◐ claude" label "" key "" status idle kind claude
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  [ "$(_line fence)" = "fence=/tmp/herdr/sessions/jugemu/herdr.sock:term:0x5:9" ]
  [ "$(_line label)" = "label attempt=ok readback=verified" ]
  [ "$(_line session)" = "session attempt=ok readback=verified" ]
}

@test "fence: two terminal_ids that differ only BEFORE their last colon are still told apart" {
  _fixture terminal_id "term:a:9" title "◐ claude" label "" key "" status idle kind claude
  sed -i '' -e 's|^fx() { sed -n "s/^$1=//p" "$FIX" \| head -1; }$|fx() { if [ "$1" = terminal_id ] \&\& [ "$(grep -c "\\[pane\\] \\[get\\]" "$ARGV_LOG")" -gt 1 ]; then echo term:c:9; return; fi; sed -n "s/^$1=//p" "$FIX" \| head -1; }|' "$FAKEBIN/herdr" 2>/dev/null \
    || sed -i 's|^fx() { sed -n "s/^$1=//p" "$FIX" \| head -1; }$|fx() { if [ "$1" = terminal_id ] \&\& [ "$(grep -c "\\[pane\\] \\[get\\]" "$ARGV_LOG")" -gt 1 ]; then echo term:c:9; return; fi; sed -n "s/^$1=//p" "$FIX" \| head -1; }|' "$FAKEBIN/herdr"
  grep -q 'term:c:9' "$FAKEBIN/herdr"
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  [ "$(_line label)" = "label attempt=skipped:fence_mismatch:terminal_id readback=not_attempted" ]
  [ "$(_line session)" = "session attempt=skipped:fence_mismatch:terminal_id readback=not_attempted" ]
}

# --- the entry refuses what is not a location of ours ------------------------------

@test "refuse: a ref outside the driver grammar writes nothing" {
  run agmsg_self_write T alice "herdr:../../etc" "$ME"
  [ "$status" -eq 2 ]
  [ "$output" = "seat=T/alice sid=$ME pane=herdr:../../etc none:bad_ref" ]
  [ ! -e "$(agmsg_spawn_path T alice)" ]
  [ ! -s "$ARGV_LOG" ]
}

@test "refuse: a plain ref is unsupported, not a failure, and writes nothing" {
  run agmsg_self_write T alice "plain:-" "$ME"
  [ "$status" -eq 3 ]
  [ "$output" = "seat=T/alice sid=$ME pane=plain:- unsupported:unsupported" ]
  [ ! -e "$(agmsg_spawn_path T alice)" ]
}

@test "refuse: an empty owner is refused" {
  run agmsg_self_write T alice herdr:w1:pB ""
  [ "$status" -eq 2 ]
  [ ! -e "$(agmsg_spawn_path T alice)" ]
}

# --- exclusion -------------------------------------------------------------------

@test "busy: a live writer on the same seat makes the second one say none:busy, and it writes nothing" {
  local bpid other
  sleep 30 & bpid=$!
  other="sid-other.$bpid"; printf '%s\n' "$other" > "$RUN_DIR/cc-instance.$bpid"
  agmsg_self_write_lock_acquire T alice "$other" >/dev/null
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ "$output" = "seat=T/alice sid=$ME pane=herdr:w1:pB none:busy:$other" ]
  [ ! -e "$(agmsg_spawn_path T alice)" ]
  [ ! -s "$ARGV_LOG" ]
}

# --- what this file must never do ------------------------------------------------

@test "never: the writer touches no pane other than the one it was handed" {
  run agmsg_self_write T alice herdr:w1:pB "$ME"
  [ "$status" -eq 0 ]
  refute grep -E '\[(w[0-9]+:p[^B]|w[0-9]+:pB[^]])' "$ARGV_LOG"
  refute grep -E 'herdr \[pane\] \[list\]' "$ARGV_LOG"
}

@test "never: the library holds no pane derivation, no search and no other-seat resolution, by name" {
  refute grep -E 'terminal_find_by_label|terminal_detect|_agmsg_placement_claimed_by|_agmsg_terminal_resolve_by_label|HERDR_PANE_ID|TMUX_PANE' "$SKILL_DIR/scripts/lib/self-write.sh"
}

# --- the record's fourth field must not land in anyone's `type` -------------------

@test "readers: every script that splits a placement record with read takes a fourth variable for the fence field" {
  # `read -r ref proj type` puts everything after the third TAB into `type`. The
  # self-write record has a fourth field, so every such reader takes a fourth
  # variable (which absorbs any later fields too). Counted at the read sites,
  # not by a guess: a reader with three variables is the defect this catches.
  local bad; bad="$(grep -nE "IFS=(\\\$'\\\\t'|\"\\\$tab\") read -r [A-Za-z_]+ [A-Za-z_]+ [A-Za-z_]+ < \"?\\\$?(SPAWN_REC|REC|rec)\"?" "$SKILL_DIR"/scripts/*.sh || true)"
  [ -z "$bad" ] || { echo "placement-record readers with only three variables:" >&2; printf '%s\n' "$bad" >&2; return 1; }
  # and the readers do exist -- the pattern is not vacuous
  [ "$(grep -cE "read -r [A-Za-z_]+ [A-Za-z_]+ [A-Za-z_]+ [A-Za-z_]+ < \"?\\\$?(SPAWN_REC|REC|rec)\"?" "$SKILL_DIR"/scripts/despawn.sh "$SKILL_DIR"/scripts/peek.sh "$SKILL_DIR"/scripts/poke.sh "$SKILL_DIR"/scripts/arrange.sh "$SKILL_DIR"/scripts/placement-collisions.sh | awk -F: '{s+=$2} END {print s+0}')" -ge 5 ]
}
