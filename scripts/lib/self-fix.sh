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

# The locator a proof established. Ask the registered driver for its instance;
# do not maintain a second terminal-name-to-environment table here.
_fix_locator_of_proof() {   # <canonical-ref>
  agmsg_terminal_ref_qualify "$1"
}

# Prove one seat's location. Prints "<state>\t<payload>\t<via>"; rc as the proof's.
_fix_locate() {   # <team> <agent> <owner>
  local team="$1" agent="$2" owner="$3" env kind cand out rc=0 st
  env="$(agmsg_terminal_self_env 2>/dev/null)"
  case "$env" in
    unknown:*) out="undetermined"$'\t'"${env#unknown:}"; rc=2 ;;
    '') out="undetermined"$'\t'"no_candidate_in_env"; rc=2 ;;
    *)
      kind="${env%%$'\t'*}"
      cand="$(printf '%s' "$env" | cut -f2)"
      # The environment-only driver query does not alter this shell's loaded
      # driver. Load the selected driver here so process observation uses its ABI.
      # Best-effort: a load failure still reaches the proof, whose own
      # declare -F guard reports the right unsupported reason.
      agmsg_terminal_load "$kind" 2>/dev/null || true
      out="$(agmsg_self_proof "$team" "$agent" "$cand")" || rc=$?
      st="${out%%$'\t'*}"
      if [ "$rc" -eq 0 ] && [ "$st" = proved ]; then
        local qualified proof_ref
        proof_ref="${out#*$'\t'}"
        if qualified="$(_fix_locator_of_proof "$proof_ref")"; then
          printf 'proved\t%s\tproof\n' "$qualified"
          return 0
        fi
        printf 'undetermined\tterminal_instance_unresolved\tproof\n'
        return 2
      fi
      ;;
  esac
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

# The entry. Refuses any argument by name.
agmsg_fix_run() {
  if [ "$#" -ne 0 ]; then
    echo "fix none:arguments_refused (fix takes no arguments: a location handed from outside is the accident this exists to remove)" >&2
    return 1
  fi
  local sid seats line status a b c team agent owner loc st payload via rc=0 any=0 failed=0
  sid="$(agmsg_instance_bare_sid "${AGMSG_SESSION_ID:-}" 2>/dev/null)"
  [ -n "$sid" ] || { echo "fix none:no_session_id" >&2; return 1; }
  seats="$(_fix_seats_of "$sid")"
  [ -n "$seats" ] || { echo "fix none:no_seat_for_this_session" >&2; return 1; }
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
