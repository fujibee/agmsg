#!/usr/bin/env bash
# self-fix.sh -- `fix`: a seat establishes where it is, and repairs itself there.
#
# NO ARGUMENTS. This is the whole design (#1152, ruling of 2026-09-13). A location
# handed in from outside is the accident this exists to remove: measured live,
# a seat whose label had been broken resolved itself through an inherited
# environment into ANOTHER seat's pane and wrote that pane into its own mark --
# it stopped short of typing there only because that pane's name was not
# readable. So nothing tells the seat where it is. The seat proves it:
#
#   1. identity  -- which seats this session holds, from the actas locks it OWNS
#                   (identity is not location; a lock names a role, not a pane)
#   2. candidate -- the pane the environment names, as a CANDIDATE only; the
#                   environment is a generator, never an authority
#   3. proof     -- agmsg_self_proof (#1154): the pane's process is in the
#                   owner's complete ancestry, or it is not, or we cannot tell
#   4. fallback  -- when the proof does not say proved and #1188's emit-and-
#                   observe is present (agmsg_token_locate_pending / _emit /
#                   _observe, #1386), that runs, in the same four-state
#                   contract -- across two SEPARATE calls to this whole
#                   script, since a token this call both emits and searches
#                   for in the same breath is never actually on screen yet
#                   to find (see token-locate.sh)
#   5. write     -- ONLY on proved: the record and decorations through
#                   agmsg_self_write, under the seat-local lock. Anything else
#                   is reported by name and NOTHING is written.
#
# Whoever runs it -- a poke from another seat, a person at the keyboard, a skill
# on a loop -- gets the same answer, because none of them carries a location.
#
# OUTPUT. One line per seat this session holds, then the writer's lines:
#   fix seat=<team>/<agent> state=proved locator=<kind:instance:pane> via=<proof|emit_observe>
#   fix seat=<team>/<agent> state=<disproved|undetermined|unsupported> reason=<r> via=<...> (written nothing)
#   fix none:<no_seat_for_this_session|arguments_refused|...>
# Exit: 0 when every held seat was written; 2 when at least one was not; 1 on refusal.

: "${SKILL_DIR:?self-fix.sh requires SKILL_DIR}"
# shellcheck disable=SC1091
. "${SKILL_DIR:?}/scripts/lib/actas-lock.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?}/scripts/lib/terminal-registry.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?}/scripts/lib/self-proof.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?}/scripts/lib/self-write.sh"
# _fix_locate's emit-and-observe fallback (#1188) calls
# agmsg_token_locate_pending/_emit/_observe behind a declare -F check;
# nothing sourced these functions in production, so the check was always
# false and the fallback never ran. This file is what depends on it, so
# this file sources it.
# shellcheck disable=SC1091
. "${SKILL_DIR:?}/scripts/lib/token-locate.sh"
# agmsg_canonical_path, for _fix_codex_thread_reassign's project comparison
# (#1468) -- actas-lock.sh/self-write.sh pull in role-session.sh and
# instance-id.sh already, but nothing before this reached resolve-project.sh.
# shellcheck disable=SC1091
. "${SKILL_DIR:?}/scripts/lib/resolve-project.sh"
# agmsg_sha1, for _fix_codex_thread_synced's multi-pair bridge_key -- the
# same derivation session-start.sh uses, so both land on the same file.
# shellcheck disable=SC1091
. "${SKILL_DIR:?}/scripts/lib/hash.sh"

# The seats whose actas lock this session OWNS, one line per seat:
#   ok\t<team>\t<agent>\t<owner>            resolved -- safe to use
#   unresolved\t<owner>\t<raw-name>          could not be resolved by name
# The leading word is its own field, never a stand-in written into team or
# agent: `?` is a NAME `agmsg_validate_team_name`/`agmsg_validate_agent_name`
# both allow, so a sentinel written into either of those fields cannot be
# told apart from a genuinely `?`-named seat's own real name -- a mistake
# review caught once already (#1457 round 3).
#
# THE DIRECTION IS INVERTED (#1457 review round 4). Three rounds running,
# guessing "is this lock's FILENAME an id or a name" from the filename
# alone kept finding one more edge case to close -- a legacy name shaped
# like two UUIDv7s, a round trip that also happens to match a real,
# separately registered legacy pair, and so on. Walking every REGISTERED
# seat instead and asking where ITS OWN lock would be makes the question
# moot: actas_lock_path already knows, for a given (team, agent) NAME
# pair, whether that seat's lock is id-keyed or legacy -- the same
# id-or-legacy resolution every other reader of a role already uses, not
# a guess made from a filename. Nothing here ever parses a filename back
# into a name; the names are already in hand from config.json, and the
# path built from them is what gets checked against disk. A team's seat
# count is small (tens at most), so walking every one costs nothing
# worth avoiding.
_fix_seats_of() {   # <bare-sid>
  local sid="$1" team_dir cfg team agent agents p rd kind owner
  local matched=() cand_path=() cand_team=() cand_agent=() cand_owner=()
  if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/sqlpath.sh"
  fi
  for team_dir in "$SKILL_DIR"/teams/*/; do
    [ -d "$team_dir" ] || continue
    cfg="${team_dir}config.json"
    [ -f "$cfg" ] || continue
    team="${team_dir%/}"; team="${team##*/}"
    # .agents is a JSON OBJECT keyed by agent name in every team format
    # this codebase carries (confirmed against resolve-project.sh's own
    # two-shape handling of what each agent's VALUE looks like -- only
    # the value's inner shape varies by vintage, never the outer keying).
    agents="$(sqlite3 :memory: "
      SELECT key FROM json_each(json_extract(CAST(readfile('$(agmsg_sql_readfile_path "$cfg")') AS TEXT), '\$.agents'));
    " 2>/dev/null | tr -d '\r')"
    [ -n "$agents" ] || continue
    while IFS= read -r agent; do
      [ -n "$agent" ] || continue
      p="$(actas_lock_path "$team" "$agent" 2>/dev/null)" || continue
      [ -e "$p" ] || continue
      matched+=("$p")
      rd="$(_actas_lock_read_path "$p")"; kind="${rd%%$'\t'*}"; owner="${rd#*$'\t'}"
      [ "$kind" = ok ] && [ -n "$owner" ] || continue
      [ "$(agmsg_instance_bare_sid "$owner")" = "$sid" ] || continue
      # Not printed yet -- collected, so a path that ANOTHER registered
      # seat also computes to (below) can still downgrade this one.
      cand_path+=("$p"); cand_team+=("$team"); cand_agent+=("$agent"); cand_owner+=("$owner")
    done <<< "$agents"
  done

  # Two or more registered seats computing to the SAME lock path is a
  # genuine ambiguity (#1457 review round 4): a legacy team/seat pair's
  # own literal name can coincide with another team's real ids (or vice
  # versa) -- not a parsing mistake to fix, since nothing here ever reads
  # the path back into a name, but a fact about the two REGISTRATIONS
  # this owner cannot be split between. Counted on the candidates already
  # gathered above; reported unresolved on every one that shares a path,
  # the same safe default as any other lock nothing here could name.
  local i j count n="${#cand_path[@]}" rawname
  for ((i = 0; i < n; i++)); do
    count=0
    for ((j = 0; j < n; j++)); do
      [ "${cand_path[j]}" = "${cand_path[i]}" ] && count=$((count + 1))
    done
    if [ "$count" -gt 1 ]; then
      rawname="${cand_path[i]##*/actas.}"; rawname="${rawname%.session}"
      printf 'unresolved\t%s\t%s\n' "${cand_owner[i]}" "$rawname"
    else
      printf 'ok\t%s\t%s\t%s\n' "${cand_team[i]}" "${cand_agent[i]}" "${cand_owner[i]}"
    fi
  done

  # Any lock this session owns that did not match any registered seat's
  # own computed path above -- reported unresolved, not silently dropped,
  # so the caller still learns something is stuck rather than seeing
  # nothing at all (the missing_fields shape #1457 measured started
  # exactly this way: a real lock, owned by this session, that nothing
  # could name).
  local f name t2 already m
  for f in "$(_actas_lock_dir)"/actas.*.session; do
    [ -e "$f" ] || continue
    already=0
    for m in ${matched[@]+"${matched[@]}"}; do
      [ "$m" = "$f" ] || continue
      already=1; break
    done
    [ "$already" -eq 0 ] || continue
    name="${f##*/actas.}"; name="${name%.session}"
    t2="${name%%__*}"
    [ "$t2" != "$name" ] || continue
    rd="$(_actas_lock_read_path "$f")"; kind="${rd%%$'\t'*}"; owner="${rd#*$'\t'}"
    [ "$kind" = ok ] && [ -n "$owner" ] || continue
    [ "$(agmsg_instance_bare_sid "$owner")" = "$sid" ] || continue
    printf 'unresolved\t%s\t%s\n' "$owner" "$name"
  done
}

# The locator a proof established. The proof's canonical ref names the kind
# and the pane; the INSTANCE is the one the proof's observation went through --
# the socket the driver was talking to while it observed the pane's processes.
# That is the name of the observation's path, not the environment as an
# authority: if the proof did not say proved, this is never consulted.
_fix_locator_of_proof() {   # <canonical-ref>
  local ref="$1" kind pane inst=""
  kind="${ref%%:*}"; pane="${ref#*:}"
  case "$kind" in
    herdr) inst="${HERDR_SOCKET_PATH:-}" ;;
    tmux)  case "$pane" in *:*) inst="${pane%:*}"; pane="${pane##*:}" ;; *) inst="${TMUX:-}"; inst="${inst%%,*}" ;; esac ;;
    plain) case "$pane" in *:*) inst="${pane%%:*}"; pane="${pane#*:}" ;; esac ;;
  esac
  [ -n "$inst" ] || { printf '%s\n' "$ref"; return 0; }   # bare: ambient instance
  agmsg_locator_compose "$kind" "$inst" "$pane" 2>/dev/null || printf '%s\n' "$ref"
}

# Prove one seat's location. Prints "<state>\t<payload>\t<via>"; rc as the proof's.
_fix_locate() {   # <team> <agent> <owner>
  local team="$1" agent="$2" owner="$3" env kind cand out rc=0 st
  env="$(agmsg_terminal_self_env 2>/dev/null)"
  if [ -n "$env" ]; then
    kind="${env%%$'\t'*}"
    cand="$(printf '%s' "$env" | cut -f2)"
    # agmsg_terminal_self_env is deliberately driver-free (its own header: "no
    # driver loaded, no terminal called"). Nothing else in this call path loads
    # one either, so terminal_pane_process_observe was never defined here and
    # the proof always answered unsupported:driver_no_process_binding -- proved
    # was unreachable for every terminal, not just the ones without the hook.
    # Best-effort: a load failure still reaches the proof, whose own
    # declare -F guard reports the right unsupported reason.
    agmsg_terminal_load "$kind" 2>/dev/null || true
    out="$(agmsg_self_proof "$team" "$agent" "$cand")" || rc=$?
    st="${out%%$'\t'*}"
    if [ "$rc" -eq 0 ] && [ "$st" = proved ]; then
      printf 'proved\t%s\tproof\n' "$(_fix_locator_of_proof "${out#*$'\t'}")"; return 0
    fi
  else
    out="undetermined"$'\t'"no_candidate_in_env"; rc=2
  fi
  # not proved: the emit-and-observe fallback (#1188), when it is present.
  # Split across two SEPARATE calls to this whole script (#1386): a caller
  # that emits and observes within the same call never sees its own token,
  # because the CLI running this renders one call's output as a block, only
  # after the call returns -- so this call either observes a token a PRIOR
  # call already emitted (and had rendered), or emits one now for a LATER
  # call to observe, never both in the same pass.
  #
  # $owner (the actas lock's own owner token for this role, from
  # agmsg_fix_run's caller) is threaded through as the pending record's
  # witness (review, #1397): the role this token was emitted for can be
  # restarted, resumed, or handed off to a different session inside the TTL
  # window, and a bare (team, agent) key alone cannot tell that seat's own
  # fresh `fix` call apart from one left over from before the change --
  # observing a stale record then would hand this seat a location the OLD
  # occupant's pane produced, not its own, exactly the outside-supplied
  # location #1152 exists to refuse. Every actas re-claim (restart, resume,
  # handoff) mints a new owner token, so requiring it to match is what makes
  # a stale record from a superseded claim unusable rather than merely
  # unlikely to collide.
  if declare -F agmsg_token_locate_pending >/dev/null 2>&1; then
    if agmsg_token_locate_pending "$team" "$agent" "$owner"; then
      local fo frc=0
      fo="$(agmsg_token_locate_observe "$team" "$agent" "$owner")" || frc=$?
      case "$frc:${fo%%$'\t'*}" in
        0:proved) printf 'proved\t%s\temit_observe\n' "${fo#*$'\t'}"; return 0 ;;
        *) printf '%s\t%s\temit_observe\n' "${fo%%$'\t'*}" "${fo#*$'\t'}"; return "${frc:-2}" ;;
      esac
    fi
    # No pending token: emit one now (visible on screen once THIS call
    # returns) and tell the caller to run `fix` again -- one line a human
    # and a seat both read the same way, not a state this contract already
    # has a name for.
    agmsg_token_locate_emit "$team" "$agent" "$owner"
    printf 'undetermined\tlocate_token_emitted_call_fix_again\temit_observe\n'
    return 2
  fi
  printf '%s\t%s\tproof\n' "${out%%$'\t'*}" "${out#*$'\t'}"
  return "$rc"
}

# Whether (team, agent)'s codex thread state matches CODEX_THREAD_ID, by
# READING THE RESULT rather than trusting an exit code (#1470 review round
# 4 finding 3): codex-record-session.sh routinely exits 0 having recorded
# nothing (its own "poison-record guard" -- a thread it cannot resolve is a
# no-op, not a failure), and session-start.sh exits 0 on every early return
# (no app-server yet, no seat key, an already-live bridge) -- none of those
# are evidence the state this function cares about actually changed.
#
# Checks the role-session record first, then -- only if a bridge has ever
# bound a thread for this project's pair set -- the bridge's own recorded
# thread, at the SAME path session-start.sh's direct path and the
# out-of-sandbox launcher both already write to (codex-bridge.<key>.thread),
# so this one check covers either architecture. No file there yet is not a
# failure: a seat that has never had a bridge has nothing to contradict.
#
# Prints nothing and returns 0 when synced; prints a one-word reason and
# returns 1 otherwise.
_fix_codex_thread_synced() {   # <team> <agent> <project>
  local team="$1" agent="$2" project="$3" rec_thread pairs pair_n bridge_key thread_file thread_now
  rec_thread="$(agmsg_role_session_uuid "$team" "$agent" 2>/dev/null || true)"
  [ "$rec_thread" = "$CODEX_THREAD_ID" ] || { printf 'role_session_record_still_old\n'; return 1; }

  pairs="$("$SKILL_DIR/scripts/identities.sh" "$project" codex 2>/dev/null || true)"
  pair_n="$(printf '%s\n' "$pairs" | grep -c . || true)"
  if [ "${pair_n:-0}" -eq 1 ]; then
    bridge_key="$team.$agent"
  else
    bridge_key="$(printf '%s' "$pairs" | agmsg_sha1)"
  fi
  thread_file="$(_actas_lock_dir)/codex-bridge.$bridge_key.thread"
  if [ -f "$thread_file" ]; then
    thread_now="$(cat "$thread_file" 2>/dev/null || true)"
    [ "$thread_now" = "$CODEX_THREAD_ID" ] || { printf 'bridge_thread_still_old\n'; return 1; }
  fi
  return 0
}

# Run the two existing recovery commands -- codex-record-session.sh, then
# session-start.sh codex <project>, the same order and the same two
# commands a seat has always run by hand -- and re-check by STATE, never by
# their exit codes (see _fix_codex_thread_synced). Already-synced short-
# circuits without running either (idempotent either way, but no reason to
# shell out twice on every `fix` once a seat has caught up). Prints nothing
# and returns 0 when synced afterward; prints the still-stale reason and
# returns 1 otherwise.
_fix_codex_thread_sync() {   # <team> <agent> <project>
  local team="$1" agent="$2" project="$3" reason
  reason="$(_fix_codex_thread_synced "$team" "$agent" "$project")" && return 0
  "$SKILL_DIR/scripts/drivers/types/codex/codex-record-session.sh" "$team" "$agent" "$project" >/dev/null 2>&1 || true
  "$SKILL_DIR/scripts/session-start.sh" codex "$project" </dev/null >/dev/null 2>&1 || true
  reason="$(_fix_codex_thread_synced "$team" "$agent" "$project")" && return 0
  printf '%s\n' "$reason"
  return 1
}

# codex's `/clear` mints a new CODEX_THREAD_ID inside the same TUI process
# (#1468). The actas lock this seat claimed under the OLD thread id is now
# owned by a sid this session's AGMSG_SESSION_ID (= the new CODEX_THREAD_ID,
# see fix.sh) can never match, so _fix_seats_of finds nothing and a plain
# `fix` reports no_seat_for_this_session even though the seat is still right
# here, in the same pane, under the same OS process. This reassigns it --
# but ONLY when every one of the following holds, checked in order, the
# first miss reported and nothing guessed past it:
#
#   1. CODEX_THREAD_ID is set (this really is a codex session, and we know
#      its current, trustworthy thread id).
#   2. Exactly ONE registered codex seat for the current project PROVES for
#      this pane (agmsg_self_proof, the same proof `fix` always uses --
#      proof is about OS process ancestry, which /clear never changes, so a
#      seat whose actas lock is stale by SID still proves here).
#   3. That seat's role-session record's project matches this one, and its
#      recorded thread is a DIFFERENT thread than CODEX_THREAD_ID (there is
#      actually something stale to fix).
#
# On success: re-claim the actas lock under the NEW sid, then run the exact
# two commands a seat has always run by hand to recover from this (#1468) --
# codex-record-session.sh to move the role-session record onto the current
# thread, then session-start.sh codex <project> to hand the bridge off
# again. No new bridge-restart machinery: the out-of-sandbox launcher
# (codex-bridge-launcher.sh, the path codex-monitor.sh actually arms) already
# polls the role-session record and its own request file and retires+
# respawns a bridge bound to the wrong thread on its own -- confirmed by
# reading its child loop, not assumed. Prints the reassigned seat in the same
# `ok\t<team>\t<agent>\t<owner>` shape _fix_seats_of emits, so the normal
# proved/write loop below picks it up unchanged; prints nothing and returns
# 1 when any condition is not met (the caller reports the skip by name).
_fix_codex_thread_reassign() {
  local project env kind cand pairs team agent
  local proof_out proof_rc proof_state proved_team="" proved_agent="" proved_n=0
  local rec_thread rec_project rec_project_phys project_phys new_owner claim_out claim_rc=0

  [ -n "${CODEX_THREAD_ID:-}" ] || { printf 'codex_thread_id_not_set\n'; return 1; }

  project="$PWD"
  env="$(agmsg_terminal_self_env 2>/dev/null)"
  [ -n "$env" ] || { printf 'no_candidate_in_env\n'; return 1; }
  kind="${env%%$'\t'*}"
  cand="$(printf '%s' "$env" | cut -f2)"
  agmsg_terminal_load "$kind" 2>/dev/null || true

  pairs="$("$SKILL_DIR/scripts/identities.sh" "$project" codex 2>/dev/null || true)"
  [ -n "$pairs" ] || { printf 'no_registered_codex_seat_for_project\n'; return 1; }

  while IFS=$'\t' read -r team agent; do
    [ -n "$team" ] && [ -n "$agent" ] || continue
    proof_rc=0
    proof_out="$(agmsg_self_proof "$team" "$agent" "$cand" 2>/dev/null)" || proof_rc=$?
    proof_state="${proof_out%%$'\t'*}"
    if [ "$proof_rc" -eq 0 ] && [ "$proof_state" = proved ]; then
      proved_n=$((proved_n + 1))
      proved_team="$team"; proved_agent="$agent"
    fi
  done <<< "$pairs"

  [ "$proved_n" -ge 1 ] || { printf 'no_proved_codex_seat_in_this_pane\n'; return 1; }
  [ "$proved_n" -eq 1 ] || { printf 'multiple_proved_codex_seats_in_this_pane\n'; return 1; }

  rec_thread="$(agmsg_role_session_uuid "$proved_team" "$proved_agent" 2>/dev/null || true)"
  [ -n "$rec_thread" ] || { printf 'no_role_session_record\n'; return 1; }
  rec_project="$(agmsg_role_session_get "$proved_team" "$proved_agent" project 2>/dev/null || true)"
  rec_project_phys="$(agmsg_canonical_path "$rec_project" 2>/dev/null || printf '%s' "$rec_project")"
  project_phys="$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")"
  [ "$rec_project_phys" = "$project_phys" ] || { printf 'recorded_project_mismatch\n'; return 1; }
  [ "$rec_thread" != "$CODEX_THREAD_ID" ] || { printf 'record_already_on_current_thread\n'; return 1; }

  # Eligible. Re-claim first -- proof and record are about to change under
  # it, and a caller reading the lock between here and the record rewrite
  # below should see this session, not the dead one.
  new_owner="$(agmsg_normalize_instance_id "$CODEX_THREAD_ID" codex 2>/dev/null)"
  [ -n "$new_owner" ] || { printf 'owner_token_unresolvable\n'; return 1; }
  # Not a plain actas_lock_claim: the old owner's pid is the SAME os process
  # (only its codex thread id changed), so it is genuinely alive and a plain
  # claim would report held:<old-owner> forever. actas_lock_reclaim_same_process
  # is the one lock write allowed to move a live-owned lock, and only when the
  # new owner's pid -- derived the identical way -- matches the current one.
  claim_out="$(actas_lock_reclaim_same_process "$proved_team" "$proved_agent" "$new_owner" 2>/dev/null)" || claim_rc=$?
  [ "$claim_rc" -eq 0 ] && [ "$claim_out" = ok ] || { printf 'actas_lock_reclaim_failed\n'; return 1; }

  # The lock move above is the one step this function is willing to leave in
  # place on a downstream failure (rolling it back would only trade "seat
  # right here, bridge on the old thread" for "seat nowhere at all" -- worse,
  # not safer). A caller must still be told when the rest did not actually
  # converge: silently reporting proved when it did not is exactly what
  # #1470 review caught. Checked by STATE (_fix_codex_thread_sync), not by
  # the two commands' exit codes -- both routinely exit 0 without having
  # changed anything.
  local sync_reason sync_rc=0
  sync_reason="$(_fix_codex_thread_sync "$proved_team" "$proved_agent" "$project")" || sync_rc=$?
  if [ "$sync_rc" -ne 0 ]; then
    printf 'partial\t%s\t%s\t%s\t%s\n' "$proved_team" "$proved_agent" "$new_owner" "$sync_reason"
    return 2
  fi

  printf 'ok\t%s\t%s\t%s\n' "$proved_team" "$proved_agent" "$new_owner"
  return 0
}

# The entry. Refuses any argument by name.
agmsg_fix_run() {
  if [ "$#" -ne 0 ]; then
    echo "fix none:arguments_refused (fix takes no arguments: a location handed from outside is the accident this exists to remove)" >&2
    return 1
  fi
  local sid seats line status a b c team agent owner loc st payload via rc=0 any=0 failed=0
  local reassign_line reassign_reason
  sid="$(agmsg_instance_bare_sid "${AGMSG_SESSION_ID:-}" 2>/dev/null)"
  [ -n "$sid" ] || { echo "fix none:no_session_id" >&2; return 1; }
  seats="$(_fix_seats_of "$sid")"
  if [ -z "$seats" ]; then
    # #1468: this session's own seat may be a codex seat stranded by /clear
    # rather than one that never existed -- see _fix_codex_thread_reassign's
    # own header for the exact conditions and why they are safe.
    reassign_line="$(_fix_codex_thread_reassign)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      seats="$reassign_line"
    elif [ "$rc" -eq 2 ]; then
      # The actas lock moved, but the role-session record and/or bridge did
      # not converge -- the seat is not fully repaired, so this is reported
      # as a failure by name, never as proved. The lock move is left in
      # place (see _fix_codex_thread_reassign's own comment for why undoing
      # it is not safer): running `fix` again from here re-enters through
      # the seats-found branch below, which now also re-checks and retries
      # the sync for exactly this reason (#1470 review round 4 finding 2).
      IFS=$'\t' read -r _ team agent owner detail <<<"$reassign_line"
      printf 'fix seat=%s/%s state=partial reason=%s (lock reclaimed under %s; fix again once the bridge catches up)\n' \
        "$team" "$agent" "$detail" "$owner"
      return 2
    else
      reassign_reason="$reassign_line"
      echo "fix none:no_seat_for_this_session reason=${reassign_reason:-not_a_codex_seat}" >&2
      return 1
    fi
  fi
  while IFS=$'\t' read -r status a b c; do
    [ -n "$status" ] || continue
    any=1
    if [ "$status" = unresolved ]; then
      # a=owner, b=raw lock name -- see _fix_seats_of's own header for why
      # the state lives in its own leading field rather than a sentinel
      # written into team/agent (#1457 round 3: `?` is a NAME the roster
      # allows, so a `?`-named seat's own real name could not have been
      # told apart from that sentinel).
      printf 'fix seat=<%s> state=unresolved reason=could_not_resolve_by_name via=n/a (written nothing)\n' "$b"
      failed=1
      continue
    fi
    team="$a"; agent="$b"; owner="$c"
    # #1470 review round 4 finding 2: a seat _fix_seats_of already found
    # normally (its actas lock is correctly ours) can still be a codex seat
    # whose role-session record or bridge is stale relative to THIS
    # session's current thread -- exactly the state a prior `partial` left
    # behind. Without this, running `fix` again after a partial would find
    # the seat via the ordinary path above, report proved (the lock and
    # pane genuinely ARE fine), and never retry the two recovery commands --
    # "fix again" would not actually converge. Only runs at all when
    # CODEX_THREAD_ID is in this shell; a non-codex seat has no such
    # variable to compare against, so this is a no-op for it.
    if [ -n "${CODEX_THREAD_ID:-}" ]; then
      local sync_reason sync_rc=0
      sync_reason="$(_fix_codex_thread_sync "$team" "$agent" "$PWD")" || sync_rc=$?
      if [ "$sync_rc" -ne 0 ]; then
        printf 'fix seat=%s/%s state=partial reason=%s (lock already ours; fix again once the bridge catches up)\n' \
          "$team" "$agent" "$sync_reason"
        failed=1
        continue
      fi
    fi
    loc="$(_fix_locate "$team" "$agent" "$owner")" || true
    st="${loc%%$'\t'*}"; payload="${loc#*$'\t'}"; via="${payload##*$'\t'}"; payload="${payload%$'\t'*}"
    if [ "$st" = proved ]; then
      printf 'fix seat=%s/%s state=proved locator=%s via=%s\n' "$team" "$agent" "$payload" "$via"
      agmsg_self_write "$team" "$agent" "$payload" "$owner" || failed=1
    else
      printf 'fix seat=%s/%s state=%s reason=%s via=%s (written nothing)\n' "$team" "$agent" "$st" "$payload" "$via"
      failed=1
    fi
  done <<< "$seats"
  [ "$any" -eq 1 ] || return 1
  [ "$failed" -eq 0 ] || return 2
  return 0
}
