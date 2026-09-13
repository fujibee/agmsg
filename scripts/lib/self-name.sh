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
#   - the name was removed while the server generation and the pane are
#     unchanged (someone renamed the pane by hand, or a terminal that clears
#     names without restarting): the fast half asks the pane which agmsg label
#     it carries, so the missing name IS seen and the seat names itself again.
#     This was a stated BLIND SPOT until #1130 -- nothing in the environment
#     changes, so a check that only read the environment could not know -- and
#     it is closed by the same read that closed the bigger one below.
#   - the environment is not this seat's at all: a seat whose commands run
#     under a shared app-server inherits the daemon's pane, so the environment,
#     and the mark and record written from it, all agree on somebody else's
#     pane. That seat is perfectly self-consistent and used to short-circuit
#     forever (#1130, measured: eleven hours of acting, the record never
#     moved). The same read catches it, because the daemon's pane carries the
#     daemon owner's label, not this seat's.
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

# Does the pane the ENVIRONMENT names actually carry this seat's label? (#1130)
#
# The fast half exists to skip work when everything is already in place, and it
# decided that from the mark, the record and the environment. All three can agree
# and all three can be WRONG together: a seat whose commands run under a shared
# app-server inherits the daemon's pane, so the environment answers with somebody
# else's pane; whatever was written from that answer -- the mark, the record --
# agrees with it by construction. Such a seat is perfectly self-consistent and
# short-circuits forever. Measured on this fleet: a seat's record and mark both
# named another seat's pane and had not moved in eleven hours of that seat acting,
# because the hook returned here every single time. The label path added in #1112
# sits in the slow half and was never reached.
#
# So the short-circuit is no longer keyed only on the input it was built to
# distrust. This asks the pane itself, through the per-pane read the confirmation
# in #1112 uses: if the environment's pane carries this seat's label, the
# environment agreed with something that is not the environment and the skip is
# earned. If it carries someone else's label, or none, or cannot be read, it is
# not -- and the slow half runs, where the label resolves the right pane.
#
# It costs one per-pane query on the FAST path only (it is the last condition, so
# a seat that already has work to do pays nothing extra). Measured on this
# machine: `herdr pane get` 25 ms, against 71 ms for the `pane list` a full
# re-resolution would cost; tmux answers `display-message` on a local socket.
# That is the price of not trusting a value we decided not to trust.
#
# Any answer other than "carries my label" is a reason to do the work, INCLUDING
# an unreadable one: a read that failed is not a pane that matched, and treating
# it as one is the fold this codebase keeps paying for.
_agmsg_self_name_env_corroborated() {   # <terminal> <id> <team> <agent>
  local terminal="$1" id="$2" want="$3:$4" seen
  agmsg_terminal_load "$terminal" >/dev/null 2>&1 || return 1
  declare -F terminal_label_of >/dev/null 2>&1 || return 1
  seen="$(terminal_label_of "$id" 2>/dev/null)" || return 1
  [ "$seen" = "$want" ]
}

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
  # agmsg_spawn_path: to check (fast half) and, via the primitive, write (slow
  # half) the placement record. A seat that names its pane but is never recorded
  # looks correct and is unreachable (#1109); this hook is the one caller entitled
  # to claim placement, because it runs AS the seat, IN its own pane, resolved from
  # that process's own environment -- exactly the case the primitive's record
  # comment (terminal-registry.sh) reserves for the caller to assert. Best-effort:
  # if it will not source, the fast-half check below is skipped and the slow half's
  # own lazy load writes the record, so naming still proceeds.
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/actas-lock.sh" 2>/dev/null || true

  # Fast half: where am I (environment only), and does my mark say so?
  local here terminal id epoch have ref
  here="$(agmsg_terminal_self_env)"
  [ -n "$here" ] || return 0                 # no pane to name (plain, or no terminal)
  terminal="${here%%	*}"; here="${here#*	}"
  id="${here%%	*}"; epoch="${here#*	}"
  ref="$(agmsg_terminal_ref "$terminal" "$id")"
  have="$(agmsg_role_session_named "$team" "$agent")"
  # The fast half short-circuits only when BOTH halves are already in place: the
  # naming mark matches this pane AND the placement record points here too. Before
  # #1109 it trusted the mark alone, so a seat named once but never recorded (every
  # hand-started seat) short-circuited past the write forever. Reading the record
  # is one file read, the same order as the mark read.
  local recorded="" rec=""
  if declare -F agmsg_spawn_path >/dev/null 2>&1; then
    rec="$(agmsg_spawn_path "$team" "$agent" 2>/dev/null || true)"
    [ -n "$rec" ] && [ -f "$rec" ] && IFS=$'\t' read -r recorded _ < "$rec" 2>/dev/null || true
  fi
  if [ -n "$have" ] && [ "${have%%	*}" = "$ref" ] && [ "${have#*	}" = "$epoch" ] \
     && [ "$recorded" = "$ref" ] \
     && _agmsg_self_name_env_corroborated "$terminal" "$id" "$team" "$agent"; then
    return 0                                 # named AND recorded at where I am
  fi

  # #1137: none of send.sh/inbox.sh/history.sh pass project or type -- they
  # never had them to pass, not merely forgot to -- so a record this hook
  # writes had two empty fields, and arrange.sh (which requires both) refused
  # any seat whose ONLY placement record came from acting rather than from
  # spawn/actas/SessionStart (measured live: 12 of 36 records). Resolve them
  # here, the same way whoami.sh does for the identical question, rather than
  # threading two new arguments through three callers that have no better
  # source for them than this process's own cwd and type anyway. Only when
  # the caller did not supply them -- a caller that already knows better
  # (every other path through the primitive) is never second-guessed.
  if [ -z "$project" ] || [ -z "$type" ]; then
    # Best-effort, matching every other lazy source in this function: a
    # failure here must not block the naming this hook exists to do, so a
    # record written with what could be resolved is better than none, and
    # the record's own project/type stay only as good as this detection is.
    if [ -z "$type" ]; then
      # shellcheck disable=SC1091
      . "$SKILL_DIR/scripts/lib/type-registry.sh" 2>/dev/null || true
      # shellcheck disable=SC1091
      . "$SKILL_DIR/scripts/lib/compat.sh" 2>/dev/null || true
      # shellcheck disable=SC1091
      if . "$SKILL_DIR/scripts/lib/detect-cli-type.sh" 2>/dev/null \
        && declare -F agmsg_detect_cli_type >/dev/null 2>&1; then
        type="$(agmsg_detect_cli_type 2>/dev/null || true)"
      fi
    fi
    if [ -z "$project" ]; then
      # shellcheck disable=SC1091
      if . "$SKILL_DIR/scripts/lib/resolve-project.sh" 2>/dev/null \
        && declare -F agmsg_resolve_project >/dev/null 2>&1; then
        project="$(agmsg_resolve_project "$(pwd)" "$type" "$team" 2>/dev/null || true)"
      fi
    fi
  fi

  # Slow half, once: name the pane through the same primitive every other path
  # uses, and -- the #1109 fix -- record this pane as the seat's placement. The
  # `record` claim is legitimate here and only here among the label writers (see
  # the sourcing comment above); every other caller of the primitive still passes
  # five args and only relabels. It leaves the mark on success. An empty session
  # id is right here: both drivers identify the pane from the environment now, and
  # the acting commands have no session id at hand.
  agmsg_terminal_name_self_safe "" "$team" "$agent" "$project" "$type" record || true
  return 0
}
