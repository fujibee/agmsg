#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: codex-diagnose.sh <project> <team> <agent> [--self-test|--confirm NONCE MESSAGE_ID|--status DIAGNOSIS_ID]

Without an option, runs the read-only process/app-server/thread diagnosis.
--self-test sends one structured marker and returns PENDING (exit 3).
--confirm records THREAD_CONFIRMED only; it does not prove which of multiple
TUI instances displaying the same thread is the user's current screen.
End-to-end success additionally requires the marker-derived turn to be visibly
observed on the current TUI. Do not substitute inbox.sh, history.sh, or DB reads.
EOF
}

[ "${1:-}" != "--help" ] || { usage; exit 0; }

# Read-only three-layer Codex monitor diagnosis, with an opt-in two-turn
# end-to-end self-delivery challenge.
PROJECT="${1:?Usage: codex-diagnose.sh <project> <team> <agent> [--self-test|--confirm NONCE MESSAGE_ID|--status DIAGNOSIS_ID]}"
TEAM="${2:?Missing team}"
AGENT="${3:?Missing agent}"
shift 3
ACTION="diagnose"
ACTION_VALUE=""
CONFIRM_MESSAGE_ID=""
case "${1:-}" in
  "") ;;
  --self-test) [ "$#" -eq 1 ] || { echo "codex-diagnose.sh: --self-test takes no value" >&2; exit 2; }; ACTION="self-test" ;;
  --confirm) [ "$#" -eq 3 ] || { echo "codex-diagnose.sh: --confirm requires NONCE MESSAGE_ID" >&2; exit 2; }; ACTION="confirm"; ACTION_VALUE="$2"; CONFIRM_MESSAGE_ID="$3" ;;
  --status) [ "$#" -eq 2 ] || { echo "codex-diagnose.sh: --status requires DIAGNOSIS_ID" >&2; exit 2; }; ACTION="status"; ACTION_VALUE="$2" ;;
  *) echo "codex-diagnose.sh: unknown option: $1" >&2; exit 2 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
source "$SCRIPT_DIR/../../../lib/hash.sh"
source "$SCRIPT_DIR/../../../lib/role-session.sh"
source "$SCRIPT_DIR/../../../lib/node.sh"
source "$SCRIPT_DIR/_home.sh"

PROJECT="$(cd "$PROJECT" && pwd)"
if [ "$ACTION" = "diagnose" ]; then
  exec "$SCRIPT_DIR/codex-diag.sh" "$PROJECT" "$TEAM" "$AGENT"
fi
CODEX_HOME_VALUE="$(agmsg_codex_effective_home)"
CODEX_HOME_HASH="$(printf '%s' "$CODEX_HOME_VALUE" | agmsg_sha1)"
SELF_TEST_PREFIX="agmsg-codex-self-test:v1"

state_file() {
  case "$1" in *[!A-Za-z0-9_-]*|"") return 1 ;; esac
  printf '%s/codex-self-test.%s.json\n' "$RUN_DIR" "$1"
}

json_get() {
  "$NODE_BIN" -e 'const fs=require("fs");const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const v=o[process.argv[2]];if(v!==undefined&&v!==null)process.stdout.write(String(v));' "$1" "$2"
}

write_state() {
  local target="$1" tmp="$1.tmp.$$"
  shift
  "$NODE_BIN" -e 'const fs=require("fs");const out={};for(let i=2;i<process.argv.length;i+=2)out[process.argv[i]]=process.argv[i+1];fs.writeFileSync(process.argv[1],JSON.stringify(out,null,2)+"\n",{mode:0o600});' "$tmp" "$@"
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
}

transition_state() {
  local target="$1" state="$2" tmp="$1.tmp.$$"
  shift 2
  "$NODE_BIN" -e 'const fs=require("fs");const out=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));out.state=process.argv[3];for(let i=4;i<process.argv.length;i+=2)out[process.argv[i]]=process.argv[i+1];fs.writeFileSync(process.argv[2],JSON.stringify(out,null,2)+"\n",{mode:0o600});' "$target" "$tmp" "$state" "$@"
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
}

nonce_digest() {
  printf '%s' "$1" | agmsg_sha1
}

new_nonce() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

jst_identifier() {
  "$NODE_BIN" -e 'const p=new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Tokyo",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit",hour12:false}).formatToParts(new Date());const g=t=>p.find(x=>x.type===t).value;process.stdout.write(`${g("month")}-${g("day")}-${g("hour")}-${g("minute")}-${g("second")}`);'
}
NODE_BIN="$(agmsg_resolve_node 2>/dev/null || true)"
[ -n "$NODE_BIN" ] || { echo "codex-diagnose.sh: node is required" >&2; exit 2; }
# Keep the three-layer diagnosis in one implementation. In particular, the
# canonical diagnostic owns the Windows PowerShell probe; self-delivery must
# not reintroduce a POSIX `ps -eo` fallback before its state machine.
DIAG_OUTPUT=""
DIAG_STATUS=0
if DIAG_OUTPUT="$("$SCRIPT_DIR/codex-diag.sh" "$PROJECT" "$TEAM" "$AGENT" 2>&1)"; then
  DIAG_STATUS=0
else
  DIAG_STATUS=$?
fi
printf '%s\n' "$DIAG_OUTPUT"
overall="$(printf '%s\n' "$DIAG_OUTPUT" | sed -n 's/^codex diagnosis: //p' | head -n 1)"
[ -n "$overall" ] || overall="UNKNOWN"
case "$ACTION" in
  diagnose)
    [ "$overall" = "MATCH" ]
    ;;
  self-test)
    CURRENT_THREAD="${CODEX_THREAD_ID:-}"
    case "$CURRENT_THREAD" in *[!A-Za-z0-9-]*|"") echo "self-delivery: UNKNOWN reason=missing-or-invalid-CODEX_THREAD_ID"; exit 2 ;; esac
    mkdir -p "$RUN_DIR"
    for existing in "$RUN_DIR"/codex-self-test.*.json; do
      [ -f "$existing" ] || continue
      existing_state="$(json_get "$existing" state 2>/dev/null || true)"
      case "$existing_state" in PREPARED|SENT) ;; *) continue ;; esac
      [ "$(json_get "$existing" team 2>/dev/null || true)" = "$TEAM" ] || continue
      [ "$(json_get "$existing" agent 2>/dev/null || true)" = "$AGENT" ] || continue
      [ "$(json_get "$existing" canonical_project 2>/dev/null || true)" = "$PROJECT" ] || continue
      [ "$(json_get "$existing" initiating_thread_id 2>/dev/null || true)" = "$CURRENT_THREAD" ] || continue
      existing_id="$(json_get "$existing" diagnosis_id 2>/dev/null || true)"
      existing_expires="$(json_get "$existing" expires_epoch 2>/dev/null || true)"
      if [ -n "$existing_expires" ] && [ "$(date +%s)" -gt "$existing_expires" ]; then
        transition_state "$existing" EXPIRED
        continue
      fi
      if [ "$existing_state" = "SENT" ]; then
        echo "self-delivery: PENDING diagnosis_id=$existing_id reason=existing-pending"
        exit 3
      fi
      echo "self-delivery: UNKNOWN diagnosis_id=$existing_id reason=existing-prepared"
      exit 2
    done
    DIAGNOSIS_ID="$(jst_identifier)-$(new_nonce | cut -c1-12)"
    NONCE="$(new_nonce)"
    STATE_FILE="$(state_file "$DIAGNOSIS_ID")"
    CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    EXPIRES_EPOCH="$(( $(date +%s) + ${AGMSG_CODEX_SELF_TEST_TTL_SECONDS:-300} ))"
    write_state "$STATE_FILE" \
      schema_version 1 diagnosis_id "$DIAGNOSIS_ID" nonce_digest "$(nonce_digest "$NONCE")" \
      team "$TEAM" agent "$AGENT" canonical_project "$PROJECT" codex_home_hash "$CODEX_HOME_HASH" \
      initiating_thread_id "$CURRENT_THREAD" sent_message_id "" state PREPARED \
      created_at "$CREATED" expires_epoch "$EXPIRES_EPOCH"
    MARKER="$SELF_TEST_PREFIX:$DIAGNOSIS_ID:$NONCE"
    set +e
    SEND_SH="${AGMSG_CODEX_DIAG_SEND_SH:-$SKILL_DIR/scripts/send.sh}"
    SEND_OUTPUT="$(bash "$SEND_SH" "$TEAM" "$AGENT" "$AGENT" "$MARKER" --print-id 2>&1)"
    SEND_STATUS=$?
    set -e
    if [ "$SEND_STATUS" -ne 0 ]; then
      write_state "$STATE_FILE" \
        schema_version 1 diagnosis_id "$DIAGNOSIS_ID" nonce_digest "$(nonce_digest "$NONCE")" \
        team "$TEAM" agent "$AGENT" canonical_project "$PROJECT" codex_home_hash "$CODEX_HOME_HASH" \
        initiating_thread_id "$CURRENT_THREAD" sent_message_id "" state SEND_FAILED \
        created_at "$CREATED" expires_epoch "$EXPIRES_EPOCH" failure_reason "$SEND_OUTPUT"
      echo "self-delivery: SEND_FAILED diagnosis_id=$DIAGNOSIS_ID"
      exit 2
    fi
    MESSAGE_ID="$(printf '%s\n' "$SEND_OUTPUT" | sed -n 's/^message_id=//p' | tail -n 1)"
    [ -n "$MESSAGE_ID" ] || { echo "self-delivery: UNKNOWN diagnosis_id=$DIAGNOSIS_ID reason=send-returned-no-message-id"; exit 2; }
    write_state "$STATE_FILE" \
      schema_version 1 diagnosis_id "$DIAGNOSIS_ID" nonce_digest "$(nonce_digest "$NONCE")" \
      team "$TEAM" agent "$AGENT" canonical_project "$PROJECT" codex_home_hash "$CODEX_HOME_HASH" \
      initiating_thread_id "$CURRENT_THREAD" sent_message_id "$MESSAGE_ID" state SENT \
      created_at "$CREATED" expires_epoch "$EXPIRES_EPOCH"
    echo "self-delivery: PENDING diagnosis_id=$DIAGNOSIS_ID initiating_thread=$CURRENT_THREAD"
    exit 3
    ;;
  confirm)
    NONCE="$ACTION_VALUE"
    case "$NONCE" in *[!A-Fa-f0-9]*|"") echo "self-delivery: UNKNOWN reason=invalid-nonce"; exit 2 ;; esac
    case "$CONFIRM_MESSAGE_ID" in *[!A-Za-z0-9-]*|"") echo "self-delivery: UNKNOWN reason=invalid-message-id"; exit 2 ;; esac
    MATCHING=""
    for candidate in "$RUN_DIR"/codex-self-test.*.json; do
      [ -f "$candidate" ] || continue
      [ "$(json_get "$candidate" nonce_digest 2>/dev/null || true)" = "$(nonce_digest "$NONCE")" ] || continue
      [ -z "$MATCHING" ] || { echo "self-delivery: UNKNOWN reason=ambiguous-nonce"; exit 2; }
      MATCHING="$candidate"
    done
    [ -n "$MATCHING" ] || { echo "self-delivery: UNKNOWN reason=missing-record"; exit 2; }
    NOW_EPOCH="$(date +%s)"
    DIAGNOSIS_ID="$(json_get "$MATCHING" diagnosis_id)"
    EXPECTED_THREAD="$(json_get "$MATCHING" initiating_thread_id)"
    STATE="$(json_get "$MATCHING" state)"
    EXPIRES_EPOCH="$(json_get "$MATCHING" expires_epoch)"
    if [ "$NOW_EPOCH" -gt "$EXPIRES_EPOCH" ]; then
      transition_state "$MATCHING" EXPIRED
      echo "self-delivery: EXPIRED diagnosis_id=$DIAGNOSIS_ID"
      exit 1
    fi
    [ "$STATE" = "SENT" ] || { echo "self-delivery: UNKNOWN diagnosis_id=$DIAGNOSIS_ID reason=state-$STATE"; exit 2; }
    [ "$(json_get "$MATCHING" team)" = "$TEAM" ] && [ "$(json_get "$MATCHING" agent)" = "$AGENT" ] \
      && [ "$(json_get "$MATCHING" canonical_project)" = "$PROJECT" ] \
      && [ "$(json_get "$MATCHING" codex_home_hash)" = "$CODEX_HOME_HASH" ] \
      || { transition_state "$MATCHING" MISMATCH mismatch_reason context; echo "self-delivery: MISMATCH diagnosis_id=$DIAGNOSIS_ID reason=context"; exit 1; }
    [ "$(json_get "$MATCHING" sent_message_id)" = "$CONFIRM_MESSAGE_ID" ] \
      || { transition_state "$MATCHING" MISMATCH mismatch_reason message-id; echo "self-delivery: MISMATCH diagnosis_id=$DIAGNOSIS_ID reason=message-id"; exit 1; }
    [ "${CODEX_THREAD_ID:-}" = "$EXPECTED_THREAD" ] \
      || { transition_state "$MATCHING" MISMATCH mismatch_reason thread confirmed_thread_id "${CODEX_THREAD_ID:-}"; echo "self-delivery: MISMATCH diagnosis_id=$DIAGNOSIS_ID reason=thread expected=$EXPECTED_THREAD actual=${CODEX_THREAD_ID:-unknown}"; exit 1; }
    write_state "$MATCHING" \
      schema_version 1 diagnosis_id "$DIAGNOSIS_ID" nonce_digest "$(nonce_digest "$NONCE")" \
      team "$TEAM" agent "$AGENT" canonical_project "$PROJECT" codex_home_hash "$CODEX_HOME_HASH" \
      initiating_thread_id "$EXPECTED_THREAD" sent_message_id "$CONFIRM_MESSAGE_ID" state THREAD_CONFIRMED \
      created_at "$(json_get "$MATCHING" created_at)" expires_epoch "$EXPIRES_EPOCH" \
      confirmed_thread_id "${CODEX_THREAD_ID:-}" receipt_message_id "$CONFIRM_MESSAGE_ID"
    echo "self-delivery: THREAD_CONFIRMED diagnosis_id=$DIAGNOSIS_ID thread=$EXPECTED_THREAD message_id=$CONFIRM_MESSAGE_ID"
    echo "tui-visible: REQUIRES_CURRENT_SCREEN_OBSERVATION"
    [ "$overall" = "MATCH" ] || exit 2
    exit 0
    ;;
  status)
    [ -d "$RUN_DIR" ] || { echo "self-delivery: UNKNOWN diagnosis_id=$ACTION_VALUE reason=missing-record"; exit 2; }
    STATE_FILE="$(state_file "$ACTION_VALUE")" || { echo "self-delivery: UNKNOWN reason=invalid-diagnosis-id"; exit 2; }
    [ -f "$STATE_FILE" ] || { echo "self-delivery: UNKNOWN diagnosis_id=$ACTION_VALUE reason=missing-record"; exit 2; }
    STATE="$(json_get "$STATE_FILE" state)"
    EXPIRES_EPOCH="$(json_get "$STATE_FILE" expires_epoch 2>/dev/null || true)"
    if { [ "$STATE" = "SENT" ] || [ "$STATE" = "PREPARED" ]; } \
      && [ -n "$EXPIRES_EPOCH" ] && [ "$(date +%s)" -gt "$EXPIRES_EPOCH" ]; then
      transition_state "$STATE_FILE" EXPIRED
      STATE="EXPIRED"
    fi
    case "$STATE" in
      THREAD_CONFIRMED) echo "self-delivery: THREAD_CONFIRMED diagnosis_id=$ACTION_VALUE"; echo "tui-visible: REQUIRES_CURRENT_SCREEN_OBSERVATION"; exit 0 ;;
      MISMATCH|EXPIRED) echo "self-delivery: $STATE diagnosis_id=$ACTION_VALUE"; exit 1 ;;
      SENT) echo "self-delivery: PENDING diagnosis_id=$ACTION_VALUE"; exit 3 ;;
      *) echo "self-delivery: $STATE diagnosis_id=$ACTION_VALUE"; exit 2 ;;
    esac
    ;;
esac
