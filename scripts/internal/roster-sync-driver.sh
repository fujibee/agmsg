#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/roster-journal.sh"

operation="${1:?Missing operation}"; team="${2:?Missing team}"
server="${3:?Missing server id}"; remote="${4:?Missing remote team id}"
protocol="${5:?Missing protocol version}"; shift 5
# The caller supplies the roster path; it derives it from the connection root and
# hands over one file. The fallback below is for running this driver DIRECTLY —
# by hand, or from a test — on a single-machine install where the skill directory
# is the connection root. It is not a location this driver should be working out
# on behalf of the engine: a second machine keeps its teams somewhere else
# entirely, and guessing here is what made an existing roster look missing.
config="${AGMSG_SYNC_LOCAL_ROSTER_FILE:-$SKILL_DIR/teams/$team/config.json}"
team_dir="$(cd "$(dirname "$config")" && pwd)"

agmsg_lock_acquire "$team_dir"
# agmsg_lock_acquire already installs EXIT cleanup and exit-on-INT/TERM traps.
# Keep those handlers: replacing them with release-only handlers would let a
# signal return into this critical section after the lock had been dropped.
trap 'agmsg_lock_release; exit 129' HUP
agmsg_roster_ensure "$team_dir" "$config"

node_bin="${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"
"$node_bin" "$SCRIPT_DIR/roster-sync.mjs" "$operation" "$config" \
  "$server" "$remote" "$protocol" "$@"
case "$operation" in
  reconcile|apply) agmsg_roster_project_config "$team_dir" "$config" ;;
esac
