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
  grep -Fqx "proof T alice /tmp/herdr/sessions/a/herdr.sock:w1:pB" "$SPY"  # qualified env pane reached the PROOF as a candidate
  grep -Fqx "write T alice herdr:/tmp/herdr/sessions/a/herdr.sock:w1:pB $ME" "$SPY"
}

@test "fix: disproved -> nothing written; the env candidate never reaches the writer" {
  _own_seat alice "$ME"; _proof_says 1 disproved pane_process_not_ancestor
  # This test is about the primary proof's own report, not the fallback -- see
  # the "NO fallback present" test below for why this line is here.
  unset -f agmsg_token_locate_pending 2>/dev/null || true
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=disproved reason=pane_process_not_ancestor via=proof (written nothing)" ]
  refute grep -q '^write' "$SPY"
}

@test "fix: undetermined with NO fallback present -> nothing written, the proof's reason named" {
  _own_seat alice "$ME"; _proof_says 2 undetermined owner_marker_absent
  unset -f agmsg_token_locate_pending 2>/dev/null || true
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=undetermined reason=owner_marker_absent via=proof (written nothing)" ]
  refute grep -q '^write' "$SPY"
}

@test "fix: undetermined, a pending token already observes proved -> written with ITS locator, via=emit_observe" {
  _own_seat alice "$ME"; _proof_says 2 undetermined invocation_not_bound_to_owner
  agmsg_token_locate_pending() { printf 'pending %s %s\n' "$1" "$2" >> "$SPY"; return 0; }
  agmsg_token_locate_observe() { printf 'observe %s %s\n' "$1" "$2" >> "$SPY"; printf 'proved\therdr:/tmp/herdr/sessions/a/herdr.sock:w1:p7\n'; return 0; }
  agmsg_token_locate_emit() { echo "emit must not run when a token is already pending" >> "$SPY"; }
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/alice state=proved locator=herdr:/tmp/herdr/sessions/a/herdr.sock:w1:p7 via=emit_observe" ]
  grep -Fqx "pending T alice" "$SPY"
  grep -Fqx "observe T alice" "$SPY"
  grep -Fqx "write T alice herdr:/tmp/herdr/sessions/a/herdr.sock:w1:p7 $ME" "$SPY"
  [ "$(grep -c '^write' "$SPY")" -eq 1 ]
  refute grep -q '^emit must not run' "$SPY"
}

@test "fix: the fallback's own undetermined (ambiguous) -> nothing written, named, via=emit_observe" {
  _own_seat alice "$ME"; _proof_says 2 undetermined owner_marker_absent
  agmsg_token_locate_pending() { return 0; }
  agmsg_token_locate_observe() { printf 'undetermined\tambiguous\n'; return 2; }
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=undetermined reason=ambiguous via=emit_observe (written nothing)" ]
  refute grep -q '^write' "$SPY"
}

# #1386: emit and observe now happen on two SEPARATE calls to `fix` -- a
# single call that emitted a token and immediately searched for it never saw
# it (measured: the CLI running `fix` renders a tool call's output as a
# block, only after the call returns, so a peek taken before that return
# always reads a screen the token has not reached yet). Runs the REAL
# emit/observe (only self_proof and self_write are the spies here, per this
# file's own header), across two genuinely separate agmsg_fix_run calls, so
# what this pins is the actual sequence, not just which function names get
# called.
@test "fix: no pending token -> emits only, says try again; a second call observes and consumes it (#1386)" {
  _own_seat alice "$ME"; _proof_says 2 undetermined invocation_not_bound_to_owner
  agmsg_token_locate_generate() { printf 'fixed-fix-token\n'; }
  agmsg_terminal_enumerate() { echo "search must not run on the first call" >> "$SPY"; }

  run agmsg_fix_run
  [ "$status" -eq 2 ]
  # The token line (this test's own #1386 point: it must be FIRST, so a CLI
  # that folds a long call's output to its first few lines still shows it)
  # and the status line both land in $output -- `run` merges stdout+stderr.
  [ "$(printf '%s\n' "$output" | head -1)" = "AGMSG_LOCATE_TOKEN(T/alice): fixed-fix-token" ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "fix seat=T/alice state=undetermined reason=locate_token_emitted_call_fix_again via=emit_observe (written nothing)" ]
  refute grep -q '^search must not run' "$SPY"
  refute grep -q '^write' "$SPY"
  run agmsg_token_locate_pending T alice "$ME"
  [ "$status" -eq 0 ]

  # Second, separate call: a token is now pending, so this one observes
  # instead of emitting again -- no second AGMSG_LOCATE_TOKEN line.
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p9\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() { printf 'prompt\nfixed-fix-token\nmore\n'; }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/alice state=proved locator=herdr:sockA:w1:p9 via=emit_observe" ]
  grep -Fqx "write T alice herdr:sockA:w1:p9 $ME" "$SPY"
  run agmsg_token_locate_pending T alice "$ME"
  [ "$status" -eq 1 ]

  # #1397: re-claim the SAME role under a DIFFERENT owner TOKEN --
  # same bare session id (so this test's own session, "sid-me", still owns
  # the seat and `fix` still acts on it -- the point here is the WITNESS,
  # not seat ownership), but a different composite owner, the same way an
  # actas restart/resume/handoff mints a fresh owner without necessarily
  # changing the underlying session identity. A fresh pending record from
  # the OLD owner is left in place, still inside the TTL. The new owner's
  # own call must not observe it -- it emits its own token instead, exactly
  # like the very first call above.
  _own_seat alice "${ME%.*}.99999"
  agmsg_token_locate_generate() { printf 'stale-owner-token\n'; }
  agmsg_token_locate_emit T alice "$ME" 2>/dev/null   # a leftover from the old owner, still inside the TTL
  agmsg_token_locate_generate() { printf 'fresh-fix-token\n'; }
  agmsg_terminal_enumerate() { echo "search must not run when the pending record belongs to a superseded owner" >> "$SPY"; }
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "AGMSG_LOCATE_TOKEN(T/alice): fresh-fix-token" ]
  refute grep -q '^search must not run' "$SPY"
}

@test "fix: no candidate in the environment -> the proof is not even asked; fallback if present, else no_candidate_in_env" {
  _own_seat alice "$ME"; _proof_says 0 proved herdr:w1:pB
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH TERM_PROGRAM ORCA_TERMINAL_HANDLE
  unset -f agmsg_token_locate_pending 2>/dev/null || true
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=undetermined reason=no_candidate_in_env via=proof (written nothing)" ]
  refute grep -q '^proof' "$SPY"
  refute grep -q '^write' "$SPY"

  # A malformed, present environment is not promoted to an environment
  # candidate either; only the separately observed fallback may decide it.
  export TERM_PROGRAM=Orca
  unset ORCA_TERMINAL_HANDLE
  : > "$SPY"
  run agmsg_fix_run
  [ "$status" -eq 2 ] || return 1
  [ "$output" = "fix seat=T/alice state=undetermined reason=orca:orca_handle_unset_or_malformed via=proof (written nothing)" ] || return 1
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

@test "fix: herdr with no socket in the environment -> no candidate is available, so nothing is written" {
  _own_seat alice "$ME"; _proof_says 0 proved herdr:w1:pB
  unset HERDR_SOCKET_PATH
  # This test is about no_candidate_in_env, not the fallback -- see the "NO
  # fallback present" test above for why this line is here.
  unset -f agmsg_token_locate_pending 2>/dev/null || true
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$output" = "fix seat=T/alice state=undetermined reason=no_candidate_in_env via=proof (written nothing)" ]
  refute grep -q '^write' "$SPY"
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

@test "fix: tmux proved with NO TMUX in the environment, under set -u -> the bare ref is written and the failure path is spoken, never an aborted substitution" {
  # The entry runs under set -euo pipefail. An unguarded read of TMUX inside the
  # locator step would kill the $( ) it runs in, and the seat line would come out
  # with an EMPTY state -- neither written nor refused by name. So this runs in
  # a real shell with -u, and the signal is the seat line's content.
  _own_seat alice "$ME"
  cat > "$SKILL_DIR/probe.sh" <<PROBE
set -u
export SKILL_DIR="$SKILL_DIR" AGMSG_SESSION_ID="$ME" SPY="$SPY"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
. "$SKILL_DIR/scripts/lib/self-fix.sh"
agmsg_terminal_self_env() { printf 'tmux\t%%5\t0\n'; }
agmsg_self_proof() { printf 'proved\ttmux:%%5\n'; }
agmsg_self_write() { printf 'write %s %s %s %s\n' "\$1" "\$2" "\$3" "\$4" >> "\$SPY"; }
agmsg_fix_run
PROBE
  run bash "$SKILL_DIR/probe.sh"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/alice state=proved locator=tmux:%5 via=proof" ]
  grep -Fqx "write T alice tmux:%5 $ME" "$SPY"
  refute grep -q 'state= ' <<< "$output"
}
