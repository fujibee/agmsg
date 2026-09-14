#!/usr/bin/env bash
# self-rename.sh — a seat fixes its own CLI SESSION NAME by typing the type's
# rename command into its own pane, once, early (#1081).
#
# The third identity cell is the CLI session name. No launch flag sets it after
# start (claude-code's -n is a launch-only flag; codex has none), and a
# hand-started or resumed seat never got one -- yet a person can always fix it by
# typing `/rename <name>`. This hook does that from the inside: a seat knows its
# team, its name, and (from the environment) the pane it is in, so it pokes the
# rename into its own pane.
#
# It is deliberately NOT modelled on self-name.sh's every-action naming, because
# typing into a live session is INVASIVE and its verification WINDOW is narrow:
#   - Invasive: `poke` seizes the keyboard. Doing that to oneself on a loop is how
#     a conversation gets wrecked. So this fires AT MOST ONCE per (seat, pane,
#     server generation); the persisted mark is what stops a second attempt, on
#     the next action AND in the next process.
#   - Narrow window: a name that can only be READ early (codex prints "Thread
#     name:" at the top of the TUI and it scrolls away) can only be VERIFIED
#     early. The window to verify and the window to rename are the same one, which
#     is also why it must run early -- before the /resume picker, before a person
#     grows used to a name. Two reasons, one design.
#
# Two-phase, because the keystroke is QUEUED and lands after the current turn:
#   action 1  observe my name. Correct already -> record ok, type nothing.
#             Unreadable (window gone) -> record why, type nothing (never rename
#             what cannot be verified). Wrong and readable -> poke once, mark
#             "attempted".
#   action 2  the mark says "attempted": the rename has had a turn to land, so
#             re-observe. Took -> ok. Could not read it (scrolled off, load) ->
#             the THIRD word poked_unverified -- typed, could not confirm, NEVER
#             "failed" on a screen we could not read. A title name still wrong ->
#             failed. Either way, no second poke.
#
# Readable and wrong is also where the keystroke is gated on agmsg_self_proof
# (#1206), the same proof `fix` requires before it writes: the placement-claim
# guard below only catches a pane already recorded as someone else's, and a
# pane nobody has claimed yet is not thereby proved to be this seat's. Only a
# `proved` verdict authorizes typing -- and the verdict alone is not enough:
# the proof's own returned locator (the driver's re-observation, never an
# echo of the candidate) must match, EXACTLY, the ref about to be poked. Proof
# without that match, or any other state, is recorded as skipped and nothing
# is poked.
#
# Two-tier opt-out, and it is VISIBLE on the mark, never silent: AGMSG_SELF_NAME=
# off stops the whole self-naming family; AGMSG_SELF_RENAME=off stops only the
# keystroke (more invasive than writing a label -- a person may accept the label
# and refuse the auto-typing).
#
# Never fails the caller: renaming is a side effect of the action. Every path
# returns 0.
#
#   agmsg_self_rename_on_action <team> <agent> [<type>]

[ -n "${_AGMSG_SELF_RENAME_SH:-}" ] && return 0
_AGMSG_SELF_RENAME_SH=1

_agmsg_self_rename_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SKILL_DIR:=$(cd "$_agmsg_self_rename_dir/../.." && pwd)}"
export SKILL_DIR

# Record the outcome on the mark, keyed to this pane+generation, and stop.
_agmsg_self_rename_record() {   # <team> <agent> <ref> <epoch> <result> <type>
  agmsg_role_session_mark_renamed "$1" "$2" "$3" "$4" "$5" "" "$6" 2>/dev/null || true
}

# agmsg_self_proof's own returned ref is the DRIVER's canonical id for the pane
# it re-observed -- NOT the caller's candidate echoed back, and for tmux that
# canonical id is deliberately bare (terminal_pane_process_observe strips the
# instance before returning it; see the driver's own ops.sh). $ref elsewhere in
# this file is composed from agmsg_terminal_self_env's id, which for tmux DOES
# carry the instance ("<socket>:<pane>"). The two are honestly different
# strings for the exact same pane, so comparing them as-is would refuse every
# real tmux poke -- the same shape self-fix.sh's own _fix_locator_of_proof
# exists to close (#1152); this is that same reattachment, kept local to this
# file rather than shared, so a proof that DOES already carry its own instance
# (a future driver, or herdr's HERDR_SOCKET_PATH) is left alone.
_agmsg_self_rename_locator_of_proof() {   # <canonical-ref, e.g. "tmux:%3">
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

agmsg_self_rename_on_action() {
  local team="${1:-}" agent="${2:-}" type="${3:-}"
  [ -n "$team" ] && [ -n "$agent" ] || return 0

  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/type-registry.sh" 2>/dev/null || return 0
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/terminal-registry.sh" 2>/dev/null || return 0
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/role-session.sh" 2>/dev/null || return 0
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/team-status.sh" 2>/dev/null || return 0

  # The acting commands (send/inbox/history) do not carry the seat's CLI type, so
  # resolve it from the role-session record the join/actas flow already wrote. No
  # record, no type -> we cannot know the rename command, so do nothing.
  [ -n "$type" ] || type="$(agmsg_role_session_get "$team" "$agent" type 2>/dev/null || true)"
  [ -n "$type" ] || return 0

  # Only a type that declares how it renames itself does anything (#1081). The
  # datum, not the type name: a type gains this by adding rename_cmd.
  local rename_cmd
  rename_cmd="$(agmsg_type_get "$type" rename_cmd 2>/dev/null || true)"
  [ -n "$rename_cmd" ] || return 0

  # Where am I -- environment only, no terminal call yet.
  local here terminal id epoch ref
  here="$(agmsg_terminal_self_env)"
  [ -n "$here" ] || return 0                 # plain, or no terminal: no pane
  terminal="${here%%	*}"; here="${here#*	}"
  id="${here%%	*}"; epoch="${here#*	}"
  ref="$(agmsg_terminal_ref "$terminal" "$id")"

  # PLACEMENT GUARD (#1112, same rule as terminal-registry.sh's #1114 guard on
  # the naming/marking/record path -- this is the SECOND call site that turns
  # the raw environment into a pane, and it was unguarded). A codex seat
  # inherits its environment from a shared app-server daemon, so a seat whose
  # own resolution is broken can resolve into ANOTHER seat's pane; measured
  # live, that happened here and the seat stopped short only because the
  # other pane's title was not readable. Had it been readable and different
  # from this seat's expected name, this function would have TYPED /rename
  # into a live pane belonging to someone else -- more invasive than the
  # wrong RECORD #1114 was written to prevent. So before anything else: if
  # the resolved ref is another seat's placement record, this action never
  # happened as far as rename is concerned -- no poke, and no mark, so the
  # next action re-checks rather than filing this pane+generation as "done"
  # on a pane that was never this seat's.
  if ! declare -F agmsg_spawn_path >/dev/null 2>&1 \
     && [ -n "${SKILL_DIR:-}" ] && [ -r "$SKILL_DIR/scripts/lib/actas-lock.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$SKILL_DIR/scripts/lib/actas-lock.sh" 2>/dev/null || true
  fi
  if declare -F agmsg_spawn_path >/dev/null 2>&1 && declare -F _agmsg_placement_claimed_by >/dev/null 2>&1; then
    local _claimed_by="" _claim_rc=0
    _claimed_by="$(_agmsg_placement_claimed_by "$ref" "$team" "$agent")" || _claim_rc=$?
    # rc != 0 is UNDECIDABLE (this seat's own ref could not be read as a pane),
    # not "unclaimed" -- #1114's own rule, and the same fail-closed direction
    # applies here: whether it is safe to type cannot be told, so it does not.
    if [ "$_claim_rc" -ne 0 ] || [ -n "$_claimed_by" ]; then
      return 0
    fi
  fi

  # The mark: what did this seat already do at THIS pane+generation?
  local have hr he hres phase=first
  have="$(agmsg_role_session_renamed "$team" "$agent")"
  if [ -n "$have" ]; then
    hr="${have%%	*}"; have="${have#*	}"; he="${have%%	*}"; hres="${have#*	}"
    if [ "$hr" = "$ref" ] && [ "$he" = "$epoch" ]; then
      case "$hres" in
        attempted) phase=confirm ;;   # poked last time; confirm now, do not re-poke
        *) return 0 ;;                # ok / failed / poked_unverified / skipped: done
      esac
    fi
    # a mark for a DIFFERENT pane/generation is stale: treat as first, below.
  fi

  # Opt-out, recorded VISIBLY (only relevant when we would otherwise act now).
  if [ "$phase" = first ] \
     && { [ "${AGMSG_SELF_NAME:-on}" = off ] || [ "${AGMSG_SELF_RENAME:-on}" = off ]; }; then
    _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" "skipped:self_rename_off" "$type"
    return 0
  fi

  # Observe my own session name. Loading the driver + one observation is the cost;
  # it happens at most twice ever (the two phases), then the mark ends it.
  agmsg_terminal_load "$terminal" 2>/dev/null || return 0
  local expected="$team-$agent" raw title observed
  raw="$(agmsg_team_observe_loaded "$id" 2>/dev/null)"
  title="$(printf '%s' "$raw" | awk -F '\t' 'NR==1{print $4}')"
  observed="$(agmsg_cli_session_observed "$type" "$title" "$id" 2>/dev/null)"

  if [ "$phase" = confirm ]; then
    # The rename has had a turn to land. Judge, but never call a screen we could
    # not read a failure.
    case "$observed" in
      "$expected") _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" ok "$type" ;;
      unknown:*|n/a:*) _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" poked_unverified "$type" ;;
      *)
        case "$(agmsg_type_get "$type" session_name_source 2>/dev/null || true)" in
          screen:*) _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" poked_unverified "$type" ;;
          *)        _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" failed "$type" ;;
        esac
        ;;
    esac
    return 0
  fi

  # phase=first
  case "$observed" in
    "$expected")
      # Already correct (e.g. claude-code born with -n). Nothing to type.
      _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" ok "$type" ;;
    unknown:*|n/a:*)
      # Cannot read the name now, so cannot verify a rename: do NOT type blindly.
      _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" "skipped:${observed}" "$type" ;;
    *)
      # Readable and wrong: before typing, require the same proof `fix` requires
      # before it writes (#1206). The claim guard above only catches a pane
      # already RECORDED as someone else's; a pane nobody has claimed yet is not
      # thereby proved to be this seat's -- an inherited environment can still
      # name a pane this process never ran in. Load self-proof.sh the same
      # lazy, best-effort way the claim guard above loads actas-lock.sh, since
      # this is the same kind of already-loaded-elsewhere situation.
      if ! declare -F agmsg_self_proof >/dev/null 2>&1 \
         && [ -n "${SKILL_DIR:-}" ] && [ -r "$SKILL_DIR/scripts/lib/self-proof.sh" ]; then
        # shellcheck disable=SC1090,SC1091
        . "$SKILL_DIR/scripts/lib/self-proof.sh" 2>/dev/null || true
      fi
      local _proof_out="" _proof_rc=0 _proof_state="unsupported"
      if declare -F agmsg_self_proof >/dev/null 2>&1; then
        _proof_out="$(agmsg_self_proof "$team" "$agent" "$id")" || _proof_rc=$?
        _proof_state="${_proof_out%%	*}"
      else
        _proof_rc=3   # self-proof.sh unavailable: the same as an unsupported proof.
      fi
      if [ "$_proof_rc" -ne 0 ] || [ "$_proof_state" != proved ]; then
        # Not proved (or the proof itself is unavailable): never type into a pane
        # we cannot show is our own. Same fail-closed direction as the claim
        # guard above -- record why and leave the mark on a terminal "skipped"
        # result rather than "attempted", so this generation is not retried.
        _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" "skipped:unproved:${_proof_state:-no_proof}" "$type"
        return 0
      fi
      # A `proved` state is not, by itself, proof about THIS pane: self-proof.sh
      # revalidates the candidate through the driver's own observation and
      # returns that driver's canonical ref, never the caller's candidate
      # echoed back (its own stated contract -- reading your own input back as
      # a confirmation is how a proof becomes a mirror). $ref, above, is a
      # SEPARATE composition of the same environment, made before the proof
      # ran. Nothing forces the two to agree except both call sites happening
      # to compose the same driver + id the same way today -- and a caller
      # that only reads the STATE word, never the payload, would still poke if
      # that ever drifted, or if a future driver's canonical id normalizes
      # differently from what $ref used. So the payload is not optional: only
      # an EXACT match between what was proved and what is about to be poked
      # authorizes the keystroke.
      local _proof_locator
      _proof_locator="$(_agmsg_self_rename_locator_of_proof "${_proof_out#*	}")"
      if [ "$_proof_locator" != "$ref" ]; then
        _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" "skipped:unproved:locator_mismatch" "$type"
        return 0
      fi
      # Readable, wrong, and proved for exactly this pane: type the rename
      # ONCE, and mark "attempted" so the next action confirms instead of
      # poking again.
      if terminal_poke "$id" "$rename_cmd $expected" >/dev/null 2>&1; then
        _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" attempted "$type"
      else
        _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" "failed:poke" "$type"
      fi
      ;;
  esac
  return 0
}
