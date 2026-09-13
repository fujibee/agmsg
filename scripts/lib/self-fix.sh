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
#                   observe is present (agmsg_token_locate_self), that runs, in
#                   the same four-state contract
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

# The seats whose actas lock this session OWNS: "<team>\t<agent>\t<owner>" per line.
# <bare-sid> is the caller's session id; a lock is ours when its owner's bare sid
# equals it. Unreadable locks are skipped, not guessed.
_fix_seats_of() {   # <bare-sid>
  local sid="$1" f name team agent rd kind owner
  for f in "$(_actas_lock_dir)"/actas.*.session; do
    [ -e "$f" ] || continue
    name="${f##*/actas.}"; name="${name%.session}"
    team="${name%%__*}"; agent="${name#*__}"
    [ "$team" != "$name" ] || continue
    rd="$(_actas_lock_read_path "$f")"; kind="${rd%%$'\t'*}"; owner="${rd#*$'\t'}"
    [ "$kind" = ok ] && [ -n "$owner" ] || continue
    [ "$(agmsg_instance_bare_sid "$owner")" = "$sid" ] || continue
    printf '%s\t%s\t%s\n' "$team" "$agent" "$owner"
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
_fix_locate() {   # <team> <agent>
  local team="$1" agent="$2" env cand out rc=0 st
  env="$(agmsg_terminal_self_env 2>/dev/null)"
  if [ -n "$env" ]; then
    cand="$(printf '%s' "$env" | cut -f2)"
    out="$(agmsg_self_proof "$team" "$agent" "$cand")" || rc=$?
    st="${out%%$'\t'*}"
    if [ "$rc" -eq 0 ] && [ "$st" = proved ]; then
      printf 'proved\t%s\tproof\n' "$(_fix_locator_of_proof "${out#*$'\t'}")"; return 0
    fi
  else
    out="undetermined"$'\t'"no_candidate_in_env"; rc=2
  fi
  # not proved: the emit-and-observe fallback (#1188), when it is present
  if declare -F agmsg_token_locate_self >/dev/null 2>&1; then
    local fo frc=0
    fo="$(agmsg_token_locate_self "$team" "$agent")" || frc=$?
    case "$frc:${fo%%$'\t'*}" in
      0:proved) printf 'proved\t%s\temit_observe\n' "${fo#*$'\t'}"; return 0 ;;
      *) printf '%s\t%s\temit_observe\n' "${fo%%$'\t'*}" "${fo#*$'\t'}"; return "${frc:-2}" ;;
    esac
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
  local sid seats line team agent owner loc st payload via rc=0 any=0 failed=0
  sid="$(agmsg_instance_bare_sid "${AGMSG_SESSION_ID:-}" 2>/dev/null)"
  [ -n "$sid" ] || { echo "fix none:no_session_id" >&2; return 1; }
  seats="$(_fix_seats_of "$sid")"
  [ -n "$seats" ] || { echo "fix none:no_seat_for_this_session" >&2; return 1; }
  while IFS=$'\t' read -r team agent owner; do
    [ -n "$team" ] || continue
    any=1
    loc="$(_fix_locate "$team" "$agent")" || true
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
