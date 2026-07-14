#!/usr/bin/env bash
set -euo pipefail
umask 077

# Bind one agmsg identity to one exact visible Codex Desktop task. Monitor mode
# has one transport only: a role-scoped bridge connects through the authenticated
# global Desktop relay. Any missing/ambiguous state downgrades to foreground turn
# delivery and leaves unread messages untouched.

PROJECT="${1:?Usage: actas-monitor.sh <project> <type> <name> [session_id]}"
TYPE="${2:?Missing type}"
NAME="${3:?Missing name}"
SESSION_ID="${4:-${CODEX_THREAD_ID:-}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="${AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR:-$SKILL_DIR/run}"

# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/node.sh
source "$SCRIPT_DIR/../../../lib/node.sh"
# shellcheck source=../../../lib/compat.sh
source "$SCRIPT_DIR/../../../lib/compat.sh"
# shellcheck source=../../../lib/resolve-project.sh
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck source=../../../lib/actas-lock.sh
source "$SCRIPT_DIR/../../../lib/actas-lock.sh"

PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"
mkdir -p "$RUN_DIR"
NODE_BIN="$(agmsg_resolve_node)"
TAB="$(printf '\t')"

IDS=$("$SCRIPT_DIR/../../../identities.sh" "$PROJECT" "$TYPE" 2>/dev/null \
  | awk -F "$TAB" -v want="$NAME" -v tab="$TAB" 'NF >= 2 && $2 == want { print $1 tab $2 }' \
  | sort -u || true)
COUNT="$(printf '%s\n' "$IDS" | grep -c . || true)"
case "$COUNT" in
  0) echo "status=not_registered name=$NAME"; exit 2 ;;
  1)
    IFS="$TAB" read -r TEAM _agent <<EOF
$IDS
EOF
    ;;
  *)
    echo "status=multiple_teams name=$NAME"
    printf '%s\n' "$IDS" | awk -F "$TAB" '{ print "team=" $1 }'
    exit 3
    ;;
esac

PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
SAFE_TEAM="$(_actas_lock_encode "$TEAM")"
SAFE_NAME="$(_actas_lock_encode "$NAME")"
STATE_KEY="$PROJECT_HASH.$SAFE_TEAM.$SAFE_NAME"
BASE="$RUN_DIR/codex-bridge.$STATE_KEY"
PIDFILE="$BASE.pid"
META="$BASE.meta"
HEALTH="$BASE.health"
APPSERVER_FILE="$BASE.appserver"
BINDING_FILE="$BASE.binding"
PLIST="$BASE.plist"
LOG="$BASE.log"
LABEL="com.agmsg.codex-bridge.$STATE_KEY"
DOMAIN="gui/$(id -u)"
CHAT_META="$RUN_DIR/codex-chat-visible.$STATE_KEY.meta"
SEAT="$(codex_seat_path "$TEAM" "$NAME")"
RELAY_HEALTH="$RUN_DIR/codex-desktop-relay.health"
RELAY_ENDPOINT_FILE="${AGMSG_CODEX_DESKTOP_RELAY_BRIDGE_ENDPOINT_FILE:-$RUN_DIR/codex-desktop-relay.bridge-endpoint}"

MODE=$("$SCRIPT_DIR/../../../delivery.sh" status "$TYPE" "$PROJECT" 2>/dev/null \
  | sed -n 's/^mode: //p')

bootout_label() {
  local label="$1" check=0
  case "$label" in
    com.agmsg.codex-bridge.*)
      case "${label#com.agmsg.codex-bridge.}" in
        ""|*[!A-Za-z0-9._%-]*) return 0 ;;
      esac
      ;;
    *) return 0 ;;
  esac
  command -v launchctl >/dev/null 2>&1 || return 0
  launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  while [ "$check" -lt 30 ] && launchctl print "$DOMAIN/$label" >/dev/null 2>&1; do
    sleep 0.1
    check=$((check + 1))
  done
}

bridge_pid_matches_state() {
  local pid="$1" base="$2" meta="$3" state_key expected cmd
  local meta_project meta_type meta_team meta_name meta_thread
  state_key="${base##*/codex-bridge.}"
  case "$state_key" in ""|*[!A-Za-z0-9._%-]*) return 1 ;; esac
  [ -f "$meta" ] || return 1
  meta_project="$(sed -n 's/^project=//p' "$meta" | head -1)"
  meta_type="$(sed -n 's/^type=//p' "$meta" | head -1)"
  meta_team="$(sed -n 's/^team=//p' "$meta" | head -1)"
  meta_name="$(sed -n 's/^name=//p' "$meta" | head -1)"
  meta_thread="$(sed -n 's/^thread=//p' "$meta" | head -1)"
  [ -n "$meta_project" ] \
    && [ "$(agmsg_canonical_path "$meta_project")" = "$(agmsg_canonical_path "$PROJECT")" ] \
    && [ "$meta_type" = "$TYPE" ] && [ -n "$meta_team" ] \
    && [ -n "$meta_name" ] && [ -n "$meta_thread" ] || return 1
  case "$meta_thread" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  expected="$SCRIPT_DIR/codex-bridge.js --project $PROJECT --type $TYPE --team $meta_team --name $meta_name --state-key $state_key --app-server-file $base.appserver --thread $meta_thread"
  cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  case " $cmd " in *" $expected "*) return 0 ;; esac
  return 1
}

stop_bridge_base() {
  local base="$1" meta pidfile pid="" label="" state_key
  meta="$base.meta"
  pidfile="$base.pid"
  case "$base" in "$RUN_DIR/codex-bridge.$PROJECT_HASH."*) ;; *) return 0 ;; esac
  state_key="${base##*/codex-bridge.}"
  case "$state_key" in ""|*[!A-Za-z0-9._%-]*) return 0 ;; esac
  label="com.agmsg.codex-bridge.$state_key"
  bootout_label "$label"
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    if bridge_pid_matches_state "$pid" "$base" "$meta"; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      bridge_pid_matches_state "$pid" "$base" "$meta" \
        && kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$base.pid" "$base.meta" "$base.health" "$base.appserver" \
    "$base.plist" "$base.log" "$base.last-ids" "$base.binding"
  rm -f "$base".wake.*.json "$base.relay-wake.json"
}

start_visible_turn_delivery() {
  local thread_id="$1" reason="$2" requested_mode="$MODE"
  stop_bridge_base "$BASE"
  {
    printf 'project=%s\n' "$PROJECT"
    printf 'type=%s\n' "$TYPE"
    printf 'team=%s\n' "$TEAM"
    printf 'name=%s\n' "$NAME"
    printf 'thread=%s\n' "${thread_id:-unresolved}"
    printf 'transport=codex-chat-visible-turn\n'
    printf 'status=waiting_for_chat_turn\n'
    printf 'requested_mode=%s\n' "$requested_mode"
    printf 'effective_mode=turn\n'
    printf 'reason=%s\n' "$reason"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$CHAT_META"
  echo "status=visible_turn_only team=$TEAM name=$NAME thread=${thread_id:-unresolved} transport=codex-chat-visible-turn requested_mode=$requested_mode effective_mode=turn reason=$reason"
  exit 0
}

start_unbound_visible_turn() {
  local reason="$1"
  echo "status=visible_turn_only team=$TEAM name=$NAME thread=unresolved transport=codex-chat-visible-turn requested_mode=$MODE effective_mode=turn reason=$reason bound=false"
  exit 0
}

claim_role_for_thread() {
  local owner_project owner_type owner_team owner_name owner_thread _owner_at tmp claim_output marker
  marker="$(actas_codex_owner "$PROJECT" "$THREAD_ID")"
  if [ -f "$SEAT" ]; then
    IFS=$'\t' read -r owner_project owner_type owner_team owner_name owner_thread _owner_at < "$SEAT" || true
    if [ "$owner_project" = "$PROJECT" ] && [ "$owner_type" = "$TYPE" ] \
        && [ "$owner_team" = "$TEAM" ] && [ "$owner_name" = "$NAME" ] \
        && [ "$owner_thread" = "$THREAD_ID" ]; then
      if claim_output="$(actas_lock_claim "$TEAM" "$NAME" "$marker" 2>&1)"; then
        return 0
      fi
      printf 'status=role_held team=%s name=%s owner_thread=%s requested_thread=%s\n' \
        "$TEAM" "$NAME" "${claim_output#held:}" "$THREAD_ID"
      return 1
    fi
    printf 'status=role_held team=%s name=%s owner_thread=%s requested_thread=%s\n' \
      "$TEAM" "$NAME" "${owner_thread:-unknown}" "$THREAD_ID"
    return 1
  fi
  if ! claim_output="$(actas_lock_claim "$TEAM" "$NAME" "$marker" 2>&1)"; then
    printf 'status=role_held team=%s name=%s owner_thread=%s requested_thread=%s\n' \
      "$TEAM" "$NAME" "${claim_output#held:}" "$THREAD_ID"
    return 1
  fi
  if ! tmp="$(mktemp "$RUN_DIR/.codex-seat.XXXXXX")"; then
    actas_lock_release "$TEAM" "$NAME" "$marker"
    return 1
  fi
  chmod 600 "$tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PROJECT" "$TYPE" "$TEAM" "$NAME" "$THREAD_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  if ln "$tmp" "$SEAT" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  IFS=$'\t' read -r owner_project owner_type owner_team owner_name owner_thread _owner_at < "$SEAT" || true
  [ "$owner_project" = "$PROJECT" ] && [ "$owner_type" = "$TYPE" ] \
    && [ "$owner_team" = "$TEAM" ] && [ "$owner_name" = "$NAME" ] \
    && [ "$owner_thread" = "$THREAD_ID" ] && return 0
  actas_lock_release "$TEAM" "$NAME" "$marker"
  printf 'status=role_held team=%s name=%s owner_thread=%s requested_thread=%s\n' \
    "$TEAM" "$NAME" "${owner_thread:-unknown}" "$THREAD_ID"
  return 1
}

release_other_role_for_thread() {
  local seat saved_project saved_type saved_team saved_name saved_thread _saved_at key base chat
  for seat in "$RUN_DIR"/codex-seat.*.tsv; do
    [ -f "$seat" ] || continue
    [ "$seat" = "$SEAT" ] && continue
    IFS=$'\t' read -r saved_project saved_type saved_team saved_name saved_thread _saved_at < "$seat" || true
    [ "$saved_project" = "$PROJECT" ] && [ "$saved_type" = "$TYPE" ] \
      && [ "$saved_thread" = "$THREAD_ID" ] || continue
    key="$PROJECT_HASH.$(_actas_lock_encode "$saved_team").$(_actas_lock_encode "$saved_name")"
    base="$RUN_DIR/codex-bridge.$key"
    chat="$RUN_DIR/codex-chat-visible.$key.meta"
    stop_bridge_base "$base"
    actas_codex_seat_release "$saved_team" "$saved_name" "$saved_project" "$saved_thread"
    rm -f "$chat"
  done
}

THREAD_ID="${AGMSG_CODEX_ACTAS_THREAD:-${CODEX_THREAD_ID:-$SESSION_ID}}"
case "$THREAD_ID" in loaded|current|unresolved) THREAD_ID="" ;; esac

case "$MODE" in
  monitor|both|turn) ;;
  off|"")
    stop_bridge_base "$BASE"
    echo "status=receive_disabled team=$TEAM name=$NAME mode=${MODE:-off}"
    exit 0
    ;;
  *) echo "status=invalid_mode team=$TEAM name=$NAME mode=$MODE" >&2; exit 4 ;;
esac

[ -n "$THREAD_ID" ] || start_unbound_visible_turn "exact_thread_id_unavailable"
if ! [[ "$THREAD_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  start_unbound_visible_turn "exact_thread_id_invalid"
fi

# Durable Codex seat metadata lives in a dedicated namespace, while atomic
# exclusivity is shared with generic actas through a non-GC role marker. Both
# are released only by the same task changing roles, SessionEnd, reset/drop,
# or a project delivery-mode teardown.
claim_role_for_thread || exit 5
release_other_role_for_thread

[ "$MODE" = "turn" ] && start_visible_turn_delivery "$THREAD_ID" "foreground_turn_mode"

private_regular_file() {
  local file="$1" mode
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || true)"
  [ "$mode" = "600" ]
}

private_regular_file "$RELAY_ENDPOINT_FILE" \
  || start_visible_turn_delivery "$THREAD_ID" "desktop_relay_endpoint_unavailable"
RELAY_ENDPOINT="$(cat "$RELAY_ENDPOINT_FILE" 2>/dev/null || true)"
if ! printf '%s' "$RELAY_ENDPOINT" \
    | grep -Eq '^ws://127\.0\.0\.1:[0-9]+/bridge/[a-f0-9]{64}$'; then
  start_visible_turn_delivery "$THREAD_ID" "desktop_relay_endpoint_invalid"
fi
RELAY_PORT="${RELAY_ENDPOINT#ws://127.0.0.1:}"
RELAY_PORT="${RELAY_PORT%%/*}"
RELAY_STATUS="$(sed -n 's/^status=//p' "$RELAY_HEALTH" 2>/dev/null | head -1 || true)"
RELAY_PID="$(sed -n 's/^pid=//p' "$RELAY_HEALTH" 2>/dev/null | head -1 || true)"
RELAY_HEALTH_PORT="$(sed -n 's/^port=//p' "$RELAY_HEALTH" 2>/dev/null | head -1 || true)"
RELAY_PRIMARY="$(sed -n 's/^primary_connected=//p' "$RELAY_HEALTH" 2>/dev/null | head -1 || true)"
RELAY_INITIALIZED="$(sed -n 's/^upstream_initialized=//p' "$RELAY_HEALTH" 2>/dev/null | head -1 || true)"
if [ "$RELAY_STATUS" != "ready" ] || [ "$RELAY_PRIMARY" != "1" ] \
    || [ "$RELAY_INITIALIZED" != "1" ] || [ "$RELAY_HEALTH_PORT" != "$RELAY_PORT" ] \
    || [ -z "$RELAY_PID" ] || ! kill -0 "$RELAY_PID" 2>/dev/null; then
  start_visible_turn_delivery "$THREAD_ID" "desktop_relay_not_ready"
fi

bridge_is_ready() {
  local pid meta_thread health_status health_thread label token expected_endpoint
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  [ -f "$META" ] && [ -f "$HEALTH" ] && private_regular_file "$APPSERVER_FILE" \
    && private_regular_file "$BINDING_FILE" || return 1
  [ "$(sed -n 's/^project=//p' "$META" | head -1)" = "$PROJECT" ] || return 1
  [ "$(sed -n 's/^type=//p' "$META" | head -1)" = "$TYPE" ] || return 1
  [ "$(sed -n 's/^team=//p' "$META" | head -1)" = "$TEAM" ] || return 1
  [ "$(sed -n 's/^name=//p' "$META" | head -1)" = "$NAME" ] || return 1
  meta_thread="$(sed -n 's/^thread=//p' "$META" | head -1)"
  health_status="$(sed -n 's/^status=//p' "$HEALTH" | head -1)"
  health_thread="$(sed -n 's/^thread=//p' "$HEALTH" | head -1)"
  [ "$meta_thread" = "$THREAD_ID" ] && [ "$health_thread" = "$THREAD_ID" ] || return 1
  [ "$health_status" = "ready" ] || return 1
  [ "$(sed -n 's/^project=//p' "$BINDING_FILE" | head -1)" = "$PROJECT" ] || return 1
  [ "$(sed -n 's/^type=//p' "$BINDING_FILE" | head -1)" = "$TYPE" ] || return 1
  [ "$(sed -n 's/^team=//p' "$BINDING_FILE" | head -1)" = "$TEAM" ] || return 1
  [ "$(sed -n 's/^name=//p' "$BINDING_FILE" | head -1)" = "$NAME" ] || return 1
  [ "$(sed -n 's/^thread=//p' "$BINDING_FILE" | head -1)" = "$THREAD_ID" ] || return 1
  [ "$(sed -n 's/^state_key=//p' "$BINDING_FILE" | head -1)" = "$STATE_KEY" ] || return 1
  token="$(sed -n 's/^token=//p' "$BINDING_FILE" | head -1)"
  printf '%s' "$token" | grep -Eq '^[a-f0-9]{64}$' || return 1
  expected_endpoint="$RELAY_ENDPOINT/$token"
  [ "$(cat "$APPSERVER_FILE" 2>/dev/null || true)" = "$expected_endpoint" ] || return 1
  label="$(sed -n 's/^launch_label=//p' "$META" | head -1)"
  if [ -n "$label" ]; then
    [ "$label" = "$LABEL" ] && [ -f "$PLIST" ] || return 1
    launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || return 1
  fi
}

if bridge_is_ready; then
  echo "status=already_running team=$TEAM name=$NAME bridge_pid=$(cat "$PIDFILE") app_server=ws://127.0.0.1:$RELAY_PORT/<capability> app_server_source=desktop_relay thread=$THREAD_ID active=true health=$(sed -n 's/^status=//p' "$HEALTH" | head -1)"
  exit 0
fi

stop_bridge_base "$BASE"
ROLE_TOKEN="$("$NODE_BIN" -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
ROLE_ENDPOINT="$RELAY_ENDPOINT/$ROLE_TOKEN"
BINDING_TMP="$BINDING_FILE.$$"
(
  umask 077
  {
    printf 'token=%s\n' "$ROLE_TOKEN"
    printf 'project=%s\n' "$PROJECT"
    printf 'type=%s\n' "$TYPE"
    printf 'team=%s\n' "$TEAM"
    printf 'name=%s\n' "$NAME"
    printf 'thread=%s\n' "$THREAD_ID"
    printf 'state_key=%s\n' "$STATE_KEY"
  } > "$BINDING_TMP"
)
chmod 600 "$BINDING_TMP"
mv "$BINDING_TMP" "$BINDING_FILE"
APPSERVER_TMP="$APPSERVER_FILE.$$"
(umask 077; printf '%s\n' "$ROLE_ENDPOINT" > "$APPSERVER_TMP")
chmod 600 "$APPSERVER_TMP"
mv "$APPSERVER_TMP" "$APPSERVER_FILE"

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}
plist_string() { printf '%s' "$1" | xml_escape; }

write_bridge_plist() {
  local temporary="$PLIST.$$" path_value
  path_value="${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
  : > "$LOG"
  chmod 600 "$LOG"
  cat > "$temporary" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$(plist_string "$LABEL")</string>
  <key>ProgramArguments</key><array>
    <string>$(plist_string "$NODE_BIN")</string>
    <string>$(plist_string "$SCRIPT_DIR/codex-bridge.js")</string>
    <string>--project</string><string>$(plist_string "$PROJECT")</string>
    <string>--type</string><string>$(plist_string "$TYPE")</string>
    <string>--team</string><string>$(plist_string "$TEAM")</string>
    <string>--name</string><string>$(plist_string "$NAME")</string>
    <string>--state-key</string><string>$(plist_string "$STATE_KEY")</string>
    <string>--app-server-file</string><string>$(plist_string "$APPSERVER_FILE")</string>
    <string>--thread</string><string>$(plist_string "$THREAD_ID")</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$(plist_string "$HOME")</string>
    <key>PATH</key><string>$(plist_string "$path_value")</string>
    <key>AGMSG_CODEX_BRIDGE_LAUNCH_LABEL</key><string>$(plist_string "$LABEL")</string>
    <key>AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR</key><string>$(plist_string "$RUN_DIR")</string>
  </dict>
  <key>WorkingDirectory</key><string>$(plist_string "$PROJECT")</string>
  <key>StandardOutPath</key><string>$(plist_string "$LOG")</string>
  <key>StandardErrorPath</key><string>$(plist_string "$LOG")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
</dict></plist>
EOF
  chmod 600 "$temporary"
  mv "$temporary" "$PLIST"
}

BRIDGE_ARGS=(
  "$SCRIPT_DIR/codex-bridge.js"
  --project "$PROJECT"
  --type "$TYPE"
  --team "$TEAM"
  --name "$NAME"
  --state-key "$STATE_KEY"
  --app-server-file "$APPSERVER_FILE"
  --thread "$THREAD_ID"
)

SUPERVISOR="direct"
if [ "${AGMSG_CODEX_BRIDGE_SUPERVISOR:-}" != "direct" ] \
    && [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null 2>&1 \
    && launchctl print "$DOMAIN" >/dev/null 2>&1; then
  SUPERVISOR="launchd"
  write_bridge_plist
  bootout_label "$LABEL"
  rm -f "$PIDFILE" "$META" "$HEALTH"
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1; then
    stop_bridge_base "$BASE"
    start_visible_turn_delivery "$THREAD_ID" "desktop_bridge_launch_failed"
  fi
  launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
else
  nohup "$NODE_BIN" "${BRIDGE_ARGS[@]}" >> "$LOG" 2>&1 &
fi

READY_SECONDS="${AGMSG_CODEX_ACTAS_READY_SECONDS:-8}"
case "$READY_SECONDS" in ''|*[!0-9]*) READY_SECONDS=8 ;; esac
READY_CHECKS=$((READY_SECONDS * 5))
[ "$READY_CHECKS" -gt 0 ] || READY_CHECKS=1
for _ in $(seq 1 "$READY_CHECKS"); do
  if bridge_is_ready; then
    # Recheck the relay after bridge startup; a Desktop disconnect during the
    # handshake must downgrade instead of reporting a stale green bridge.
    if [ "$(sed -n 's/^status=//p' "$RELAY_HEALTH" | head -1)" = "ready" ] \
        && [ "$(sed -n 's/^primary_connected=//p' "$RELAY_HEALTH" | head -1)" = "1" ] \
        && [ "$(sed -n 's/^upstream_initialized=//p' "$RELAY_HEALTH" | head -1)" = "1" ]; then
      rm -f "$CHAT_META"
      echo "status=ok team=$TEAM name=$NAME bridge_pid=$(cat "$PIDFILE") app_server=ws://127.0.0.1:$RELAY_PORT/<capability> app_server_source=desktop_relay thread=$THREAD_ID supervisor=$SUPERVISOR active=true health=ready"
      exit 0
    fi
    break
  fi
  sleep 0.2
done

stop_bridge_base "$BASE"
start_visible_turn_delivery "$THREAD_ID" "desktop_bridge_not_ready"
