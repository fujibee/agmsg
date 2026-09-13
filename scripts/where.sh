#!/usr/bin/env bash
set -euo pipefail

# Where is THIS session — without the caller ever naming a terminal.
#
# #1171: asked to report its pane, an agent under herdr ran a raw `tmux
# display-message`, got a connection error (there was no tmux server), and
# reported that AS ITS OWN PLACEMENT: "this session is not attached to a
# pane". A failed read of the wrong terminal became a confident negative
# about the caller. That happened because SKILL.md taught tmux's syntax and
# nothing else, and no script exposed a driver-neutral way to ask.
#
# This script is that way. It goes through the same driver auto-detection
# every other self-placement path already uses (actas' self-naming, spawn's
# placement resolution) — the caller never picks a terminal, and never sees
# one to pick. A terminal name in the OUTPUT is diagnostic only, never
# something the caller is meant to branch on.
#
# Usage: where.sh [session_id]
#   session_id — optional. Only herdr's fallback path consults it; herdr's
#   preferred HERDR_PANE_ID path and tmux's $TMUX_PANE need none. Omit it if
#   the caller does not have one.
#
# Output (stdout, one line, key=value):
#   resolved=true placement=<terminal>:<id> container=<container>
#     A real, addressable pane was identified. `container` is best-effort
#     extra context (e.g. the window/tab it lives in); if the driver could
#     not answer THAT sub-question, container names why
#     (unknown:<reason>) — that failure is about the container lookup, not
#     about whether this session has a pane, which is already settled.
#   resolved=true placement=none reason=no_addressable_pane terminal=<name>
#     A GENUINE negative: <name> was identified as this session's terminal,
#     and it confirmed it has no addressable pane (a plain OS terminal).
#   resolved=false reason=<text>
#     Placement could NOT be determined. <text> names every terminal that
#     was actually asked and why it did not answer (e.g. "under a terminal
#     but cannot identify this pane to name it — tmux: \$TMUX_PANE is
#     unset — cannot identify this pane"). This is never collapsed into
#     "no pane" — that claim requires resolved=true.
#
# Exit code mirrors `resolved`: 0 when true, 1 when false.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/terminal-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/team-status.sh"

SID="${1:-}"

errf="$(mktemp "${TMPDIR:-/tmp}/agmsg-where.XXXXXX")" || errf=/dev/null
rc=0
resolved="$(agmsg_terminal_resolve_name "$SID" 2>"$errf")" || rc=$?

if [ "$rc" -ne 0 ]; then
  reason=""
  if [ "$errf" != /dev/null ] && [ -s "$errf" ]; then
    reason="$(cat "$errf" 2>/dev/null || true)"
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  printf 'resolved=false reason=%s\n' "${reason:-could not determine placement for this session}"
  exit 1
fi
[ "$errf" = /dev/null ] || rm -f "$errf"

# agmsg_terminal_resolve_name prints exactly "<terminal>\t<id>" on success.
terminal="${resolved%%$'\t'*}"
id="${resolved#*$'\t'}"

if [ "$id" = '-' ]; then
  printf 'resolved=true placement=none reason=no_addressable_pane terminal=%s\n' "$terminal"
  exit 0
fi

# terminal_where's own failures are named already (agmsg_team_location prints
# unknown:<reason>) — that is about the CONTAINER sub-question, not about
# whether this session has a pane, which the branch above already settled.
location="$(agmsg_team_location "$terminal" "$id")"
container="${location##*$'\t'}"
printf 'resolved=true placement=%s:%s container=%s\n' "$terminal" "$id" "$container"
exit 0
