#!/usr/bin/env bash
# codex-daemon-health.sh -- read-only check of the Codex app-server daemon of
# every profile this install knows (#1886). agmsgd runs this once per check.
#
# Usage: codex-daemon-health.sh
# One tab-separated line per profile:
#   profile  state  pid  start  age_seconds  footprint_mb  over  clients  reason  peak_mb
# state: absent | stale | running | unchecked. Never stops or restarts anything.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="${SKILL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/codex-daemon-health.sh"
_print_profile() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "${CDH_STATE:-}" "${CDH_PID:-}" "${CDH_START:-}" \
    "${CDH_AGE_SECONDS:-}" "${CDH_FOOTPRINT_MB:-}" "${CDH_OVER:-}" "${CDH_CLIENTS:-}" "${CDH_REASON:-}" "${CDH_PEAK_MB:-}"
}
trap 'agmsg_codex_daemon_reap_child; exit 143' TERM INT
agmsg_codex_daemon_scan "$SKILL_DIR/run" _print_profile
