#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codex-diag.sh <project> <team> <agent>

Runs a read-only process/app-server/thread diagnosis.
Exit 0 means all three layers match; exit 1 means mismatch or unknown;
exit 2 means invalid usage. Missing observations remain UNKNOWN.
EOF
}

if [ "${1:-}" = "--help" ]; then usage; exit 0; fi
[ "$#" -eq 3 ] || { usage >&2; exit 2; }
PROJECT="$1"; TEAM="$2"; AGENT="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
source "$SCRIPT_DIR/../../../lib/role-session.sh"
source "$SCRIPT_DIR/../../../lib/node.sh"
source "$SCRIPT_DIR/_home.sh"
source "$SCRIPT_DIR/_seat-key.sh"
source "$SCRIPT_DIR/_app-server.sh"

PROJECT="$(cd "$PROJECT" && pwd)"
BASE="$RUN_DIR/codex-bridge.$TEAM.$AGENT"
BRIDGE_PID="$(cat "$BASE.pid" 2>/dev/null || true)"
BRIDGE_THREAD="$(cat "$BASE.thread" 2>/dev/null || true)"
BRIDGE_APP="$(cat "$BASE.appserver" 2>/dev/null || true)"
APP_SERVER_URL="$(_agmsg_codex_app_server_url "$PROJECT" 2>/dev/null || true)"
PORT="${APP_SERVER_URL##*:}"
case "$PORT" in ''|*[!0-9]*) PORT="" ;; esac
SERVER_PID=""
if [ -n "${AGMSG_CODEX_SEAT_KEY:-}" ] && _agmsg_codex_seat_key_ok "$AGMSG_CODEX_SEAT_KEY" 2>/dev/null; then
  seat_record="$(_agmsg_codex_seat_record_path "$RUN_DIR" "$AGMSG_CODEX_SEAT_KEY")"
  if _agmsg_codex_seat_record_read "$seat_record" 2>/dev/null; then SERVER_PID="${SEAT_REC_PID:-}"; fi
fi
agmsg_role_session_load "$TEAM" "$AGENT" 2>/dev/null || true
SEAT_THREAD="${AGMSG_ROLE_SESSION_UUID:-}"
NODE_BIN="$(agmsg_resolve_node 2>/dev/null || true)"
[ -n "$NODE_BIN" ] || { echo "codex-diag.sh: node is required" >&2; exit 2; }
LOADED=""
if [ -n "$PORT" ] && { command -v "$NODE_BIN" >/dev/null 2>&1 || [ -x "$NODE_BIN" ]; }; then
  LOADED="$($NODE_BIN "$SCRIPT_DIR/codex-bridge.js" --app-server "ws://127.0.0.1:$PORT" --print-loaded-threads --connect-timeout-ms 1500 --request-timeout-ms 1500 2>/dev/null || true)"
fi
DIAG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-codex-diag.XXXXXX")"
trap 'rm -rf "$DIAG_TMP"' EXIT
printf '%s\n' "$LOADED" | grep -E '^[[:alnum:]-]+$' | sort -u >"$DIAG_TMP/current" || true
loaded_count="$(grep -c . "$DIAG_TMP/current" 2>/dev/null || true)"
loaded_only="$(cat "$DIAG_TMP/current" 2>/dev/null || true)"

is_windows_git_bash() { case "${MSYSTEM:-}" in MINGW*|MSYS*|CLANGARM*) return 0 ;; *) return 1 ;; esac; }
probe_ss_pids() {
  [ -n "$PORT" ] && command -v ss >/dev/null 2>&1 || return 1
  ss -tnp 2>/dev/null | awk -v p=":$PORT" '$0 ~ p { print }' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -nu
}
probe_posix_pids() {
  [ -n "$PORT" ] || return 1
  ps -eo pid=,args= 2>/dev/null | awk -v p="--remote ws://127.0.0.1:$PORT" '$0 ~ /codex/ && $0 ~ p && $0 !~ /codex-bridge/ { print $1 }'
}
probe_windows_pids() {
  [ -n "$PORT" ] || return 1
  local bin out
  for bin in powershell.exe pwsh; do
    command -v "$bin" >/dev/null 2>&1 || continue
    if out="$(AGMSG_DIAG_REMOTE="--remote ws://127.0.0.1:$PORT" "$bin" -NoProfile -NonInteractive -Command '
      $needle = $env:AGMSG_DIAG_REMOTE
      Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) -and $_.CommandLine -match "codex" -and $_.CommandLine -notmatch "codex-bridge" } |
        ForEach-Object { $_.ProcessId }
    ' 2>/dev/null)"; then
      printf '%s\n' "$out" | tr -d '\r' | sed '/^[0-9][0-9]*$/!d' | sort -nu
      return 0
    fi
  done
  return 1
}
process_reason="no-matching-tui"; probe_ok=0; : >"$DIAG_TMP/pids"
if is_windows_git_bash; then
  if probe_windows_pids >"$DIAG_TMP/pids"; then probe_ok=1; else process_reason="process-observation-failed"; fi
else
  if probe_ss_pids >"$DIAG_TMP/ss-pids"; then probe_ok=1; cat "$DIAG_TMP/ss-pids" >>"$DIAG_TMP/pids"; fi
  if [ ! -s "$DIAG_TMP/pids" ]; then
    if probe_posix_pids >"$DIAG_TMP/ps-pids"; then probe_ok=1; cat "$DIAG_TMP/ps-pids" >>"$DIAG_TMP/pids"
    elif [ "$probe_ok" -eq 1 ]; then process_reason="no-matching-tui-partial-probe-failure"
    else process_reason="process-observation-failed"; fi
  fi
fi
TUI_PIDS="$(sort -nu "$DIAG_TMP/pids" 2>/dev/null | tr '\n' ' ')"
TUI_PIDS="$(printf '%s' "$TUI_PIDS" | sed "s/\\b$SERVER_PID\\b//g; s/\\b$BRIDGE_PID\\b//g" | xargs 2>/dev/null || true)"
process_state="UNKNOWN"
if [ -n "$TUI_PIDS" ]; then process_state="MATCH"; process_reason="observed-matching-tui"
elif [ "$probe_ok" -eq 0 ]; then process_reason="process-observation-failed"; fi
app_state="UNKNOWN"
if [ -n "$PORT" ] && [ -n "$BRIDGE_APP" ] && [ "$BRIDGE_APP" = "ws://127.0.0.1:$PORT" ] && [ -n "$SERVER_PID" ]; then
  app_state="MATCH"
elif [ -n "$PORT" ] && [ -n "$BRIDGE_APP" ]; then
  app_state="MISMATCH"
fi
thread_state="UNKNOWN"; thread_reason="no-unique-current-thread"
if [ "$loaded_count" -eq 1 ] && [ "$BRIDGE_THREAD" = "$loaded_only" ] && [ "$SEAT_THREAD" = "$BRIDGE_THREAD" ]; then
  thread_state="MATCH"; thread_reason="single-loaded-thread-and-seat-bridge-match"
elif [ -n "$BRIDGE_THREAD" ] && [ -n "$SEAT_THREAD" ] && [ "$BRIDGE_THREAD" != "$SEAT_THREAD" ] && grep -Fxq "$BRIDGE_THREAD" "$DIAG_TMP/current"; then
  thread_state="MISMATCH"; thread_reason="bridge-seat-mismatch"
fi
overall="MATCH"
for state in "$process_state" "$app_state" "$thread_state"; do
  [ "$state" = "MATCH" ] || { overall="$state"; [ "$state" = "MISMATCH" ] && break; }
done
echo "codex diagnosis: $overall"
echo "process: $process_state tui_pids=${TUI_PIDS:-unknown} app_server_pid=${SERVER_PID:-unknown} bridge_pid=${BRIDGE_PID:-unknown} reason=$process_reason"
echo "app-server: $app_state port=${PORT:-unknown} bridge_app=${BRIDGE_APP:-unknown}"
echo "thread: $thread_state seat=${SEAT_THREAD:-unknown} bridge=${BRIDGE_THREAD:-unknown}"
echo "loaded_threads: ${LOADED:-unknown}"
echo "thread-evidence: current_count=$loaded_count reason=$thread_reason"
[ "$overall" = "MATCH" ]
