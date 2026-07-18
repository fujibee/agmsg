#!/usr/bin/env bash
set -euo pipefail

# Legacy headless fallback for sessions opened directly in Codex.app.
#
# This script wakes a Codex thread through `codex exec resume`, which does not
# report progress in the active Codex.app chat. It is therefore disabled by
# default. Use the app-server bridge for visible real-time delivery, or turn
# delivery for chat-visible handling at turn boundaries.

usage() {
  cat <<EOF
Usage: codex-app-monitor.sh <project> <type> <team> <name> <thread_id>

Environment:
  AGMSG_CODEX_ALLOW_HEADLESS_APP_MONITOR=1
                                      opt in to this legacy headless fallback
  AGMSG_CODEX_APP_MONITOR_TIMEOUT    watch-once timeout seconds (default: 300)
  AGMSG_CODEX_APP_MONITOR_INTERVAL   watch-once poll interval seconds (default: 2)
  AGMSG_CODEX_APP_MONITOR_MAX_WAKES  stop after N wakes, useful for tests
  AGMSG_CODEX_APP_MONITOR_MAX_FAILURES
                                      switch to visible turn delivery after N
                                      consecutive failures (default: 3)
  AGMSG_CODEX_APP_MONITOR_FLAGS      extra flags passed to "codex exec"
  AGMSG_CODEX_APP_MONITOR_CODEX      codex binary override
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "${AGMSG_CODEX_ALLOW_HEADLESS_APP_MONITOR:-}" != "1" ]; then
  echo "codex-app-monitor: disabled; it handles messages via headless 'codex exec resume'." >&2
  echo "codex-app-monitor: use the Codex app-server bridge or turn delivery for visible chat status." >&2
  echo "codex-app-monitor: set AGMSG_CODEX_ALLOW_HEADLESS_APP_MONITOR=1 only for legacy opt-in runs." >&2
  exit 64
fi

PROJECT="${1:?Usage: codex-app-monitor.sh <project> <type> <team> <name> <thread_id>}"
TYPE="${2:?Missing type}"
TEAM="${3:?Missing team}"
NAME="${4:?Missing name}"
THREAD_ID="${5:-}"

if [ -z "$THREAD_ID" ] || [ "$THREAD_ID" = "loaded" ] || [ "$THREAD_ID" = "new" ]; then
  echo "codex-app-monitor: a concrete Codex thread id is required" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

# shellcheck source=../../../lib/resolve-project.sh
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck source=../../../lib/storage.sh
source "$SCRIPT_DIR/../../../lib/storage.sh"
# shellcheck source=../../../lib/actas-lock.sh
source "$SCRIPT_DIR/../../../lib/actas-lock.sh"

PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"
mkdir -p "$RUN_DIR"

TIMEOUT="${AGMSG_CODEX_APP_MONITOR_TIMEOUT:-${AGMSG_WATCH_ONCE_TIMEOUT:-300}}"
INTERVAL="${AGMSG_CODEX_APP_MONITOR_INTERVAL:-${AGMSG_WATCH_ONCE_INTERVAL:-2}}"
MAX_WAKES="${AGMSG_CODEX_APP_MONITOR_MAX_WAKES:-0}"
MAX_FAILURES="${AGMSG_CODEX_APP_MONITOR_MAX_FAILURES:-3}"
resolve_codex_bin() {
  if [ -n "${AGMSG_CODEX_APP_MONITOR_CODEX:-}" ]; then
    printf '%s\n' "$AGMSG_CODEX_APP_MONITOR_CODEX"
    return 0
  fi
  if [ -x "/Applications/Codex.app/Contents/Resources/codex" ]; then
    printf '%s\n' "/Applications/Codex.app/Contents/Resources/codex"
    return 0
  fi
  if [ -x "$HOME/.npm-global/bin/codex" ]; then
    printf '%s\n' "$HOME/.npm-global/bin/codex"
    return 0
  fi
  command -v codex 2>/dev/null || printf '%s\n' "codex"
}

CODEX_BIN="$(resolve_codex_bin)"
OWNER_ID="agmsg-codex-app-monitor-$$.$$"

case "$TIMEOUT" in ''|*[!0-9]*) echo "codex-app-monitor: timeout must be a whole number" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "codex-app-monitor: interval must be a whole number" >&2; exit 2 ;; esac
case "$MAX_WAKES" in ''|*[!0-9]*) echo "codex-app-monitor: max wakes must be a whole number" >&2; exit 2 ;; esac
case "$MAX_FAILURES" in ''|*[!0-9]*) echo "codex-app-monitor: max failures must be a whole number" >&2; exit 2 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=1
[ "$MAX_FAILURES" -gt 0 ] || MAX_FAILURES=1

PIDFILE="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.pid"
META="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.meta"
LOG="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.log"
LAST_PROMPT="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.last-prompt.txt"
LAST_OUTPUT="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.last-message.txt"
LAST_STATUS="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.last-status"
LAST_IDS="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.last-ids"
HEALTH="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.health"
PREFLIGHT_LOG="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.preflight.log"
CHAT_META="$RUN_DIR/codex-chat-visible.$TEAM.$NAME.meta"

consecutive_failures=0
last_wake_at=""
last_success_at=""

write_health() {
  local status="$1" last_error="${2:-none}" tmp="$HEALTH.$$"
  {
    printf 'project=%s\n' "$PROJECT"
    printf 'type=%s\n' "$TYPE"
    printf 'team=%s\n' "$TEAM"
    printf 'name=%s\n' "$NAME"
    printf 'thread=%s\n' "$THREAD_ID"
    printf 'transport=codex-app-exec-resume\n'
    printf 'status=%s\n' "$status"
    printf 'consecutive_failures=%s\n' "$consecutive_failures"
    printf 'last_error=%s\n' "$last_error"
    printf 'last_wake_at=%s\n' "${last_wake_at:-none}"
    printf 'last_success_at=%s\n' "${last_success_at:-none}"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  mv "$tmp" "$HEALTH"
}

notify_delivery_failure() {
  local message="${1:-未読メッセージを自動配送できません。turn 配送へ退避しました。}"
  [ "${AGMSG_CODEX_APP_MONITOR_DISABLE_NOTIFY:-}" = "1" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  /usr/bin/osascript - "$TEAM/$NAME" "$message" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 2 of argv) with title "agmsg monitor" subtitle (item 1 of argv)
end run
APPLESCRIPT
}

write_chat_visible_meta() {
  local tmp="$CHAT_META.$$"
  {
    printf 'project=%s\n' "$PROJECT"
    printf 'type=%s\n' "$TYPE"
    printf 'team=%s\n' "$TEAM"
    printf 'name=%s\n' "$NAME"
    printf 'thread=%s\n' "$THREAD_ID"
    printf 'transport=codex-chat-visible-turn\n'
    printf 'status=waiting_for_chat_turn\n'
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  mv "$tmp" "$CHAT_META"
}

fallback_to_turn() {
  local reason="$1"
  write_health "fallback_turn" "$reason"
  notify_delivery_failure
  # Monitor mode already installs the visible Stop-hook fallback for Codex.
  # Do not rewrite the project to turn mode here: that would remove the
  # SessionStart hook and prevent automatic rebind after the next restart.
  write_chat_visible_meta
  write_health "fallback_turn" "$reason"
  return 70
}

if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  write_health "preflight_failed" "codex_binary_not_found"
  echo "codex-app-monitor: codex binary not found: $CODEX_BIN" >&2
  exit 3
fi

write_health "starting" "none"
if ! "$CODEX_BIN" mcp list >"$PREFLIGHT_LOG" 2>&1; then
  write_health "preflight_failed" "codex_config_invalid"
  notify_delivery_failure "自動配送を開始できません。未読メッセージは保持しています。"
  echo "codex-app-monitor: codex config preflight failed; see $PREFLIGHT_LOG" >&2
  exit 78
fi
rm -f "$PREFLIGHT_LOG"
write_health "ready" "none"

cleanup() {
  actas_lock_release "$TEAM" "$NAME" "$OWNER_ID" 2>/dev/null || true
  rm -f "$PIDFILE" "$META"
}
terminate() {
  write_health "stopped" "terminated"
  cleanup
  exit 0
}
trap cleanup EXIT
trap terminate INT TERM

printf '%s\n' "$$" > "$PIDFILE"
{
  printf 'project=%s\n' "$PROJECT"
  printf 'type=%s\n' "$TYPE"
  printf 'team=%s\n' "$TEAM"
  printf 'name=%s\n' "$NAME"
  printf 'thread=%s\n' "$THREAD_ID"
  printf 'transport=codex-app-exec-resume\n'
  printf 'owner=%s\n' "$OWNER_ID"
  if [ -n "${AGMSG_CODEX_APP_MONITOR_LABEL:-}" ]; then
    printf 'launch_label=%s\n' "$AGMSG_CODEX_APP_MONITOR_LABEL"
  fi
} > "$META"

build_prompt() {
  local inbox_text="$1"
  local send_script="$SKILL_DIR/scripts/send.sh"
  cat <<EOF
agmsg delivered the following unread messages for ${TEAM}/${NAME}:

${inbox_text}

Continue the conversation in this Codex thread. You are currently acting as ${NAME}.
If a reply to an agmsg sender is needed, send it with:
${send_script} ${TEAM} ${NAME} <to> <message>

Visible UI requirement:
1. Before the first tool call, post a short Japanese progress update in the
   Codex thread UI starting with "agmsg対応状況:" and include sender, summary,
   planned action, and whether you will reply.
2. Keep substantive work in the visible thread. Before each major action, post
   a short Japanese progress update; do not complete the task in an unreported
   background worker.
3. After handling the message, post a final Japanese status update with:
   sender, received instruction, action taken, reply target, reply summary,
   remaining blocker, and next step.
4. If you do not reply, state why in the visible status.
5. Do not treat DB writes, monitor delivery, or a send.sh result as complete
   unless the handling is visible in the Codex thread UI.
EOF
	}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

read_unread_for_prompt() {
  : > "$LAST_IDS"
  "$SKILL_DIR/scripts/inbox-peek.sh" "$TEAM" "$NAME" --quiet --ids-file "$LAST_IDS"
  [ -s "$LAST_IDS" ] || return 1
}

mark_delivered_ids_read() {
  [ -f "$LAST_IDS" ] || return 0
  "$SKILL_DIR/scripts/mark-read.sh" "$TEAM" "$NAME" --ids-file "$LAST_IDS"
}

run_resume() {
  local prompt_file="$1"
  local -a cmd
  local child wait_status
  cmd=("$CODEX_BIN" exec)

  # Non-interactive wakeups cannot answer approval prompts. The default mirrors
  # Codex.app's automation context; callers can override or append with
  # AGMSG_CODEX_APP_MONITOR_FLAGS when they need a stricter profile.
  if [ -z "${AGMSG_CODEX_APP_MONITOR_NO_BYPASS:-}" ]; then
    cmd+=(--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust)
  fi
  if [ -n "${AGMSG_CODEX_APP_MONITOR_FLAGS:-}" ]; then
    # shellcheck disable=SC2206
    extra_flags=(${AGMSG_CODEX_APP_MONITOR_FLAGS})
    cmd+=("${extra_flags[@]}")
  fi
  cmd+=(-C "$PROJECT" -o "$LAST_OUTPUT" resume "$THREAD_ID" -)

  : > "$LAST_STATUS"
  printf 'codex-app-monitor: running %q' "${cmd[0]}"
  printf ' %q' "${cmd[@]:1}"
  printf '\n'

  (
    set +e
    "${cmd[@]}" < "$prompt_file"
    printf '%s\n' "$?" > "$LAST_STATUS"
  ) >>"$LOG" 2>&1 &
  child="$!"
  wait "$child"
  wait_status=$?
  if [ -s "$LAST_STATUS" ]; then
    wait_status="$(cat "$LAST_STATUS" 2>/dev/null || printf '%s' "$wait_status")"
  fi
  return "$wait_status"
}

wake_count=0
printf 'codex-app-monitor: started team=%s name=%s thread=%s pid=%s\n' "$TEAM" "$NAME" "$THREAD_ID" "$$"

while :; do
  set +e
  watch_output="$("$SCRIPT_DIR/watch-once.sh" "$PROJECT" "$TYPE" \
    --team "$TEAM" \
    --name "$NAME" \
    --owner "$OWNER_ID" \
    --claim \
    --timeout "$TIMEOUT" \
    --interval "$INTERVAL" 2>&1)"
  watch_status=$?
  set -e

  case "$watch_status" in
    0)
      ;;
    2)
      continue
      ;;
    *)
      consecutive_failures=$((consecutive_failures + 1))
      write_health "degraded" "watch_once_exit_${watch_status}"
      printf 'codex-app-monitor: watch-once failed status=%s output=%s\n' "$watch_status" "$watch_output" >&2
      if [ "$consecutive_failures" -ge "$MAX_FAILURES" ]; then
        fallback_to_turn "watch_once_failed_${watch_status}" || fallback_status=$?
        exit "${fallback_status:-70}"
      fi
      sleep 5
      continue
      ;;
  esac

  if ! inbox_text="$(read_unread_for_prompt)"; then
    continue
  fi

  build_prompt "$inbox_text" > "$LAST_PROMPT"
  wake_count=$((wake_count + 1))
  last_wake_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_health "delivering" "none"
  printf 'codex-app-monitor: wakeup %s for %s/%s thread=%s\n' "$wake_count" "$TEAM" "$NAME" "$THREAD_ID"

  set +e
  run_resume "$LAST_PROMPT"
  resume_status=$?
  set -e
  if [ "$resume_status" -ne 0 ]; then
    consecutive_failures=$((consecutive_failures + 1))
    write_health "degraded" "codex_exec_resume_exit_${resume_status}"
    printf 'codex-app-monitor: codex exec resume failed status=%s prompt=%s output=%s\n' "$resume_status" "$LAST_PROMPT" "$LAST_OUTPUT" >&2
    if [ "$consecutive_failures" -ge "$MAX_FAILURES" ]; then
      fallback_to_turn "codex_exec_resume_failed_${resume_status}" || fallback_status=$?
      exit "${fallback_status:-70}"
    fi
    sleep 30
  else
    mark_delivered_ids_read
    consecutive_failures=0
    last_success_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_health "ready" "none"
  fi

  if [ "$MAX_WAKES" -gt 0 ] && [ "$wake_count" -ge "$MAX_WAKES" ]; then
    write_health "stopped" "max_wakes_reached"
    exit 0
  fi
done
