#!/usr/bin/env bash
# self-name.sh — a seat names its own pane when it ACTS, if it is not named.
#
# The problem (1.3.0 requirement): every live seat's terminal id/name must be
# right in any state. Identifying a seat from the outside cannot reach every
# state -- a seat started by hand has no placement record, a resumed seat's
# record points at a pane it no longer sits in -- so `team --fix` skips
# exactly the seats that need it. Inverting the direction removes the
# question: the seat itself knows its team, its name and (from its environment)
# the pane it is in, so when it does anything through agmsg it can make sure
# its pane carries its name. The moment such a seat sends or reads, it is
# correct, whatever the records say.
#
# The self-naming primitive already existed (agmsg_terminal_name_self), but
# every one of its five callers was a Claude Code path (SessionStart,
# actas-claim, join, watch, check-inbox), so a codex seat never passed
# through it. This hook is tied to the ACTION instead, and is called from the
# commands a seat of any type runs: send, inbox, history. The five paths stay;
# they and this hook call the same primitive and leave the same mark, so
# whichever runs first, the state is the same.
#
# COST is the condition (measured 2026-09-08 on the shared workstation):
#   history.sh 0.8-1.1 s, inbox.sh 0.2-0.3 s   the commands this rides on
#   mark check (one file read + compare)         0.22 ms
#   naming (one terminal round trip)            10-30 ms, tmux or herdr
# So the common case costs nothing anyone can see, and the terminal is called
# once per (seat, pane, server generation).
#
# THE MARK LIES in two ways, and this is what is done about each:
#   - the pane was closed and another seat now sits in it: that seat has no
#     mark for this pane (its own record names another pane, or nothing), so
#     it names the pane for itself on its first action, overwriting the stale
#     name. The old seat, if it acts again from elsewhere, finds its mark
#     naming a pane it is not in, and names the new one.
#   - the terminal server restarted and forgot the name: the mark carries the
#     server generation as the environment shows it (tmux: the pid in $TMUX;
#     herdr: the socket file's inode+ctime, recreated at server start), so a
#     restart makes the mark not match and the seat names itself again.
#   BLIND SPOT, stated rather than papered over: a name removed while the
#   server generation and the pane are unchanged (someone renamed the pane by
#   hand, or a terminal that clears names without restarting) is not seen
#   here -- the mark says named, nothing in the environment says otherwise,
#   and no terminal call is made. `team --fix` (which observes the terminal)
#   or `rename` repairs that case; this hook does not claim to.
#
# Never fails the caller: naming is a side effect of the action, the action is
# the thing. Every failure path returns 0 after one line on stderr.
#
#   agmsg_self_name_on_action <team> <agent> [<project>] [<type>]

[ -n "${_AGMSG_SELF_NAME_SH:-}" ] && return 0
_AGMSG_SELF_NAME_SH=1

_agmsg_self_name_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SKILL_DIR:=$(cd "$_agmsg_self_name_dir/../.." && pwd)}"
export SKILL_DIR

agmsg_self_name_on_action() {
  local team="${1:-}" agent="${2:-}" project="${3:-}" type="${4:-}"
  [ -n "$team" ] && [ -n "$agent" ] || return 0
  # Opt-out for a caller that must not touch a terminal at all (tests that run
  # under a real tmux, batch tooling). Same switch as the existing naming paths
  # use for the visible label; here it turns the whole hook off.
  [ "${AGMSG_SELF_NAME:-on}" != off ] || return 0

  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/terminal-registry.sh" 2>/dev/null || return 0
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/role-session.sh" 2>/dev/null || return 0

  # Fast half: where am I (environment only), and does my mark say so?
  local here terminal id epoch have ref
  here="$(agmsg_terminal_self_env)"
  [ -n "$here" ] || return 0                 # no pane to name (plain, or no terminal)
  terminal="${here%%	*}"; here="${here#*	}"
  id="${here%%	*}"; epoch="${here#*	}"
  ref="$(agmsg_terminal_ref "$terminal" "$id")"
  have="$(agmsg_role_session_named "$team" "$agent")"
  if [ -n "$have" ] && [ "${have%%	*}" = "$ref" ] && [ "${have#*	}" = "$epoch" ]; then
    return 0                                 # named, by a mark that matches where I am
  fi

  # Slow half, once: name the pane through the same primitive every other
  # path uses; it leaves the mark on success. An empty session id is right
  # here: both drivers identify the pane from the environment now, and the
  # acting commands have no session id at hand.
  agmsg_terminal_name_self_safe "" "$team" "$agent" "$project" "$type" || true
  return 0
}
