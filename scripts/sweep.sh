#!/usr/bin/env bash
set -euo pipefail

# Explicit leader-side fan-out. Nothing sources or invokes this entry point
# automatically; running it is the operator's blast-radius decision.

if [ "$#" -ne 1 ]; then
  echo 'Usage: sweep.sh <team>' >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAM="$1"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1
[ -r "$SKILL_DIR/teams/$TEAM/config.json" ] \
  || { echo "sweep: team not found: $TEAM" >&2; exit 1; }

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/terminal-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sweep.sh"

agmsg_sweep_run "$TEAM"
