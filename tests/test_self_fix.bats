#!/usr/bin/env bats
# `fix` (scripts/lib/self-fix.sh): no arguments; identity from the locks this
# session owns; the environment only proposes a candidate; the proof decides;
# the emit-and-observe fallback (#1188) runs when present; nothing is written
# unless a proof said proved. The proof, the fallback and the writer are spies
# here: what this file pins is the ORCHESTRATION -- what reaches the writer,
# and what never does.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export SPY="$SKILL_DIR/spy.log"; : > "$SPY"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-fix.sh"
  ME="sid-me.$$"; export AGMSG_SESSION_ID="$ME"
  printf '%s\n' "$ME" > "$RUN_DIR/cc-instance.$$"
  export HERDR_ENV=1 HERDR_PANE_ID=w1:pB HERDR_SOCKET_PATH=/tmp/herdr/sessions/a/herdr.sock
  unset TMUX TMUX_PANE
  # the writer is a spy: it records its arguments and writes nothing
  agmsg_self_write() { printf 'write %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$SPY"; echo "seat=$1/$2 sid=$4 pane=$3"; echo "policy=accepted"; return 0; }
}
teardown() { teardown_test_env; }

_own_seat() { printf '%s\n' "$2" > "$(actas_lock_path T "$1")"; }
_proof_says() {   # <rc> <state> <payload>
  local rc="$1" st="$2" pl="$3"
  eval "agmsg_self_proof() { printf 'proof %s %s %s\\n' \"\$1\" \"\$2\" \"\$3\" >> \"\$SPY\"; printf '%s\\t%s\\n' '$st' '$pl'; return $rc; }"
}

@test "fix: any argument is refused by name, and nothing runs" {
  _own_seat alice "$ME"; _proof_says 0 proved herdr:w1:pB
  run agmsg_fix_run herdr:w1:pB
  [ "$status" -eq 1 ]
  [ "$output" = "fix none:arguments_refused (fix takes no arguments: a location handed from outside is the accident this exists to remove)" ]
  [ ! -s "$SPY" ]
}

@test "fix: a session that owns no seat writes nothing, and says so" {
  _proof_says 0 proved herdr:w1:pB
  run agmsg_fix_run
  [ "$status" -eq 1 ]
  [ "$output" = "fix none:no_seat_for_this_session" ]
  [ ! -s "$SPY" ]
}

@test "fix: proved -> the writer gets the seat, the proof's pane qualified by the observation's socket, and the LOCK's owner token" {
  _own_seat alice "$ME"; _proof_says 0 proved herdr:w1:pB
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/alice state=proved locator=herdr:/tmp/herdr/sessions/a/herdr.sock:w1:pB via=proof" ]
  grep -Fqx "proof T alice w1:pB" "$SPY"                                  # env pane reached the PROOF as a candidate
  grep -Fqx "write T alice herdr:/tmp/herdr/sessions/a/herdr.sock:w1:pB $ME" "$SPY"
}

@test "fix: disproved -> nothing written; the env candidate never reaches the writer" {
  _own_seat alice "$ME"; _proof_says 1 disproved pane_process_not_ancestor
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=disproved reason=pane_process_not_ancestor via=proof (written nothing)" ]
  refute grep -q '^write' "$SPY"
}

@test "fix: undetermined with NO fallback present -> nothing written, the proof's reason named" {
  _own_seat alice "$ME"; _proof_says 2 undetermined owner_marker_absent
  unset -f agmsg_token_locate_self 2>/dev/null || true
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=undetermined reason=owner_marker_absent via=proof (written nothing)" ]
  refute grep -q '^write' "$SPY"
}

@test "fix: undetermined, then the emit-and-observe fallback says proved -> written with ITS locator, via=emit_observe" {
  _own_seat alice "$ME"; _proof_says 2 undetermined invocation_not_bound_to_owner
  agmsg_token_locate_self() { printf 'fallback %s %s\n' "$1" "$2" >> "$SPY"; printf 'proved\therdr:/tmp/herdr/sessions/a/herdr.sock:w1:p7\n'; return 0; }
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/alice state=proved locator=herdr:/tmp/herdr/sessions/a/herdr.sock:w1:p7 via=emit_observe" ]
  grep -Fqx "fallback T alice" "$SPY"
  grep -Fqx "write T alice herdr:/tmp/herdr/sessions/a/herdr.sock:w1:p7 $ME" "$SPY"
  [ "$(grep -c '^write' "$SPY")" -eq 1 ]
}

@test "fix: the fallback's own undetermined (ambiguous) -> nothing written, named, via=emit_observe" {
  _own_seat alice "$ME"; _proof_says 2 undetermined owner_marker_absent
  agmsg_token_locate_self() { printf 'undetermined\tambiguous\n'; return 2; }
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=undetermined reason=ambiguous via=emit_observe (written nothing)" ]
  refute grep -q '^write' "$SPY"
}

@test "fix: no candidate in the environment -> the proof is not even asked; fallback if present, else no_candidate_in_env" {
  _own_seat alice "$ME"; _proof_says 0 proved herdr:w1:pB
  unset HERDR_ENV HERDR_PANE_ID
  unset -f agmsg_token_locate_self 2>/dev/null || true
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=undetermined reason=no_candidate_in_env via=proof (written nothing)" ]
  refute grep -q '^proof' "$SPY"
  refute grep -q '^write' "$SPY"
}

@test "fix: a session holding two seats proves and writes each; a lock owned by another session is not ours" {
  _own_seat alice "$ME"; _own_seat bob "$ME"; _own_seat carol "sid-other.424242"
  _proof_says 0 proved herdr:w1:pB
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(grep -c '^write T alice ' "$SPY")" -eq 1 ]
  [ "$(grep -c '^write T bob ' "$SPY")" -eq 1 ]
  refute grep -q 'carol' "$SPY"
}

@test "fix: the entry script refuses without a session id in the shell, and takes no arguments" {
  run env -u AGMSG_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID bash "$SKILL_DIR/scripts/fix.sh"
  [ "$status" -eq 1 ]
  case "$output" in "fix none:no_session_id"*) : ;; *) echo "$output" >&2; return 1 ;; esac
  run bash "$SKILL_DIR/scripts/fix.sh" herdr:w1:p2
  [ "$status" -eq 1 ]
  case "$output" in "fix none:arguments_refused"*) : ;; *) echo "$output" >&2; return 1 ;; esac
}

@test "fix: herdr with no socket in the environment -> the proof's bare ref is written as-is (ambient instance), not a malformed 'herdr::pane'" {
  _own_seat alice "$ME"; _proof_says 0 proved herdr:w1:pB
  unset HERDR_SOCKET_PATH
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  grep -Fqx "write T alice herdr:w1:pB $ME" "$SPY"
  refute grep -q 'herdr::' "$SPY"
}

@test "fix: tmux -> the proof's pane is qualified by the socket the observation went through" {
  # tmux's self-env candidate is socket-qualified, and so is the proof's ref (#1051)
  _own_seat alice "$ME"; _proof_says 0 proved 'tmux:/tmp/tmux-501/default:%5'
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
  export TMUX="/tmp/tmux-501/default,123,0" TMUX_PANE='%5'
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  grep -Fqx "proof T alice /tmp/tmux-501/default:%5" "$SPY"
  grep -Fqx "write T alice tmux:/tmp/tmux-501/default:%5 $ME" "$SPY"
}
