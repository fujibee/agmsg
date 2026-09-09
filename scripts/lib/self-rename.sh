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
      # Readable and wrong: type the rename ONCE, and mark "attempted" so the next
      # action confirms instead of poking again.
      if terminal_poke "$id" "$rename_cmd $expected" >/dev/null 2>&1; then
        _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" attempted "$type"
      else
        _agmsg_self_rename_record "$team" "$agent" "$ref" "$epoch" "failed:poke" "$type"
      fi
      ;;
  esac
  return 0
}
