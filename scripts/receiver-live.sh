#!/usr/bin/env bash
# receiver-live.sh — is the actas receiver for (team, agent) still live?
#
# Reads the ready sentinel written by watch.sh when an exclusive (actas)
# watcher attaches (see agmsg_ready_path / #108) and checks that the owner
# process is still running.
#
# Origin: proposed in fujibee/agmsg#372 by @u-ichi as a shared liveness
# primitive for external delivery daemons and spawn readiness (#338 Gap 2).
# This copy keeps that contract and adds a composite-instance-id fallback
# so it works with today's watch.sh ready tokens ("<session_id>.<pid>",
# see instance-id.sh / #93) in addition to an explicit "pid=N" field.
#
# Usage:
#   receiver-live.sh <team> <agent>        # exit 0 if live, non-zero if not; silent
#   receiver-live.sh <team> <agent> --pid  # print the live pid on stdout when live
#
# Exit status: 0 = live, 1 = missing/stale/not-alive.
set -euo pipefail

TEAM="${1:?team required}"
AGENT="${2:?agent required}"
PRINT_PID=0
if [ "${3:-}" = "--pid" ]; then
  PRINT_PID=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"

ready="$(SKILL_DIR="$SKILL_DIR" agmsg_ready_path "$TEAM" "$AGENT")"
[ -f "$ready" ] || exit 1

# Preferred form from #372: an explicit pid=N field anywhere in the file.
pid="$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$ready" | head -1 | tr -d '\r')"

# Fallback: watch.sh today stamps the composite instance id
# ("<session_id>.<pid>") as the sole line. Trailing numeric component is the
# owner process (same pid kill -0 gate actas_lock_sid_alive uses).
if [ -z "$pid" ]; then
  token="$(tr -d '\r\n' < "$ready" 2>/dev/null || true)"
  case "$token" in
    *.*)
      trail="${token##*.}"
      case "$trail" in
        ''|*[!0-9]*) ;;
        *) pid="$trail" ;;
      esac
      ;;
  esac
fi

case "$pid" in
  ''|*[!0-9]*|0) exit 1 ;;
esac

kill -0 "$pid" 2>/dev/null || exit 1

if [ "$PRINT_PID" -eq 1 ]; then
  printf '%s\n' "$pid"
fi
exit 0
