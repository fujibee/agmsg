#!/usr/bin/env bash
set -euo pipefail

# Event-driven background receiver for an explicitly monitored Codex thread.
#
# The shell-only watcher does not start a model while the inbox is empty. When
# unread mail appears it resumes the same persisted Codex thread, whose first
# action is the official inbox.sh command. The receiver never reads message
# bodies and never marks them read itself.

usage() {
  cat <<EOF
Usage: codex-app-monitor.sh <project> <type> <team> <name> <thread_id>

Environment:
  AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1
                                      required explicit monitor opt-in
  AGMSG_CODEX_APP_MONITOR_TIMEOUT    watch-once timeout seconds (default: 300)
  AGMSG_CODEX_APP_MONITOR_INTERVAL   watch-once poll interval seconds (default: 2)
  AGMSG_CODEX_APP_MONITOR_MAX_WAKES  stop after N wakes, useful for tests
  AGMSG_CODEX_APP_MONITOR_MAX_FAILURES
                                      switch to visible turn delivery after N
                                      consecutive failures (default: 3)
  AGMSG_CODEX_APP_MONITOR_FLAGS      extra flags passed to "codex exec"
  AGMSG_CODEX_APP_MONITOR_CODEX      codex binary override
  AGMSG_CODEX_APP_MONITOR_DANGEROUS_BYPASS=1
                                      legacy escape hatch; disabled by default
  AGMSG_CODEX_APP_MONITOR_SUPERVISED=1  restart unexpected exits through launchd;
                                      terminal fallback still exits successfully
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "${AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME:-${AGMSG_CODEX_ALLOW_HEADLESS_APP_MONITOR:-}}" != "1" ]; then
  echo "codex-app-monitor: disabled; background thread resume requires explicit monitor opt-in." >&2
  echo "codex-app-monitor: use mode monitor to opt in, or turn delivery for foreground-only handling." >&2
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
  if [ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]; then
    printf '%s\n' "/Applications/ChatGPT.app/Contents/Resources/codex"
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
ACTIVE_CHILD=""
LOCK_CLAIMED=0

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
HEALTH="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.health"
PREFLIGHT_LOG="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.preflight.log"
WATCH_OUTPUT="$RUN_DIR/codex-app-monitor.$TEAM.$NAME.watch-output"
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
    printf 'transport=codex-background-thread-resume\n'
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
  return "$(terminal_exit_code 70)"
}

terminal_exit_code() {
  if [ "${AGMSG_CODEX_APP_MONITOR_SUPERVISED:-}" = "1" ]; then
    printf '0\n'
  else
    printf '%s\n' "$1"
  fi
}

exit_after_fallback() {
  local status=0
  fallback_to_turn "$1" || status=$?
  exit "$status"
}

stop_active_child() {
  local child="${ACTIVE_CHILD:-}" check=0
  [ -n "$child" ] || return 0
  if kill -0 "$child" 2>/dev/null; then
    kill "$child" 2>/dev/null || true
    while [ "$check" -lt 20 ] && kill -0 "$child" 2>/dev/null; do
      sleep 0.1
      check=$((check + 1))
    done
    if kill -0 "$child" 2>/dev/null; then
      kill -KILL "$child" 2>/dev/null || true
    fi
  fi
  wait "$child" 2>/dev/null || true
  ACTIVE_CHILD=""
}

cleanup() {
  stop_active_child
  if [ "$LOCK_CLAIMED" = "1" ]; then
    actas_lock_release "$TEAM" "$NAME" "$OWNER_ID" 2>/dev/null || true
  fi
  if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$PIDFILE" "$META"
  fi
  rm -f "$WATCH_OUTPUT"
}
terminate() {
  write_health "stopped" "terminated"
  trap - EXIT
  cleanup
  exit 0
}

if ! lock_result="$(actas_lock_claim "$TEAM" "$NAME" "$OWNER_ID" 2>&1)"; then
  echo "codex-app-monitor: receiver already owns $TEAM/$NAME (${lock_result:-held})" >&2
  exit "$(terminal_exit_code 73)"
fi
LOCK_CLAIMED=1
trap cleanup EXIT
trap terminate INT TERM

printf '%s\n' "$$" > "$PIDFILE"
{
  printf 'project=%s\n' "$PROJECT"
  printf 'type=%s\n' "$TYPE"
  printf 'team=%s\n' "$TEAM"
  printf 'name=%s\n' "$NAME"
  printf 'thread=%s\n' "$THREAD_ID"
  printf 'transport=codex-background-thread-resume\n'
  printf 'owner=%s\n' "$OWNER_ID"
  if [ -n "${AGMSG_CODEX_APP_MONITOR_LABEL:-}" ]; then
    printf 'launch_label=%s\n' "$AGMSG_CODEX_APP_MONITOR_LABEL"
  fi
} > "$META"

if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  write_health "preflight_failed" "codex_binary_not_found"
  echo "codex-app-monitor: codex binary not found: $CODEX_BIN" >&2
  exit "$(terminal_exit_code 3)"
fi

write_health "starting" "none"
if ! "$CODEX_BIN" mcp list >"$PREFLIGHT_LOG" 2>&1; then
  write_health "preflight_failed" "codex_config_invalid"
  notify_delivery_failure "自動配送を開始できません。未読メッセージは保持しています。"
  echo "codex-app-monitor: codex config preflight failed; see $PREFLIGHT_LOG" >&2
  exit "$(terminal_exit_code 78)"
fi
rm -f "$PREFLIGHT_LOG"
write_health "ready" "none"

build_prompt() {
  local inbox_script="$SKILL_DIR/scripts/inbox.sh"
  local send_script="$SKILL_DIR/scripts/send.sh"
  cat <<EOF
agmsg has unread mail for ${TEAM}/${NAME}. Continue this persisted Codex thread
as ${NAME} and handle the mail within the thread's existing scope.

Your first tool call must be this official inbox command:
${inbox_script} ${TEAM} ${NAME}

Do not use inbox-peek.sh and do not access the agmsg database or team files
directly. If the official inbox reports no new messages, stop without replying.
Use the official sender when a response is needed:
${send_script} ${TEAM} ${NAME} <to> <message>

Autonomous collaboration contract:
1. For a substantive request, review, or new evidence, continue the requested
   work through verification and reply with concrete evidence. Do not stop at
   an ACK when safe in-scope work remains.
2. Do not reply to ACK-only, thanks-only, or status-only mail that contains no
   new request, evidence, correction, or blocker. This prevents reply loops.
3. Preserve all existing safety, approval, production, customer-data, secret,
   and scope boundaries. Stop and report a real blocker when new authority or
   an unsafe/external mutation would be required.
4. Keep the handling visible in this same Codex thread with concise Japanese
   progress and a final status. Never claim completion from delivery alone.
EOF
}

run_resume() {
  local prompt_file="$1"
  local -a cmd
  local child wait_status
  cmd=("$CODEX_BIN" exec)

  # Background turns cannot answer approval prompts. Keep them non-interactive
  # and workspace-bounded by default; the agmsg runtime dirs are added so the
  # official inbox/send scripts can update their own state. The dangerous
  # bypass remains an explicit compatibility escape hatch only.
  if [ "${AGMSG_CODEX_APP_MONITOR_DANGEROUS_BYPASS:-}" = "1" ]; then
    cmd+=(--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust)
  else
    cmd+=(-c 'approval_policy="never"' -s workspace-write)
    cmd+=(--add-dir "$SKILL_DIR/run" --add-dir "$SKILL_DIR/db" --add-dir "$SKILL_DIR/teams")
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

  AGMSG_CODEX_BACKGROUND_RESUME=1 \
    "${cmd[@]}" < "$prompt_file" >>"$LOG" 2>&1 &
  child="$!"
  ACTIVE_CHILD="$child"
  wait "$child"
  wait_status=$?
  ACTIVE_CHILD=""
  printf '%s\n' "$wait_status" > "$LAST_STATUS"
  return "$wait_status"
}

run_watch_once() {
  local timeout="$1" interval="$2" child wait_status
  : > "$WATCH_OUTPUT"
  "$SCRIPT_DIR/watch-once.sh" "$PROJECT" "$TYPE" \
    --team "$TEAM" \
    --name "$NAME" \
    --owner "$OWNER_ID" \
    --claim \
    --timeout "$timeout" \
    --interval "$interval" >"$WATCH_OUTPUT" 2>&1 &
  child="$!"
  ACTIVE_CHILD="$child"
  wait "$child"
  wait_status=$?
  ACTIVE_CHILD=""
  return "$wait_status"
}

wake_count=0
printf 'codex-app-monitor: started team=%s name=%s thread=%s pid=%s\n' "$TEAM" "$NAME" "$THREAD_ID" "$$"

while :; do
  set +e
  run_watch_once "$TIMEOUT" "$INTERVAL"
  watch_status=$?
  set -e
  watch_output="$(cat "$WATCH_OUTPUT" 2>/dev/null || true)"
  rm -f "$WATCH_OUTPUT"

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
        exit_after_fallback "watch_once_failed_${watch_status}"
      fi
      sleep 5
      continue
      ;;
  esac

  pending_max_id="$(printf '%s\n' "$watch_output" | sed -n 's/.*max_id=\([0-9][0-9]*\).*/\1/p' | head -1)"
  case "$pending_max_id" in ''|*[!0-9]*) pending_max_id=0 ;; esac
  if [ "$pending_max_id" -le 0 ]; then
    consecutive_failures=$((consecutive_failures + 1))
    write_health "degraded" "watch_once_missing_max_id"
    printf 'codex-app-monitor: watch-once wake omitted a valid max_id: %s\n' "$watch_output" >&2
    if [ "$consecutive_failures" -ge "$MAX_FAILURES" ]; then
      exit_after_fallback "watch_once_missing_max_id"
    fi
    sleep 5
    continue
  fi
  build_prompt > "$LAST_PROMPT"
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
    # A non-zero CLI status does not prove that the app rejected the turn
    # before creating it. Retrying the same unread high-water mark could wake
    # the visible task twice, so preserve the inbox and stop after one attempt.
    exit_after_fallback "codex_exec_resume_failed_${resume_status}"
  else
    # Success means the resumed thread ran. Verify that it also consumed the
    # high-water mark through inbox.sh; otherwise keep the message unread and
    # degrade instead of silently declaring delivery.
    set +e
    run_watch_once 0 1
    post_status=$?
    set -e
    post_output="$(cat "$WATCH_OUTPUT" 2>/dev/null || true)"
    rm -f "$WATCH_OUTPUT"
    post_max_id="$(printf '%s\n' "$post_output" | sed -n 's/.*max_id=\([0-9][0-9]*\).*/\1/p' | head -1)"
    case "$post_max_id" in ''|*[!0-9]*) post_max_id=0 ;; esac
    if [ "$post_status" -eq 0 ] && [ "$post_max_id" -eq "$pending_max_id" ]; then
      consecutive_failures=$((consecutive_failures + 1))
      write_health "degraded" "thread_did_not_consume_inbox"
      printf 'codex-app-monitor: resumed thread did not consume max_id=%s\n' "$pending_max_id" >&2
      # A successful resume already created a turn. Never wake the same unread
      # high-water mark twice; preserve it and fall back for operator recovery.
      exit_after_fallback "thread_did_not_consume_inbox"
    elif [ "$post_status" -eq 0 ]; then
      # A different high-water mark means the resumed turn consumed the
      # original batch while newer mail arrived (or left another batch). Re-arm
      # immediately so the new mail gets its own serialized turn.
      consecutive_failures=0
      last_success_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      write_health "pending" "new_mail_after_resume"
    elif [ "$post_status" -eq 2 ]; then
      consecutive_failures=0
      last_success_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      write_health "ready" "none"
    else
      consecutive_failures=$((consecutive_failures + 1))
      write_health "degraded" "post_watch_exit_${post_status}"
      printf 'codex-app-monitor: post-resume watch failed status=%s output=%s\n' "$post_status" "$post_output" >&2
      # The wake already ran and consumption cannot be proved. Fail closed
      # instead of risking a second turn for the same unread message.
      exit_after_fallback "post_watch_failed_${post_status}"
    fi
  fi

  if [ "$MAX_WAKES" -gt 0 ] && [ "$wake_count" -ge "$MAX_WAKES" ]; then
    write_health "stopped" "max_wakes_reached"
    exit 0
  fi
done
