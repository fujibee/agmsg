#!/usr/bin/env bash
# fix -- a seat establishes where it is and repairs its own identity cells there.
# No arguments (see scripts/lib/self-fix.sh for why). Run it from the seat.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SKILL_DIR="${SKILL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/self-fix.sh"
# The session this shell belongs to: what the CLI exports for its own session.
# It identifies the seat's LOCKS (which roles this session holds); it says
# nothing about where the seat is -- that is the proof's job.
export AGMSG_SESSION_ID="${AGMSG_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-}}}"
[ -n "$AGMSG_SESSION_ID" ] || { echo "fix none:no_session_id (no AGMSG_SESSION_ID, CLAUDE_CODE_SESSION_ID or CODEX_THREAD_ID in this shell)" >&2; exit 1; }
rc=0
agmsg_fix_run "$@" || rc=$?
exit "$rc"
