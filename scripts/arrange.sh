#!/usr/bin/env bash
set -euo pipefail

# Declaratively place one member's pane relative to another member's pane.
# Identity/placement resolution belongs here; terminal drivers receive ids only.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/terminal-registry.sh"

die() { echo "arrange: $*" >&2; exit 1; }

TEAM="${1:-}"; SOURCE="${2:-}"; INTENT="${3:-}"; TARGET="${4:-}"
[ -n "$TEAM" ] && [ -n "$SOURCE" ] && [ -n "$INTENT" ] && [ -n "$TARGET" ] \
  || die "Usage: arrange.sh <team> <agent> <place_below|place_right> <anchor-agent>"
[ "$SOURCE" != "$TARGET" ] || die "source and anchor must be different members"
case "$INTENT" in place_below|place_right) : ;; *) die "unknown intent '$INTENT' (expected place_below or place_right)" ;; esac

_placement() {
  local agent="$1" rec ref terminal id
  rec="$(agmsg_spawn_path "$TEAM" "$agent")"
  [ -f "$rec" ] || { echo "arrange: no placement record for '$TEAM/$agent'" >&2; return 1; }
  IFS=$'\t' read -r ref _ _ < "$rec" || true
  terminal="$(agmsg_terminal_ref_terminal "$ref" 2>/dev/null)" || terminal=""
  id="$(agmsg_terminal_ref_id "$ref" 2>/dev/null)" || id=""
  [ -n "$terminal" ] && [ -n "$id" ] \
    || { echo "arrange: placement record for '$TEAM/$agent' is unreadable" >&2; return 1; }
  PLACEMENT_TERMINAL="$terminal"
  PLACEMENT_ID="$id"
}

PLACEMENT_TERMINAL=""; PLACEMENT_ID=""
_placement "$SOURCE" || exit $?
SOURCE_TERMINAL="$PLACEMENT_TERMINAL"; SOURCE_ID="$PLACEMENT_ID"
_placement "$TARGET" || exit $?
TARGET_TERMINAL="$PLACEMENT_TERMINAL"; TARGET_ID="$PLACEMENT_ID"
[ "$SOURCE_TERMINAL" = "$TARGET_TERMINAL" ] \
  || die "members are in different terminals ('$SOURCE_TERMINAL' and '$TARGET_TERMINAL')"
agmsg_terminal_has "$SOURCE_TERMINAL" capabilities arrange \
  || die "terminal '$SOURCE_TERMINAL' cannot arrange panes"
agmsg_terminal_load "$SOURCE_TERMINAL" \
  || die "cannot load terminal driver '$SOURCE_TERMINAL'"

# Last command: preserve the driver's moved/unchanged/error token and exit code.
terminal_arrange "$SOURCE_ID" "$INTENT" "$TARGET_ID"
