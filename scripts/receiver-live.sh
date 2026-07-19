#!/usr/bin/env bash
# receiver-live.sh — is the exclusive (actas) receiver for (team, agent) live?
#
# Exclusive watchers (watch.sh with ACTIVE_NAME set) write:
#   1. run/watch.<session_token>.pid  — the watcher process itself (first)
#   2. run/ready.<team>__<agent>      — content = <session_token> (second)
# See watch.sh / agmsg_ready_path / #108. Broad (non-actas) watchers never
# write a ready sentinel; they are outside this helper's scope.
#
# Origin: fujibee/agmsg#372 by @u-ichi proposed a ready-file + kill -0 helper.
# This copy keeps the ready-path contract and extends it so the process we
# probe is the WATCHER (watch.<token>.pid), not the agent CLI pid embedded in
# a composite instance id. Treating the composite trailing digits as the
# watcher pid is wrong: that component is the agent process (#93), so a dead
# watcher with a live agent would false-alive. Credit #372; extension is for
# accurate exclusive-receiver liveness used by delivery.sh status (#267).
#
# Usage:
#   receiver-live.sh <team> <agent>        # exit 0 if live, non-zero if not; silent
#   receiver-live.sh <team> <agent> --pid  # print the live WATCHER pid when live
#
# Exit status: 0 = exclusive receiver live, 1 = missing/stale/not-alive.
set -euo pipefail

TEAM="${1:?team required}"
AGENT="${2:?agent required}"
PRINT_PID=0
if [ "${3:-}" = "--pid" ]; then
  PRINT_PID=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"

ready="$(SKILL_DIR="$SKILL_DIR" agmsg_ready_path "$TEAM" "$AGENT")"
[ -f "$ready" ] || exit 1

# Full ready content is the session token watch.sh stamped (bare sid or
# composite "<sid>.<agent_pid>"). Do NOT treat the trailing digits as the
# watcher pid — those are the agent CLI's pid when composite.
token="$(tr -d '\r\n' < "$ready" 2>/dev/null || true)"
[ -n "$token" ] || exit 1

# Required: watcher pidfile, written before the ready sentinel (same process,
# sequential in watch.sh). Missing pidfile ⇒ stale ready, not live.
watcher_pidfile="$RUN_DIR/watch.${token}.pid"
[ -f "$watcher_pidfile" ] || exit 1

watcher_pid="$(tr -d '\r\n' < "$watcher_pidfile" 2>/dev/null || true)"
case "$watcher_pid" in
  ''|*[!0-9]*|0) exit 1 ;;
esac
[ "$watcher_pid" -gt 1 ] 2>/dev/null || exit 1

kill -0 "$watcher_pid" 2>/dev/null || exit 1

# Defend against pid recycling: the live pid must still look like our watch.sh
# for THIS agent specifically — not just any watch.sh (a recycled pid could
# just as easily be an unrelated watcher for a different team/role).
cmd="$(compat_get_cmdline "$watcher_pid" 2>/dev/null || true)"
if [ -n "$cmd" ]; then
  case "$cmd" in
    *"$SKILL_DIR/scripts/watch.sh"*|*"watch.sh "*) ;;
    *) exit 1 ;;
  esac
  # An exclusive watcher's cmdline carries the agent name as its trailing
  # argument (watch.sh <sid> <project> <type> <agent>) — require it (review
  # finding, 2026-07-19).
  case " $cmd " in
    *" $AGENT "*) ;;
    *) exit 1 ;;
  esac
fi
# else: ps unavailable (e.g. Claude Code sandbox) — compat_get_cmdline can't
# inspect argv here. Skip validation and rely on kill -0 alone, matching
# watch.sh's own self-clean fallback for this same environment (#66; review
# finding, 2026-07-19) rather than reporting every live watcher as dead.

if [ "$PRINT_PID" -eq 1 ]; then
  printf '%s\n' "$watcher_pid"
fi
exit 0
