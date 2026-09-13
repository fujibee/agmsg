#!/usr/bin/env bash
set -euo pipefail

# Arrange one member's pane relative to an anchor pane. place_below and
# place_right are idempotent; swap is not — calling swap twice swaps back.
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
  || die "Usage: arrange.sh <team> <agent> <place_below|place_right|swap> <anchor-ref>"
case "$INTENT" in
  place_below|place_right|swap) : ;;
  *) die "unknown intent '$INTENT' (expected place_below, place_right, or swap)" ;;
esac

_placement() {
  local agent="$1" rec ref terminal id project type
  rec="$(agmsg_spawn_path "$TEAM" "$agent")"
  [ -f "$rec" ] || { echo "arrange: no placement record for '$TEAM/$agent'" >&2; return 1; }
  IFS=$'\t' read -r ref project type _fence < "$rec" || true
  terminal="$(agmsg_terminal_ref_terminal "$ref" 2>/dev/null)" || terminal=""
  id="$(agmsg_terminal_ref_id "$ref" 2>/dev/null)" || id=""
  [ -n "$terminal" ] && [ -n "$id" ] \
    || { echo "arrange: placement record for '$TEAM/$agent' is unreadable" >&2; return 1; }
  PLACEMENT_TERMINAL="$terminal"
  PLACEMENT_ID="$id"
  PLACEMENT_PROJECT="$project"
  PLACEMENT_TYPE="$type"
}

PLACEMENT_TERMINAL=""; PLACEMENT_ID=""; PLACEMENT_PROJECT=""; PLACEMENT_TYPE=""
_placement "$SOURCE" || exit $?
SOURCE_TERMINAL="$PLACEMENT_TERMINAL"; SOURCE_ID="$PLACEMENT_ID"
SOURCE_PROJECT="$PLACEMENT_PROJECT"; SOURCE_TYPE="$PLACEMENT_TYPE"

# The source remains a roster member: its placement record is an address, not
# proof that the registration still exists. The anchor is deliberately not
# looked up in the roster; a terminal pane may belong to another team or to a
# plain shell. Its reference is validated by the shared terminal-ref parser.
[ -n "$SOURCE_PROJECT" ] && [ -n "$SOURCE_TYPE" ] \
  || die "placement record for '$TEAM/$SOURCE' is missing project or type"
if ! "$SCRIPT_DIR/identities.sh" "$SOURCE_PROJECT" "$SOURCE_TYPE" \
    | awk -F '\t' -v team="$TEAM" -v agent="$SOURCE" \
        '$1 == team && $2 == agent { found=1 } END { exit found ? 0 : 1 }'; then
  die "source '$TEAM/$SOURCE' is not a registered member"
fi

ANCHOR_TERMINAL=""; ANCHOR_ID=""
ANCHOR_TERMINAL="$(agmsg_terminal_ref_terminal "$TARGET" 2>/dev/null)" || ANCHOR_TERMINAL=""
ANCHOR_ID="$(agmsg_terminal_ref_id "$TARGET" 2>/dev/null)" || ANCHOR_ID=""
[ -n "$ANCHOR_TERMINAL" ] && [ -n "$ANCHOR_ID" ] \
  || die "anchor reference '$TARGET' did not resolve to a terminal and pane id"

[ "$SOURCE_TERMINAL" = "$ANCHOR_TERMINAL" ] \
  || die "source and anchor are in different terminals ('$SOURCE_TERMINAL' and '$ANCHOR_TERMINAL')"
case "$INTENT" in
  place_below|place_right)
    [ "$SOURCE_ID" != "$ANCHOR_ID" ] \
      || die "source and anchor must be different panes"
    ;;
esac
agmsg_terminal_has "$SOURCE_TERMINAL" capabilities arrange \
  || die "terminal '$SOURCE_TERMINAL' cannot arrange panes"
agmsg_terminal_load "$SOURCE_TERMINAL" \
  || die "cannot load terminal driver '$SOURCE_TERMINAL'"

# Last command: preserve the driver's moved/unchanged/error token and exit code.
terminal_arrange "$SOURCE_ID" "$INTENT" "$ANCHOR_ID"
