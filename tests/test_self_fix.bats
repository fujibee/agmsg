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

_own_seat() {   # <agent> <owner>
  # _fix_seats_of now walks every REGISTERED seat and computes where ITS
  # OWN lock would be (#1457 round 4), rather than parsing a lock's
  # filename back into a name -- so a lock this helper places has to sit
  # behind a config.json that actually names the agent, the same as a
  # real actas-claim.sh always would have arranged first. A team with no
  # team_id (the shape every other test in this file already assumes)
  # keeps actas_lock_path on the legacy, name-keyed path.
  local team_dir="$SKILL_DIR/teams/T" cfg tmp
  mkdir -p "$team_dir"
  cfg="$team_dir/config.json"
  [ -f "$cfg" ] || printf '{"name":"T","agents":{}}' > "$cfg"
  tmp="$BATS_TEST_TMPDIR/own-seat-cfg.json"
  jq --arg a "$1" '.agents[$a] //= {}' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  printf '%s\n' "$2" > "$(actas_lock_path T "$1")"
}
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
  # #1468: the empty-seats path also tries a codex /clear thread reassign
  # before giving up; with no CODEX_THREAD_ID in this shell (test_helper
  # unsets it) that attempt fails on its very first condition, and the
  # reason rides along on the same line rather than the plain message.
  [ "$output" = "fix none:no_seat_for_this_session reason=codex_thread_id_not_set" ]
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
  unset HERDR_ENV HERDR_PANE_ID
  unset -f agmsg_token_locate_pending 2>/dev/null || true
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

@test "fix: an ID-keyed lock (team_id/member_id, #1240) resolves the real role-session by NAME, not missing_fields (#1457)" {
  # Every join now mints a team_id/member_id (#1240), so the actas lock this
  # session owns is actas.<team_id>__<member_id>.session, not
  # actas.T__alice.session -- _own_seat below goes through actas_lock_path,
  # the same id-or-legacy resolution the real claim flow uses, so it lands
  # there too. _fix_seats_of used to split that FILENAME into team/agent,
  # handing the two ids on as though they were names; every OTHER reader of
  # a role (agmsg_role_session_get, inside the REAL self-write.sh below) is
  # keyed by name, so the ids found nothing and the record cell failed as
  # missing_fields -- reproduced live, before this fix, with this exact
  # setup. This pins the fixed shape: the ids resolve back to "T"/"alice"
  # and the record is written under the name the real role-session.sh
  # record already exists under.
  #
  # The REAL writer, not this file's default spy (setup(), line 23) -- the
  # defect only shows up once role-session.sh's own name-keyed lookup
  # actually runs against it.
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-write.sh"
  # No real herdr socket in this fixture: keep the driver from loading (it
  # would overwrite these with its own real ops), and stand in for the one
  # capability self-write.sh actually needs past the fence step. Every
  # OTHER decoration (label/key/session) is optional by self-write.sh's own
  # design and skips cleanly with no driver loaded.
  agmsg_terminal_load() { :; }
  terminal_fence() { printf 'inst1\tt1\n'; return 0; }

  bash "$SCRIPTS/join.sh" T alice codex "$SKILL_DIR/proj" >/dev/null
  _own_seat alice "$ME"
  # The role-session record a real actas-claim.sh writes (role-session.sh's
  # own agmsg_role_session_record) -- _own_seat above only places the lock,
  # the same shortcut every other test in this file uses; this is the ONE
  # test that also needs the record self-write.sh's real
  # agmsg_role_session_get reads project/type from.
  agmsg_role_session_record T alice "$ME" "$SKILL_DIR/proj" codex "$ME"
  _proof_says 0 proved herdr:w1:pB

  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/alice state=proved locator=herdr:w1:pB via=proof" ]
  refute grep -qF "missing_fields" <<<"$output"
  grep -qF "record attempt=ok" <<<"$output"
}

@test "fix: an id-keyed lock whose member half cannot be resolved is reported unresolved, not the raw ids (#1457 round 2)" {
  # The team half IS a real team_id here (confirming this genuinely is an
  # id-keyed lock), but the member half was never minted for anyone -- a
  # ghost id, standing in for whatever left the journal unable to answer
  # it in the real incident. Before this fix, the empty team/agent fields
  # this row prints did not survive `read` at all (IFS treats tab as
  # whitespace, so two adjacent tabs collapse rather than reading back as
  # an empty field) -- the row silently vanished and `fix` reported
  # nothing, rc=1, never the intended state=unresolved.
  bash "$SCRIPTS/join.sh" T alice codex "$SKILL_DIR/proj" >/dev/null
  local cfg="$SKILL_DIR/teams/T/config.json" team_id
  team_id="$(sqlite3 :memory: "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.team_id');")"
  local ghost_member_id="018f0000-0000-7000-8000-0000000000fe"
  local raw="${team_id}__${ghost_member_id}"
  printf '%s\n' "$ME" > "$(_actas_lock_dir)/actas.${raw}.session"
  run agmsg_fix_run
  [ "$status" -eq 2 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=<$raw> state=unresolved reason=could_not_resolve_by_name via=n/a (written nothing)" ]
  refute grep -qF "$ghost_member_id/" <<<"$output"
}

@test "fix: a legacy team with no journal at all, literally named after a UUID, still resolves by name (#1457 round 4)" {
  # A team that has NEVER been through the id-minting
  # join flow -- config.json only, no roster journal, no team_id -- whose
  # literal NAME happens to look like a UUIDv7 (team/agent naming rules do
  # not forbid it). _fix_seats_of never parses this team's own lock
  # FILENAME at all now; it reads this team's config.json, sees "agent"
  # registered, and asks actas_lock_path where THAT seat's lock is --
  # which, with no team_id anywhere in this team's config, is the legacy
  # path, unconditionally. Nothing about a UUID shape ever enters the
  # decision.
  local uuid_team="018f0000-0000-7000-8000-0000000000aa"
  mkdir -p "$SKILL_DIR/teams/$uuid_team"
  printf '{"name":"%s","agents":{"agent":{}}}' "$uuid_team" \
    > "$SKILL_DIR/teams/$uuid_team/config.json"
  printf '%s\n' "$ME" > "$(actas_lock_path "$uuid_team" agent)"
  agmsg_role_session_record "$uuid_team" agent "$ME" "$SKILL_DIR/proj" codex "$ME"
  _proof_says 0 proved herdr:w1:pB
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-write.sh"
  agmsg_terminal_load() { :; }
  terminal_fence() { printf 'inst1\tt1\n'; return 0; }
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=$uuid_team/agent state=proved locator=herdr:w1:pB via=proof" ]
  refute grep -qF "state=unresolved" <<<"$output"
  grep -qF "record attempt=ok" <<<"$output"
}

@test "fix: a seat literally named ? is not mistaken for the unresolved sentinel (#1457 round 3)" {
  # agmsg_validate_agent_name allows "?" as a real name. Reached through
  # the id-keyed path (a real join mints team_id/member_id, both UUIDs --
  # the lock's own FILENAME never needs to encode "?" at all here, unlike
  # a literal legacy name would need _actas_lock_encode's percent-encoding
  # decoded back, which this file has never done), so this exercises the
  # exact path _agmsg_id_key_to_names resolves a name through. State has
  # to live in its own leading field, never a sentinel value written into
  # team/agent -- overloading `?` into those fields (the round-2 shape)
  # could not tell a genuinely unresolved row apart from a seat that is
  # really named "?".
  bash "$SCRIPTS/join.sh" T '?' codex "$SKILL_DIR/proj" >/dev/null
  printf '%s\n' "$ME" > "$(actas_lock_path T '?')"
  agmsg_role_session_record T '?' "$ME" "$SKILL_DIR/proj" codex "$ME"
  _proof_says 0 proved herdr:w1:pB
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-write.sh"
  agmsg_terminal_load() { :; }
  terminal_fence() { printf 'inst1\tt1\n'; return 0; }
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/? state=proved locator=herdr:w1:pB via=proof" ]
  refute grep -qF "state=unresolved" <<<"$output"
}

@test "fix: two registered seats computing to the SAME lock path are both unresolved, never one guessed (#1457 round 4)" {
  # Measured directly: this is the one residual shape the inverted walk
  # (above) does not close by itself. Team A really has these ids; a
  # SEPARATE, journal-less team is registered under A's team_id/member_id
  # taken LITERALLY as its own name. Both registrations compute to the
  # exact same actas_lock_path -- team A's genuinely, the other team's
  # legacy path coincidentally landing on the identical string. Neither
  # is a filename being misread; both are real, independently registered
  # seats whose own computed paths happen to collide. This owner cannot
  # be split between them, so both are reported unresolved rather than
  # guessing which one the lock means.
  bash "$SCRIPTS/join.sh" A agentA codex "$SKILL_DIR/projA" >/dev/null
  local cfg_a="$SKILL_DIR/teams/A/config.json" team_id_a member_id_a
  team_id_a="$(sqlite3 :memory: "SELECT json_extract(CAST(readfile('$(rf "$cfg_a")') AS TEXT), '\$.team_id');")"
  member_id_a="$(sqlite3 :memory: "SELECT json_extract(CAST(readfile('$(rf "$cfg_a")') AS TEXT), '\$.agents.agentA.member_id');")"

  mkdir -p "$SKILL_DIR/teams/$team_id_a"
  printf '{"name":"%s","agents":{"%s":{}}}' "$team_id_a" "$member_id_a" \
    > "$SKILL_DIR/teams/$team_id_a/config.json"

  local sid_a="sidA.$$"
  printf '%s\n' "$sid_a" > "$(actas_lock_path A agentA)"

  run _fix_seats_of "$(agmsg_instance_bare_sid "$sid_a")"
  [ "$status" -eq 0 ]
  local raw="${team_id_a}__${member_id_a}"
  [ "$(printf '%s\n' "$output" | grep -c "^unresolved	${sid_a}	${raw}\$")" -eq 2 ]
  refute grep -qF "^ok" <<<"$output"
}

@test "fix: a codex /clear -stranded seat is reassigned and the bridge is restarted through the existing recovery commands (#1468)" {
  # No lock this session owns THROUGH THE ORDINARY SID MATCH (the /clear
  # symptom: a new CODEX_THREAD_ID means _fix_seats_of's owner comparison
  # never matches), but a registered codex seat for this project proves for
  # this pane. The REAL shape, measured against a genuine lock: the actas lock this seat
  # already holds is owned by a pid that is genuinely alive -- THIS TEST
  # SHELL's own pid, standing in for the same os process /clear leaves
  # running -- never an absent or already-dead lock. A plain actas_lock_claim
  # would report held:<old-owner> forever against a lock like this; only the
  # narrow same-process reclaim may move it.
  local project="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$project"
  local team_dir="$SKILL_DIR/teams/T"
  mkdir -p "$team_dir"
  printf '{"name":"T","agents":{"cx":{"type":"codex","project":"%s"}}}' "$project" \
    > "$team_dir/config.json"
  agmsg_role_session_record T cx old-thread-111 "$project" codex old-owner.1
  printf 'old-thread-111.%s\n' "$$" > "$(actas_lock_path T cx)"
  # setup() already wrote cc-instance.$$ = $ME for the OTHER tests in this
  # file; agmsg_instance_alive requires that marker to match the EXACT
  # token it is asked about, so it has to agree with the owner this test
  # just placed, or the pid would read as dead by marker mismatch rather
  # than the genuinely-alive case this test means to exercise.
  printf '%s\n' "old-thread-111.$$" > "$RUN_DIR/cc-instance.$$"
  # agmsg_normalize_instance_id's composite upgrade goes through
  # agmsg_agent_pid, which walks $$'s ancestry for a codex process -- there
  # is none inside bats, so without this override the new owner token would
  # come back bare (no .pid) and never same-pid-match the lock above. This
  # is the SAME override test_delivery.bats already uses for the identical
  # reason.
  export AGMSG_AGENT_PID="$$"
  export CODEX_THREAD_ID=new-thread-222
  _proof_says 0 proved herdr:w1:pB

  # Fake the two commands a seat has always run by hand to recover from
  # this (codex-record-session.sh, session-start.sh) as spies -- this test
  # pins that `fix` calls them, with the right arguments, not what a real
  # bridge process does afterward.
  cat > "$SKILL_DIR/scripts/drivers/types/codex/codex-record-session.sh" <<'FAKEEOF'
#!/usr/bin/env bash
printf 'record-session %s %s %s CODEX_THREAD_ID=%s\n' "$1" "$2" "$3" "${CODEX_THREAD_ID:-}" >> "$SPY"
FAKEEOF
  chmod +x "$SKILL_DIR/scripts/drivers/types/codex/codex-record-session.sh"
  cat > "$SKILL_DIR/scripts/session-start.sh" <<'FAKEEOF'
#!/usr/bin/env bash
printf 'session-start %s %s\n' "$1" "$2" >> "$SPY"
FAKEEOF
  chmod +x "$SKILL_DIR/scripts/session-start.sh"

  cd "$project"
  run agmsg_fix_run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "fix seat=T/cx state=proved locator=herdr:/tmp/herdr/sessions/a/herdr.sock:w1:pB via=proof" ]
  grep -Fq "record-session T cx $project CODEX_THREAD_ID=new-thread-222" "$SPY"
  grep -Fq "session-start codex $project" "$SPY"
  grep -q '^write T cx' "$SPY"
  [ "$(cat "$(actas_lock_path T cx)")" = "new-thread-222.$$" ]

  # Condition missing: a DIFFERENT, still-alive pid holds the old lock -- a
  # genuinely separate live process, not this session's own. This is exactly
  # the case the narrow reclaim must never touch: same-pid is its whole
  # license, and there is no pid match here. fix must not steal it, and must
  # say why instead of repeating the generic no-seat message.
  : > "$SPY"
  sleep 100 &
  local other_pid=$!
  printf 'old-thread-111.%s\n' "$other_pid" > "$(actas_lock_path T cx)"
  export CODEX_THREAD_ID=new-thread-333
  run agmsg_fix_run
  kill "$other_pid" 2>/dev/null || true
  wait "$other_pid" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ "$output" = "fix none:no_seat_for_this_session reason=actas_lock_reclaim_failed" ]
  [ "$(cat "$(actas_lock_path T cx)")" = "old-thread-111.$other_pid" ]
  refute grep -q '^record-session' "$SPY"
  refute grep -q '^session-start' "$SPY"
  refute grep -q '^write' "$SPY"
}

