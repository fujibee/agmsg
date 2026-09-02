#!/usr/bin/env bash
set -euo pipefail

# peek.sh — look at a named member's terminal screen without switching panes.
#
# Usage:
#   peek.sh <team> <name> [--lines N]
#
#   <team>     team the member is in
#   <name>     the member whose pane to read
#   --lines N  include scrollback: the driver decides what N means for its
#              backend (tmux: last N lines; herdr: the 'recent' source)
#
# Read-only. The member's placement record (run/spawn.<team>__<name>, written
# at placement time) names the terminal and the pane id; that terminal's driver
# is loaded and terminal_peek prints the pane text verbatim. The terminal comes
# from the RECORD, never from this caller's environment — an exported
# AGMSG_TERMINAL_DRIVER must not make us read a herdr pane id as a tmux one
# (v1 scope ruling: the override applies to resolution, never to something
# already placed).
#
# A terminal without an addressable pane (plain) refuses with
# "unsupported: <why>" on stderr and a non-zero exit — never a silent 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"          # agmsg_spawn_path
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/terminal-registry.sh"   # record scheme + driver load

die() { echo "peek: $*" >&2; exit 1; }

TEAM="${1:-}"; NAME="${2:-}"
[ -n "$TEAM" ] && [ -n "$NAME" ] \
  || die "Usage: peek.sh <team> <name> [--lines N]"
shift 2

PEEK_LINES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lines)
      PEEK_LINES="${2:-}"
      case "$PEEK_LINES" in
        ''|*[!0-9]*) die "--lines must be a whole number of lines" ;;
      esac
      shift 2
      ;;
    *) die "unknown option: $1" ;;
  esac
done

REC="$(agmsg_spawn_path "$TEAM" "$NAME")"
[ -f "$REC" ] || die "no placement record for '$TEAM/$NAME' — nothing here knows which pane is theirs (spawn writes it at launch; a hand-joined member gets one when a terminal-aware session names its pane)"

IFS=$'\t' read -r REF _PROJ _TYPE < "$REC" || true
[ -n "$REF" ] || die "placement record for '$TEAM/$NAME' has no pane id — a record with no id is not a placement (a bug in whatever wrote it)"

TERMINAL="$(agmsg_terminal_ref_terminal "$REF")"
BARE_ID="$(agmsg_terminal_ref_id "$REF")"
[ -n "$TERMINAL" ] && [ -n "$BARE_ID" ] \
  || die "placement record for '$TEAM/$NAME' did not resolve to a terminal and pane id (ref: '$REF')"

agmsg_terminal_load "$TERMINAL" \
  || die "cannot load terminal driver '$TERMINAL' recorded for '$TEAM/$NAME'"

# Last command on purpose: terminal_peek's output is the product (verbatim) and
# its exit status is ours — plain's "unsupported" 13 included.
if [ -n "$PEEK_LINES" ]; then
  terminal_peek "$BARE_ID" --lines "$PEEK_LINES"
else
  terminal_peek "$BARE_ID"
fi
