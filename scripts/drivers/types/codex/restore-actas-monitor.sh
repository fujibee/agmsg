#!/usr/bin/env bash
set -euo pipefail

# Global Codex SessionStart hook.
#
# Restores the receive-side agmsg monitor for the last `agmsg actas <name>` role
# used in this project. This is intentionally Codex.app-friendly: ordinary app
# sessions use codex-app-monitor.sh via actas-monitor.sh, while shim/app-server
# sessions can still use the bridge path selected there.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/resolve-project.sh
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"

mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/codex-actas-restore.log"

INPUT="$(cat 2>/dev/null || true)"

json_string_field() {
  local key="$1"
  printf '%s' "$INPUT" \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    | head -1
}

PROJECT="$(json_string_field cwd)"
if [ -z "$PROJECT" ]; then
  PROJECT="$PWD"
fi
PROJECT="$(agmsg_resolve_project "$PROJECT" codex 2>/dev/null || printf '%s' "$PROJECT")"
if [ -d "$PROJECT" ]; then
  PROJECT="$(cd "$PROJECT" && pwd -P)"
fi

PROJECT_HASH="$(agmsg_sha1 <<<"$PROJECT")"
STATE="$RUN_DIR/codex-last-actas.$PROJECT_HASH.tsv"

if [ ! -f "$STATE" ]; then
  exit 0
fi

IFS=$'\t' read -r saved_project saved_type saved_team saved_name _saved_at < "$STATE" || exit 0
[ "$saved_type" = "codex" ] || exit 0
[ -n "$saved_team" ] && [ -n "$saved_name" ] || exit 0

if [ -d "$saved_project" ]; then
  saved_project="$(cd "$saved_project" && pwd -P)"
fi
[ "$saved_project" = "$PROJECT" ] || exit 0

THREAD_ID="$(json_string_field session_id)"
if [ -z "$THREAD_ID" ]; then
  THREAD_ID="$(json_string_field id)"
fi

{
  printf 'restore-start project=%s team=%s name=%s thread=%s at=%s\n' \
    "$PROJECT" "$saved_team" "$saved_name" "${THREAD_ID:-auto}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  AGMSG_TEAM="$saved_team" AGMSG_CODEX_ACTAS_THREAD="$THREAD_ID" \
    "$SCRIPT_DIR/actas-monitor.sh" "$PROJECT" codex "$saved_name" "${THREAD_ID:-}"
  printf 'restore-end status=ok at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$LOG" 2>&1 || {
  status=$?
  printf 'restore-end status=failed code=%s at=%s\n' "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG" 2>&1 || true
  exit 0
}
