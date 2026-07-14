#!/usr/bin/env bash
set -euo pipefail

# State machine for one ChatGPT Scheduled task that returns to the same Codex
# conversation. It only checks unread metadata. ChatGPT remains responsible for
# running inbox.sh visibly and for changing this task's own recurrence.

ACTION="${1:-}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="${AGMSG_RUN_PATH:-$SKILL_DIR/run}"
WATCH_ONCE="${AGMSG_WATCH_ONCE:-$SCRIPT_DIR/watch-once.sh}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../lib/validate.sh"

FAST_WINDOW="${AGMSG_CODEX_SCHEDULED_FAST_WINDOW:-1800}"
MEDIUM_WINDOW="${AGMSG_CODEX_SCHEDULED_MEDIUM_WINDOW:-14400}"
TTL="${AGMSG_CODEX_SCHEDULED_TTL:-86400}"
FAST_INTERVAL="${AGMSG_CODEX_SCHEDULED_FAST_INTERVAL:-120}"
MEDIUM_INTERVAL="${AGMSG_CODEX_SCHEDULED_MEDIUM_INTERVAL:-900}"
SLOW_INTERVAL="${AGMSG_CODEX_SCHEDULED_SLOW_INTERVAL:-3600}"
RETRY_AFTER="${AGMSG_CODEX_SCHEDULED_RETRY_AFTER:-300}"

usage() {
  cat >&2 <<'EOF'
Usage:
  codex-scheduled-monitor.sh arm <project> <team> <name> <owner> [--now <epoch>]
  codex-scheduled-monitor.sh check <project> <team> <name> <owner> [--now <epoch>] [--force]
  codex-scheduled-monitor.sh delivered <project> <team> <name> <owner> <max_id> [--now <epoch>]
  codex-scheduled-monitor.sh scheduled <project> <team> <name> <owner> <interval_sec>
  codex-scheduled-monitor.sh status <project> <team> <name> <owner> [--now <epoch>]
  codex-scheduled-monitor.sh stop <project> <team> <name> <owner>
  codex-scheduled-monitor.sh prompt <project> <team> <name> <owner>
EOF
  exit 64
}

whole_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

reject_line_breaks() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; *) return 0 ;; esac
}

for value in "$FAST_WINDOW" "$MEDIUM_WINDOW" "$TTL" \
  "$FAST_INTERVAL" "$MEDIUM_INTERVAL" "$SLOW_INTERVAL" "$RETRY_AFTER"; do
  whole_number "$value" || { echo "agmsg: scheduled timing values must be whole numbers" >&2; exit 64; }
done
[ "$FAST_WINDOW" -lt "$MEDIUM_WINDOW" ] || { echo "agmsg: fast window must end before medium window" >&2; exit 64; }
[ "$MEDIUM_WINDOW" -lt "$TTL" ] || { echo "agmsg: medium window must end before ttl" >&2; exit 64; }

PROJECT=""
TEAM=""
NAME=""
OWNER=""
STATE=""
LOCK=""
STATUS="active"
CYCLE_STARTED_AT=0
EXPIRES_AT=0
LAST_CHECKED_AT=0
LAST_SEEN_ID=0
LAST_DELIVERED_ID=0
PENDING_ID=0
PENDING_AT=0
FAILURES=0
SCHEDULED_INTERVAL="$FAST_INTERVAL"
NOW=""
FORCE=0

state_field() {
  local key="$1" file="$2"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1
}

load_state() {
  [ -f "$STATE" ] || return 1
  STATUS="$(state_field status "$STATE")"
  CYCLE_STARTED_AT="$(state_field cycle_started_at "$STATE")"
  EXPIRES_AT="$(state_field expires_at "$STATE")"
  LAST_CHECKED_AT="$(state_field last_checked_at "$STATE")"
  LAST_SEEN_ID="$(state_field last_seen_id "$STATE")"
  LAST_DELIVERED_ID="$(state_field last_delivered_id "$STATE")"
  PENDING_ID="$(state_field pending_id "$STATE")"
  PENDING_AT="$(state_field pending_at "$STATE")"
  FAILURES="$(state_field failures "$STATE")"
  SCHEDULED_INTERVAL="$(state_field scheduled_interval "$STATE")"
  for value in CYCLE_STARTED_AT EXPIRES_AT LAST_CHECKED_AT LAST_SEEN_ID \
    LAST_DELIVERED_ID PENDING_ID PENDING_AT FAILURES SCHEDULED_INTERVAL; do
    whole_number "${!value:-}" || printf -v "$value" 0
  done
  [ "$SCHEDULED_INTERVAL" -gt 0 ] || SCHEDULED_INTERVAL="$FAST_INTERVAL"
}

write_state() {
  local tmp="$STATE.$$"
  mkdir -p "$RUN_DIR"
  {
    printf 'project=%s\n' "$PROJECT"
    printf 'type=codex\n'
    printf 'team=%s\n' "$TEAM"
    printf 'name=%s\n' "$NAME"
    printf 'owner=%s\n' "$OWNER"
    printf 'status=%s\n' "$STATUS"
    printf 'cycle_started_at=%s\n' "$CYCLE_STARTED_AT"
    printf 'expires_at=%s\n' "$EXPIRES_AT"
    printf 'last_checked_at=%s\n' "$LAST_CHECKED_AT"
    printf 'last_seen_id=%s\n' "$LAST_SEEN_ID"
    printf 'last_delivered_id=%s\n' "$LAST_DELIVERED_ID"
    printf 'pending_id=%s\n' "$PENDING_ID"
    printf 'pending_at=%s\n' "$PENDING_AT"
    printf 'failures=%s\n' "$FAILURES"
    printf 'scheduled_interval=%s\n' "$SCHEDULED_INTERVAL"
  } > "$tmp"
  mv "$tmp" "$STATE"
}

release_lock() {
  [ -n "$LOCK" ] || return 0
  rm -f "$LOCK/pid" 2>/dev/null || true
  rmdir "$LOCK" 2>/dev/null || true
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
      echo "status=busy"
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
  OWNER="${4:?Missing owner}"
  agmsg_validate_team_name "$TEAM"
  agmsg_validate_agent_name "$NAME"
  reject_line_breaks "$PROJECT" || { echo "agmsg: invalid project path" >&2; exit 64; }
  reject_line_breaks "$OWNER" || { echo "agmsg: invalid owner" >&2; exit 64; }
  [ -n "$OWNER" ] || { echo "agmsg: scheduled monitor needs an exact owner" >&2; exit 64; }
  PROJECT="$(agmsg_resolve_project "$PROJECT" codex)"
  local key
  key="$(printf '%s\t%s\t%s\t%s' "$PROJECT" "$TEAM" "$NAME" "$OWNER" | agmsg_sha1)"
  STATE="$RUN_DIR/codex-scheduled-monitor.$key.state"
  LOCK="$STATE.lock"
}

parse_now_options() {
  NOW=""
  FORCE=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now) NOW="${2:?--now needs epoch seconds}"; shift 2 ;;
      --force) FORCE=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$NOW" ] || NOW="$(date +%s)"
  whole_number "$NOW" || { echo "agmsg: --now must be epoch seconds" >&2; exit 64; }
}

stage_for_elapsed() {
  local elapsed="$1"
  if [ "$elapsed" -lt "$FAST_WINDOW" ]; then
    echo fast
  elif [ "$elapsed" -lt "$MEDIUM_WINDOW" ]; then
    echo medium
  else
    echo slow
  fi
}

interval_for_stage() {
  case "$1" in
    fast) echo "$FAST_INTERVAL" ;;
    medium) echo "$MEDIUM_INTERVAL" ;;
    slow) echo "$SLOW_INTERVAL" ;;
    *) return 1 ;;
  esac
}

rrule_for_interval() {
  case "$1" in
    120) echo 'FREQ=MINUTELY;INTERVAL=2' ;;
    900) echo 'FREQ=MINUTELY;INTERVAL=15' ;;
    3600) echo 'FREQ=HOURLY;INTERVAL=1' ;;
    *) printf 'FREQ=SECONDLY;INTERVAL=%s\n' "$1" ;;
  esac
}

emit_runtime_status() {
  local now="$1" elapsed stage interval change next_due
  elapsed=$((now - CYCLE_STARTED_AT))
  [ "$elapsed" -ge 0 ] || elapsed=0
  stage="$(stage_for_elapsed "$elapsed")"
  interval="$(interval_for_stage "$stage")"
  change=0
  [ "$interval" -eq "$SCHEDULED_INTERVAL" ] || change=1
  next_due=$((LAST_CHECKED_AT + SCHEDULED_INTERVAL))
  printf 'stage=%s elapsed=%s next_interval=%s next_rrule=%s schedule_change=%s next_due_at=%s expires_at=%s' \
    "$stage" "$elapsed" "$interval" "$(rrule_for_interval "$interval")" \
    "$change" "$next_due" "$EXPIRES_AT"
}

case "$ACTION" in
  arm)
    [ "$#" -ge 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    shift 4
    parse_now_options "$@"
    acquire_lock
    STATUS="active"
    CYCLE_STARTED_AT="$NOW"
    EXPIRES_AT=$((NOW + TTL))
    # The Scheduled task is created at the two-minute cadence, so the first
    # check is due two minutes after arming. Recording NOW also rejects an
    # accidental duplicate run immediately after task creation.
    LAST_CHECKED_AT="$NOW"
    LAST_SEEN_ID=0
    LAST_DELIVERED_ID=0
    PENDING_ID=0
    PENDING_AT=0
    FAILURES=0
    SCHEDULED_INTERVAL="$FAST_INTERVAL"
    write_state
    printf 'status=active '
    emit_runtime_status "$NOW"
    printf '\n'
    ;;
  check)
    [ "$#" -ge 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    shift 4
    parse_now_options "$@"
    acquire_lock
    load_state || { echo "status=inactive"; exit 3; }
    [ "$STATUS" = "active" ] || { printf 'status=%s\n' "$STATUS"; exit 3; }
    if [ "$NOW" -gt "$EXPIRES_AT" ]; then
      STATUS="expired"
      write_state
      printf 'status=expired schedule_action=pause '
      emit_runtime_status "$NOW"
      printf '\n'
      exit 3
    fi
    if [ "$FORCE" -ne 1 ] && [ "$NOW" -lt $((LAST_CHECKED_AT + SCHEDULED_INTERVAL)) ]; then
      printf 'status=not_due '
      emit_runtime_status "$NOW"
      printf '\n'
      exit 2
    fi

    set +e
    pending="$("$WATCH_ONCE" "$PROJECT" codex \
      --team "$TEAM" --name "$NAME" --owner "$OWNER" --claim \
      --timeout 0 --interval 1 2>&1)"
    pending_status=$?
    set -e
    LAST_CHECKED_AT="$NOW"

    if [ "$pending_status" -eq 2 ]; then
      PENDING_ID=0
      PENDING_AT=0
      if [ "$NOW" -ge "$EXPIRES_AT" ]; then
        STATUS="expired"
        write_state
        printf 'status=expired schedule_action=pause '
        emit_runtime_status "$NOW"
        printf '\n'
        exit 3
      fi
      write_state
      printf 'status=idle '
      emit_runtime_status "$NOW"
      printf '\n'
      exit 2
    fi
    if [ "$pending_status" -ne 0 ]; then
      FAILURES=$((FAILURES + 1))
      write_state
      printf 'status=error failures=%s detail=%s\n' \
        "$FAILURES" "$(printf '%s' "$pending" | tr '\n' ' ')"
      exit 1
    fi

    count="$(printf '%s\n' "$pending" | sed -n 's/.*count=\([0-9][0-9]*\).*/\1/p' | head -1)"
    max_id="$(printf '%s\n' "$pending" | sed -n 's/.*max_id=\([0-9][0-9]*\).*/\1/p' | head -1)"
    whole_number "$count" || count=0
    whole_number "$max_id" || max_id=0
    is_new=0
    if [ "$max_id" -gt "$LAST_SEEN_ID" ]; then
      is_new=1
      LAST_SEEN_ID="$max_id"
      CYCLE_STARTED_AT="$NOW"
      EXPIRES_AT=$((NOW + TTL))
      PENDING_ID="$max_id"
      PENDING_AT="$NOW"
      FAILURES=0
    elif [ "$PENDING_ID" -eq "$max_id" ] && [ $((NOW - PENDING_AT)) -ge "$RETRY_AFTER" ]; then
      PENDING_AT="$NOW"
    else
      write_state
      printf 'status=waiting count=%s max_id=%s new_message=0 ' "$count" "$max_id"
      emit_runtime_status "$NOW"
      printf '\n'
      exit 2
    fi
    write_state
    printf 'status=wake count=%s max_id=%s new_message=%s ' "$count" "$max_id" "$is_new"
    emit_runtime_status "$NOW"
    printf '\n'
    ;;
  delivered)
    [ "$#" -ge 5 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    max_id="$5"
    shift 5
    parse_now_options "$@"
    whole_number "$max_id" || { echo "agmsg: max_id must be a whole number" >&2; exit 64; }
    acquire_lock
    load_state || { echo "status=inactive"; exit 3; }
    [ "$max_id" -le "$LAST_SEEN_ID" ] || { echo "agmsg: max_id was not observed by this monitor" >&2; exit 64; }
    [ "$max_id" -gt "$LAST_DELIVERED_ID" ] && LAST_DELIVERED_ID="$max_id"
    [ "$PENDING_ID" -le "$max_id" ] && { PENDING_ID=0; PENDING_AT=0; }
    FAILURES=0
    write_state
    printf 'status=delivered max_id=%s ' "$max_id"
    emit_runtime_status "$NOW"
    printf '\n'
    ;;
  scheduled)
    [ "$#" -eq 5 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    interval="$5"
    whole_number "$interval" || { echo "agmsg: interval must be a whole number" >&2; exit 64; }
    case "$interval" in
      "$FAST_INTERVAL"|"$MEDIUM_INTERVAL"|"$SLOW_INTERVAL") ;;
      *) echo "agmsg: interval is outside the adaptive schedule" >&2; exit 64 ;;
    esac
    acquire_lock
    load_state || { echo "status=inactive"; exit 3; }
    SCHEDULED_INTERVAL="$interval"
    write_state
    printf 'status=scheduled interval=%s rrule=%s\n' "$interval" "$(rrule_for_interval "$interval")"
    ;;
  status)
    [ "$#" -ge 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    shift 4
    parse_now_options "$@"
    load_state || { echo "status=inactive"; exit 3; }
    printf 'status=%s last_seen_id=%s last_delivered_id=%s pending_id=%s ' \
      "$STATUS" "$LAST_SEEN_ID" "$LAST_DELIVERED_ID" "$PENDING_ID"
    emit_runtime_status "$NOW"
    printf '\n'
    ;;
  stop)
    [ "$#" -eq 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    acquire_lock
    rm -f "$STATE"
    echo "status=inactive schedule_action=pause"
    ;;
  prompt)
    [ "$#" -eq 4 ] || usage
    init_identity "$1" "$2" "$3" "$4"
    printf -v check_cmd '%q %q %q %q %q %q' \
      "$SCRIPT_DIR/codex-scheduled-monitor.sh" check "$PROJECT" "$TEAM" "$NAME" "$OWNER"
    printf -v inbox_cmd '%q %q %q' "$SKILL_DIR/scripts/inbox.sh" "$TEAM" "$NAME"
    printf -v delivered_cmd '%q %q %q %q %q' \
      "$SCRIPT_DIR/codex-scheduled-monitor.sh" delivered "$PROJECT" "$TEAM" "$NAME"
    delivered_cmd="$delivered_cmd $(printf '%q' "$OWNER") <max_id>"
    printf -v scheduled_cmd '%q %q %q %q %q' \
      "$SCRIPT_DIR/codex-scheduled-monitor.sh" scheduled "$PROJECT" "$TEAM" "$NAME"
    scheduled_cmd="$scheduled_cmd $(printf '%q' "$OWNER") <next_interval>"
    cat <<EOF
This is the single adaptive agmsg monitor for $TEAM/$NAME in this existing ChatGPT task.
Run exactly this metadata-only check first:
$check_cmd
If status is idle, waiting, or not_due, do not run inbox.sh and do not notify the user.
If status is wake, record max_id, run the official visible inbox command below, handle those messages in this task, and reply through official agmsg scripts when needed:
$inbox_cmd
After inbox.sh succeeds, run:
$delivered_cmd
If schedule_change=1, update this same Scheduled task to next_rrule. Do not create another task. Only after the update succeeds, run:
$scheduled_cmd
If status is expired or schedule_action=pause, pause this same Scheduled task.
Never edit automation files directly. Never use Desktop relay, CODEX_APP_SERVER_WS_URL, launchd, cron, a background receiver, codex exec resume, or a ChatGPT.app restart.
If the native Scheduled-task update capability is unavailable, leave agmsg unread, pause this task if possible, and visibly report the limitation once.
EOF
    ;;
  *) usage ;;
esac
