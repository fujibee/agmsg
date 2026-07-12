#!/usr/bin/env bash
set -euo pipefail

# Coordinate Codex Desktop heartbeat and scheduled watchdog delivery.
#
# The collector never reads message bodies and never marks messages read. It
# only reserves an unread high-water mark long enough for one visible Codex
# turn to be started. The target thread remains responsible for inbox.sh.

ACTION="${1:-}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../lib/validate.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  codex-monitor-lease.sh arm <project> <team> <name> <thread> [--ttl <sec>]
  codex-monitor-lease.sh heartbeat <project> <team> <name> <thread> [--ttl <sec>]
  codex-monitor-lease.sh claim <project> <team> <name> <thread> [--fallback-after <sec>] [--retry-after <sec>]
  codex-monitor-lease.sh delivered <project> <team> <name> <thread> <max_id>
  codex-monitor-lease.sh failed <project> <team> <name> <thread> <max_id>
  codex-monitor-lease.sh automation <project> <team> <name> <thread> <heartbeat_id> <watchdog_id>
  codex-monitor-lease.sh prompt <project> <team> <name> <thread> <heartbeat|watchdog>
  codex-monitor-lease.sh status <project> <team> <name> <thread>
  codex-monitor-lease.sh disarm <project> <team> <name> <thread>
  codex-monitor-lease.sh deactivate-thread <project> <thread>
  codex-monitor-lease.sh disarm-project <project>
EOF
  exit 64
}

whole_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

reject_line_breaks() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; *) return 0 ;; esac
}

PROJECT=""
TEAM=""
NAME=""
THREAD=""
STATE=""
LOCK=""
STATUS="active"
TTL="${AGMSG_CODEX_MONITOR_LEASE_TTL:-43200}"
EXPIRES_AT=0
LAST_HEARTBEAT=0
LAST_WAKE_ID=0
LAST_WAKE_AT=0
PENDING_WAKE_ID=0
PENDING_WAKE_AT=0
FAILURES=0
HEARTBEAT_AUTOMATION_ID=""
WATCHDOG_AUTOMATION_ID=""

state_field() {
  local key="$1" file="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1
}

load_state() {
  [ -f "$STATE" ] || return 1
  STATUS="$(state_field status "$STATE")"
  TTL="$(state_field ttl "$STATE")"
  EXPIRES_AT="$(state_field expires_at "$STATE")"
  LAST_HEARTBEAT="$(state_field last_heartbeat "$STATE")"
  LAST_WAKE_ID="$(state_field last_wake_id "$STATE")"
  LAST_WAKE_AT="$(state_field last_wake_at "$STATE")"
  PENDING_WAKE_ID="$(state_field pending_wake_id "$STATE")"
  PENDING_WAKE_AT="$(state_field pending_wake_at "$STATE")"
  FAILURES="$(state_field failures "$STATE")"
  HEARTBEAT_AUTOMATION_ID="$(state_field heartbeat_automation_id "$STATE")"
  WATCHDOG_AUTOMATION_ID="$(state_field watchdog_automation_id "$STATE")"
  whole_number "$TTL" || TTL=43200
  whole_number "$EXPIRES_AT" || EXPIRES_AT=0
  whole_number "$LAST_HEARTBEAT" || LAST_HEARTBEAT=0
  whole_number "$LAST_WAKE_ID" || LAST_WAKE_ID=0
  whole_number "$LAST_WAKE_AT" || LAST_WAKE_AT=0
  whole_number "$PENDING_WAKE_ID" || PENDING_WAKE_ID=0
  whole_number "$PENDING_WAKE_AT" || PENDING_WAKE_AT=0
  whole_number "$FAILURES" || FAILURES=0
}

write_state() {
  local tmp="$STATE.$$"
  mkdir -p "$RUN_DIR"
  {
    printf 'project=%s\n' "$PROJECT"
    printf 'type=codex\n'
    printf 'team=%s\n' "$TEAM"
    printf 'name=%s\n' "$NAME"
    printf 'thread=%s\n' "$THREAD"
    printf 'status=%s\n' "$STATUS"
    printf 'ttl=%s\n' "$TTL"
    printf 'expires_at=%s\n' "$EXPIRES_AT"
    printf 'last_heartbeat=%s\n' "$LAST_HEARTBEAT"
    printf 'last_wake_id=%s\n' "$LAST_WAKE_ID"
    printf 'last_wake_at=%s\n' "$LAST_WAKE_AT"
    printf 'pending_wake_id=%s\n' "$PENDING_WAKE_ID"
    printf 'pending_wake_at=%s\n' "$PENDING_WAKE_AT"
    printf 'failures=%s\n' "$FAILURES"
    printf 'heartbeat_automation_id=%s\n' "$HEARTBEAT_AUTOMATION_ID"
    printf 'watchdog_automation_id=%s\n' "$WATCHDOG_AUTOMATION_ID"
  } > "$tmp"
  mv "$tmp" "$STATE"
}

release_lock() {
  if [ -n "$LOCK" ]; then
    rm -f "$LOCK/pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
  fi
}

acquire_lock() {
  local attempts=0 owner
  mkdir -p "$RUN_DIR"
  while ! mkdir "$LOCK" 2>/dev/null; do
    owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$LOCK"
      continue
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 40 ]; then
      echo "status=busy lease_id=$(basename "${STATE%.state}")"
      exit 75
    fi
    sleep 0.05
  done
  printf '%s\n' "$$" > "$LOCK/pid"
  trap release_lock EXIT INT TERM
}

init_identity() {
  PROJECT="${1:?Missing project}"
  TEAM="${2:?Missing team}"
  NAME="${3:?Missing name}"
  THREAD="${4:?Missing thread}"
  agmsg_validate_team_name "$TEAM"
  agmsg_validate_agent_name "$NAME"
  reject_line_breaks "$PROJECT" || { echo "agmsg: invalid project path" >&2; exit 64; }
  reject_line_breaks "$THREAD" || { echo "agmsg: invalid Codex thread id" >&2; exit 64; }
  [ -n "$THREAD" ] || { echo "agmsg: Codex monitor needs a thread id" >&2; exit 64; }
  PROJECT="$(agmsg_resolve_project "$PROJECT" codex)"
  local key
  key="$(printf '%s\t%s\t%s\t%s' "$PROJECT" "$TEAM" "$NAME" "$THREAD" | agmsg_sha1)"
  STATE="$RUN_DIR/codex-monitor-lease.$key.state"
  LOCK="$STATE.lock"
}

parse_timing_options() {
  FALLBACK_AFTER=0
  RETRY_AFTER="${AGMSG_CODEX_MONITOR_RETRY_AFTER:-90}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ttl) TTL="${2:?--ttl needs seconds}"; shift 2 ;;
      --fallback-after) FALLBACK_AFTER="${2:?--fallback-after needs seconds}"; shift 2 ;;
      --retry-after) RETRY_AFTER="${2:?--retry-after needs seconds}"; shift 2 ;;
      *) usage ;;
    esac
  done
  whole_number "$TTL" || { echo "agmsg: --ttl must be a whole number" >&2; exit 64; }
  whole_number "$FALLBACK_AFTER" || { echo "agmsg: --fallback-after must be a whole number" >&2; exit 64; }
  whole_number "$RETRY_AFTER" || { echo "agmsg: --retry-after must be a whole number" >&2; exit 64; }
}

emit_status() {
  local lease_id
  lease_id="$(basename "${STATE%.state}")"
  printf 'status=%s lease_id=%s team=%s name=%s thread=%s heartbeat_automation_id=%s watchdog_automation_id=%s\n' \
    "$STATUS" "$lease_id" "$TEAM" "$NAME" "$THREAD" \
    "${HEARTBEAT_AUTOMATION_ID:-none}" "${WATCHDOG_AUTOMATION_ID:-none}"
}

case "$ACTION" in
  arm)
    [ "$#" -ge 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    shift 4
    parse_timing_options "$@"
    acquire_lock
    now="$(date +%s)"
    load_state || true
    STATUS="active"
    LAST_HEARTBEAT="$now"
    EXPIRES_AT=$((now + TTL))
    FAILURES=0
    write_state
    emit_status
    ;;
  heartbeat)
    [ "$#" -ge 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    shift 4
    parse_timing_options "$@"
    acquire_lock
    if ! load_state; then
      echo "status=inactive"
      exit 3
    fi
    if [ "$STATUS" = "inactive" ] || [ "$STATUS" = "expired" ]; then
      emit_status
      exit 3
    fi
    now="$(date +%s)"
    STATUS="active"
    LAST_HEARTBEAT="$now"
    EXPIRES_AT=$((now + TTL))
    FAILURES=0
    write_state
    emit_status
    ;;
  claim)
    [ "$#" -ge 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    shift 4
    parse_timing_options "$@"
    acquire_lock
    if ! load_state; then
      echo "status=inactive"
      exit 3
    fi
    now="$(date +%s)"
    if [ "$STATUS" != "active" ]; then
      emit_status
      exit 3
    fi
    if [ "$EXPIRES_AT" -le "$now" ]; then
      STATUS="expired"
      write_state
      emit_status
      exit 3
    fi
    if [ "$FALLBACK_AFTER" -gt 0 ] && [ $((now - LAST_HEARTBEAT)) -lt "$FALLBACK_AFTER" ]; then
      STATUS="healthy"
      emit_status
      exit 2
    fi
    set +e
    pending="$("$SCRIPT_DIR/watch-once.sh" "$PROJECT" codex \
      --team "$TEAM" --name "$NAME" --owner "$THREAD" --claim \
      --timeout 0 --interval 1 2>&1)"
    pending_status=$?
    set -e
    if [ "$pending_status" -eq 2 ]; then
      STATUS="active"
      PENDING_WAKE_ID=0
      PENDING_WAKE_AT=0
      write_state
      echo "status=idle"
      exit 2
    fi
    if [ "$pending_status" -ne 0 ]; then
      printf 'status=error detail=%s\n' "$(printf '%s' "$pending" | tr '\n' ' ')"
      exit 1
    fi
    count="$(printf '%s\n' "$pending" | sed -n 's/.*count=\([0-9][0-9]*\).*/\1/p' | head -1)"
    max_id="$(printf '%s\n' "$pending" | sed -n 's/.*max_id=\([0-9][0-9]*\).*/\1/p' | head -1)"
    whole_number "$count" || count=0
    whole_number "$max_id" || max_id=0
    newest_at="$LAST_WAKE_AT"
    [ "$PENDING_WAKE_AT" -gt "$newest_at" ] && newest_at="$PENDING_WAKE_AT"
    newest_id="$LAST_WAKE_ID"
    [ "$PENDING_WAKE_ID" -gt "$newest_id" ] && newest_id="$PENDING_WAKE_ID"
    if [ "$max_id" -le "$newest_id" ] && [ $((now - newest_at)) -lt "$RETRY_AFTER" ]; then
      STATUS="active"
      write_state
      printf 'status=waiting count=%s max_id=%s retry_in=%s\n' \
        "$count" "$max_id" "$((RETRY_AFTER - (now - newest_at)))"
      exit 2
    fi
    STATUS="active"
    PENDING_WAKE_ID="$max_id"
    PENDING_WAKE_AT="$now"
    write_state
    printf 'status=wake count=%s max_id=%s thread=%s team=%s name=%s\n' \
      "$count" "$max_id" "$THREAD" "$TEAM" "$NAME"
    ;;
  delivered|failed)
    [ "$#" -eq 5 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    max_id="$5"
    whole_number "$max_id" || { echo "agmsg: max_id must be a whole number" >&2; exit 64; }
    acquire_lock
    if ! load_state; then
      echo "status=inactive"
      exit 3
    fi
    now="$(date +%s)"
    if [ "$ACTION" = "delivered" ]; then
      LAST_WAKE_ID="$max_id"
      LAST_WAKE_AT="$now"
      FAILURES=0
      STATUS="active"
    else
      FAILURES=$((FAILURES + 1))
      if [ "$FAILURES" -ge 3 ]; then
        STATUS="error"
      else
        STATUS="active"
      fi
    fi
    PENDING_WAKE_ID=0
    PENDING_WAKE_AT=0
    write_state
    emit_status
    ;;
  automation)
    [ "$#" -eq 6 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    acquire_lock
    load_state || { echo "status=inactive"; exit 3; }
    HEARTBEAT_AUTOMATION_ID="$5"
    WATCHDOG_AUTOMATION_ID="$6"
    reject_line_breaks "$HEARTBEAT_AUTOMATION_ID" || exit 64
    reject_line_breaks "$WATCHDOG_AUTOMATION_ID" || exit 64
    write_state
    emit_status
    ;;
  prompt)
    [ "$#" -eq 5 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    prompt_kind="$5"
    printf -v lease_cmd '%q %q %q %q %q' \
      "$SCRIPT_DIR/codex-monitor-lease.sh" heartbeat "$PROJECT" "$TEAM" "$NAME"
    lease_cmd="$lease_cmd $(printf '%q' "$THREAD")"
    printf -v claim_cmd '%q %q %q %q %q %q' \
      "$SCRIPT_DIR/codex-monitor-lease.sh" claim "$PROJECT" "$TEAM" "$NAME" "$THREAD"
    printf -v inbox_cmd '%q %q %q' \
      "$SKILL_DIR/scripts/inbox.sh" "$TEAM" "$NAME"
    printf -v delivered_cmd '%q %q %q %q %q' \
      "$SCRIPT_DIR/codex-monitor-lease.sh" delivered "$PROJECT" "$TEAM" "$NAME"
    delivered_cmd="$delivered_cmd $(printf '%q' "$THREAD") <max_id>"
    printf -v failed_cmd '%q %q %q %q %q' \
      "$SCRIPT_DIR/codex-monitor-lease.sh" failed "$PROJECT" "$TEAM" "$NAME"
    failed_cmd="$failed_cmd $(printf '%q' "$THREAD") <max_id>"
    case "$prompt_kind" in
      heartbeat)
        cat <<EOF
This is the opt-in agmsg heartbeat for $TEAM/$NAME in Codex thread $THREAD.
Run this heartbeat command first:
$lease_cmd
If it reports inactive, expired, or error, delete or pause both automation ids reported by the lease and stop.
Then run:
$claim_cmd --retry-after 90
If it reports idle, waiting, or healthy, stay quiet.
If it reports status=wake, record max_id, run the official inbox command below, and let this visible Codex thread handle the messages within its existing scope:
$inbox_cmd
After inbox.sh returns, run:
$delivered_cmd
Reply to senders through the official agmsg scripts when needed. Never read another identity's inbox. Do not access the agmsg database directly. If inbox delivery fails, run:
$failed_cmd
EOF
        ;;
      watchdog)
        cat <<EOF
This is the independent fallback watchdog for the opt-in agmsg lease $TEAM/$NAME targeting Codex thread $THREAD.
Run:
$claim_cmd --fallback-after 150 --retry-after 90
If it reports healthy, idle, waiting, inactive, expired, or error, do not read any inbox body. Stay quiet, except that inactive or expired must delete or pause both automation ids reported by the lease.
If it reports status=wake, use the Codex app send_message_to_thread capability to send this follow-up to thread $THREAD: "agmsg has unread mail for $TEAM/$NAME. Run $inbox_cmd now, handle the messages in this visible thread, and reply through the official agmsg scripts when needed. Do not read any other identity's inbox or access the database directly."
Only after send_message_to_thread succeeds, run:
$delivered_cmd
If the visible wake fails, run:
$failed_cmd
The watchdog is an unread-only collector. It must never run inbox.sh or mark messages read itself.
EOF
        ;;
      *) usage ;;
    esac
    ;;
  status)
    [ "$#" -eq 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    load_state || { echo "status=inactive"; exit 3; }
    emit_status
    ;;
  disarm)
    [ "$#" -eq 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    acquire_lock
    if load_state; then
      STATUS="inactive"
      emit_status
    else
      echo "status=inactive"
    fi
    rm -f "$STATE"
    ;;
  disarm-project)
    [ "$#" -eq 1 ] || usage
    PROJECT="$(agmsg_resolve_project "$1" codex)"
    found=0
    for state in "$RUN_DIR"/codex-monitor-lease.*.state; do
      [ -f "$state" ] || continue
      [ "$(state_field project "$state")" = "$PROJECT" ] || continue
      STATE="$state"
      LOCK="$STATE.lock"
      acquire_lock
      if [ ! -f "$STATE" ] || [ "$(state_field project "$STATE")" != "$PROJECT" ]; then
        release_lock
        LOCK=""
        continue
      fi
      found=1
      printf 'status=inactive lease_id=%s team=%s name=%s thread=%s heartbeat_automation_id=%s watchdog_automation_id=%s\n' \
        "$(basename "${STATE%.state}")" \
        "$(state_field team "$STATE")" \
        "$(state_field name "$STATE")" \
        "$(state_field thread "$STATE")" \
        "$(state_field heartbeat_automation_id "$STATE")" \
        "$(state_field watchdog_automation_id "$STATE")"
      rm -f "$STATE"
      release_lock
      LOCK=""
    done
    [ "$found" -eq 1 ] || echo "status=inactive"
    ;;
  deactivate-thread)
    [ "$#" -eq 2 ] || usage
    PROJECT="$(agmsg_resolve_project "$1" codex)"
    THREAD="$2"
    found=0
    for state in "$RUN_DIR"/codex-monitor-lease.*.state; do
      [ -f "$state" ] || continue
      [ "$(state_field project "$state")" = "$PROJECT" ] || continue
      [ "$(state_field thread "$state")" = "$THREAD" ] || continue
      STATE="$state"
      LOCK="$STATE.lock"
      acquire_lock
      if [ ! -f "$STATE" ] || \
        [ "$(state_field project "$STATE")" != "$PROJECT" ] || \
        [ "$(state_field thread "$STATE")" != "$THREAD" ]; then
        release_lock
        LOCK=""
        continue
      fi
      found=1
      STATUS="inactive"
      TTL="$(state_field ttl "$STATE")"
      EXPIRES_AT="$(date +%s)"
      LAST_HEARTBEAT="$(state_field last_heartbeat "$STATE")"
      LAST_WAKE_ID="$(state_field last_wake_id "$STATE")"
      LAST_WAKE_AT="$(state_field last_wake_at "$STATE")"
      PENDING_WAKE_ID=0
      PENDING_WAKE_AT=0
      FAILURES="$(state_field failures "$STATE")"
      HEARTBEAT_AUTOMATION_ID="$(state_field heartbeat_automation_id "$STATE")"
      WATCHDOG_AUTOMATION_ID="$(state_field watchdog_automation_id "$STATE")"
      TEAM="$(state_field team "$STATE")"
      NAME="$(state_field name "$STATE")"
      write_state
      emit_status
      release_lock
      LOCK=""
    done
    [ "$found" -eq 1 ] || echo "status=inactive"
    ;;
  *) usage ;;
esac
