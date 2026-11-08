#!/usr/bin/env bash
# User-facing transition inventory. Reads current registrations and bridge
# evidence rather than trusting the daemon's last poll after it has stopped.
[ -n "${_AGMSG_DAEMON_SEATS_SH:-}" ] && return 0
_AGMSG_DAEMON_SEATS_SH=1
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance-id.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/role-session.sh"

# What the running agmsgd last observed about the Codex seats. It keeps that in
# memory only, so it is asked (one node process per report) rather than read
# from install.db. Sets AGMSG_SEATS_STATE to ok, not_polled_yet,
# daemon_not_running, liveness_unconfirmed, no_answer, helper_unavailable or
# unreadable (with AGMSG_SEATS_DETAIL holding the real error for the last
# two), and AGMSG_SEATS_ROWS to one "<seat key>\t<thread>\t<reason>" line per
# seat. daemon.sh's own Node choice is used when it is loaded (_resolve_node),
# so this agrees with the status above it; elsewhere the recorded one, then
# whatever Node can be found.
_agmsg_daemon_seats_fetch() {
  local node_path out rc=0
  AGMSG_SEATS_STATE=unreadable
  AGMSG_SEATS_DETAIL=""
  AGMSG_SEATS_ROWS=""
  if declare -F _resolve_node >/dev/null 2>&1; then
    node_path="$(_resolve_node 2>/dev/null || true)"
  else
    node_path="$(sqlite3 -readonly -cmd '.timeout 100' "$SKILL_DIR/run/install.db" 'SELECT node_path FROM meta;' 2>/dev/null)" || node_path=""
    if [ -z "$node_path" ] || [ ! -x "$node_path" ]; then
      if declare -F agmsg_resolve_node >/dev/null 2>&1; then node_path="$(agmsg_resolve_node 2>/dev/null || true)"; else node_path="$(command -v node 2>/dev/null || true)"; fi
    fi
  fi
  if [ -z "$node_path" ] || ! command -v "$node_path" >/dev/null 2>&1; then
    AGMSG_SEATS_STATE=helper_unavailable
    AGMSG_SEATS_DETAIL="no usable Node found (recorded Node missing and none on PATH)"
    return 0
  fi
  out="$("$node_path" --disable-warning=ExperimentalWarning "$SKILL_DIR/scripts/daemon/seat-query.mjs" "$SKILL_DIR" 2>&1)" || rc=$?
  case "$out" in
    state=*)
      local rest=""
      AGMSG_SEATS_STATE="${out%%$'\n'*}"; AGMSG_SEATS_STATE="${AGMSG_SEATS_STATE#state=}"
      case "$out" in *$'\n'*) rest="${out#*$'\n'}" ;; esac
      case "$AGMSG_SEATS_STATE" in
        ok|not_polled_yet|daemon_not_running|liveness_unconfirmed|no_answer) AGMSG_SEATS_ROWS="$rest" ;;
        unreadable)
          # What follows the state line is the helper's real error.
          AGMSG_SEATS_DETAIL="$(printf '%s' "${rest#detail=}" | head -c 300 | tr '\n' ' ')"
          [ -n "$AGMSG_SEATS_DETAIL" ] || AGMSG_SEATS_DETAIL="the helper gave no reason"
          ;;
        *)
          AGMSG_SEATS_DETAIL="unexpected seat state '$AGMSG_SEATS_STATE' from the helper"
          AGMSG_SEATS_STATE=unreadable
          ;;
      esac
      ;;
    *)
      AGMSG_SEATS_STATE=unreadable
      AGMSG_SEATS_DETAIL="$(printf '%s' "${out:-no output (exit $rc)}" | head -c 300 | tr '\n' ' ')"
      ;;
  esac
}

# The reason the daemon last recorded for <seat key> on <thread>, or nothing.
_agmsg_daemon_seat_reason() {
  local key="$1" thread="$2" row_seat row_thread row_reason
  while IFS=$'\t' read -r row_seat row_thread row_reason; do
    if [ "$row_seat" = "$key" ] && [ "$row_thread" = "$thread" ]; then
      printf '%s' "$row_reason"
      return 0
    fi
  done <<< "$AGMSG_SEATS_ROWS"
  return 0
}

agmsg_daemon_seat_report() {
  local action="${1:-status}" cfg cfg_sql roster team agent project pid meta_type meta_project meta_pid
  local bridge record_status cached key driver record_type record_home label latest
  local seen='|' omitted=0 pending owner updated recent active display chosen
  local active_lines='' recent_lines='' older_lines='' recovery
  source "$SKILL_DIR/scripts/lib/type-registry.sh"
  source "$SKILL_DIR/scripts/lib/boot-command.sh"
  recovery="$(agmsg_actas_prompt codex '<name>')"
  driver="$(agmsg_storage_driver)" || driver=unknown
  _agmsg_daemon_seats_fetch
  if [ "$action" = status ]; then
    case "$AGMSG_SEATS_STATE" in
      ok) : ;;
      not_polled_yet) echo 'Codex seats: agmsgd has not finished its first poll yet; seat state appears after it' ;;
      no_answer) echo 'Codex seats: agmsgd is running but did not answer in time; there is no seat state to show' ;;
      liveness_unconfirmed) echo "Codex seats: agmsgd's process could not be confirmed to be running, so its seat state was not fetched" ;;
      helper_unavailable) echo "Codex seats: the seat state of agmsgd could not be asked for: $AGMSG_SEATS_DETAIL" ;;
      unreadable) echo "Codex seats: the seat state of agmsgd could not be read: $AGMSG_SEATS_DETAIL" ;;
      *) echo 'Codex seats: agmsgd is not running; there is no seat state to show' ;;
    esac
  fi
  for cfg in "$SKILL_DIR/teams/"*/config.json; do
    [ -f "$cfg" ] || continue
    cfg_sql="$(agmsg_sql_readfile_path "$cfg")"
    roster="$(sqlite3 -separator $'\t' :memory: "
      WITH cfg(j) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT))
      SELECT DISTINCT json_extract(cfg.j,'\$.name'), a.key, json_extract(r.value,'\$.project')
      FROM cfg, json_each(cfg.j,'\$.agents') a, json_each(a.value,'\$.registrations') r
      WHERE json_extract(r.value,'\$.type')='codex';
    " 2>/dev/null)" || { echo 'Codex seats: registration inventory could not be read'; continue; }
    while IFS=$'\t' read -r team agent project; do
      [ -n "$team" ] && [ -n "$agent" ] || continue
      [ -z "${FILTER_TEAM:-}" ] || [ "$FILTER_TEAM" = "$team" ] || continue
      [ -z "${FILTER_PROJECT:-}" ] || [ "$FILTER_PROJECT" = "$project" ] || continue
      [ -z "${FILTER_TYPE:-}" ] || [ "$FILTER_TYPE" = codex ] || continue
      if ! agmsg_validate_team_name "$team" >/dev/null 2>&1 || ! agmsg_validate_agent_name "$agent" >/dev/null 2>&1; then continue; fi
      case "$seen" in *"|$team/$agent|"*) continue ;; esac
      seen="$seen$team/$agent|"
      bridge=stopped
      if [ -e "$SKILL_DIR/run/codex-bridge.$team.$agent.pid" ]; then
        pid="$(cat "$SKILL_DIR/run/codex-bridge.$team.$agent.pid" 2>/dev/null)" || pid=""
        meta_pid=""; meta_type=""; meta_project=""
        if [ -r "$SKILL_DIR/run/codex-bridge.$team.$agent.meta" ]; then
          local field value
          while IFS='=' read -r field value; do
            case "$field" in pid) meta_pid="$value" ;; type) meta_type="$value" ;; project) meta_project="$value" ;; esac
          done < "$SKILL_DIR/run/codex-bridge.$team.$agent.meta"
        fi
        case "$pid" in ''|*[!0-9]*) bridge=unknown ;; *)
          local registered_project=0 agent_match project_match
          agent_match="$(printf '%s' "$agent" | LC_ALL=C sed "s/'/''/g")"
          project_match="$(printf '%s' "$meta_project" | LC_ALL=C sed "s/'/''/g")"
          registered_project="$(sqlite3 :memory: "SELECT count(*) FROM json_each(CAST(readfile('$cfg_sql') AS TEXT),'\$.agents') a, json_each(a.value,'\$.registrations') r WHERE a.key='$agent_match' AND json_extract(r.value,'\$.type')='codex' AND json_extract(r.value,'\$.project')='$project_match';" 2>/dev/null)" || registered_project=0
          if [ "$meta_pid" != "$pid" ] || [ "$meta_type" != codex ] || [ "$registered_project" = 0 ]; then
            bridge=unknown
          elif _agmsg_pid_alive "$pid"; then
            bridge=running
          fi ;;
        esac
      fi
      agmsg_role_session_load "$team" "$agent" 2>/dev/null || true
      record_type="$(_agmsg_role_session_field "$_AGMSG_ROLE_SESSION_PATH" type)"
      record_home="$(_agmsg_role_session_field "$_AGMSG_ROLE_SESSION_PATH" codex_home)"
      record_status='destination recorded'
      if [ "$record_type" != codex ] || [ -z "${AGMSG_ROLE_SESSION_UUID:-}" ] || [ -z "$record_home" ]; then
        record_status='no destination record; restart Codex and run actas again to record it'
      fi
      key="$(printf '%s' "$team" | LC_ALL=C sed "s/'/''/g")"
      local agent_sql
      agent_sql="$(printf '%s' "$agent" | LC_ALL=C sed "s/'/''/g")"
      local thread_sql
      thread_sql="$(printf '%s' "${AGMSG_ROLE_SESSION_UUID:-}" | LC_ALL=C sed "s/'/''/g")"
      cached="$(_agmsg_daemon_seat_reason "[\"$team\",\"$agent\"]" "${AGMSG_ROLE_SESSION_UUID:-}")"
      pending="$(sqlite3 -readonly -cmd '.timeout 100' "$SKILL_DIR/run/install.db" "SELECT count(*) FROM beta_codex_queue WHERE seat=json_array('$key','$agent_sql') AND state='pending';" 2>/dev/null)" || pending=0
      # Ask for a refresh only on evidence about the current destination: the
      # newest notice attempt for this seat and thread expired unconfirmed. An
      # attempt for another conversation says nothing about the recorded one.
      latest="$(sqlite3 -readonly -cmd '.timeout 100' "$SKILL_DIR/run/install.db" "SELECT state FROM beta_codex_queue WHERE seat=json_array('$key','$agent_sql') AND thread='$thread_sql' ORDER BY id DESC LIMIT 1;" 2>/dev/null)" || latest=""
      if [ "$record_status" = 'destination recorded' ] && [ "$latest" = expired ]; then
        record_status="destination recorded; the last notice was not delivered. In Codex, run $recovery to refresh the destination"
      fi
      owner="$(_agmsg_role_session_field "$_AGMSG_ROLE_SESSION_PATH" owner)"
      updated="$(_agmsg_role_session_field "$_AGMSG_ROLE_SESSION_PATH" updated_at)"
      updated="$(printf '%s' "$updated" | LC_ALL=C sed "s/'/''/g")"
      recent="$(sqlite3 :memory: "SELECT COALESCE(strftime('%s','$updated') >= strftime('%s','now','-1 day'),0);" 2>/dev/null)" || recent=0
      active=0
      chosen=""
      if declare -F agmsg_delivery_choice_get >/dev/null 2>&1; then
        chosen="$(agmsg_delivery_choice_get codex "$project")"
        [ "$chosen" != agmsgd ] || chosen=""
        [ -z "$chosen" ] || active=1
      fi
      [ "$bridge" != running ] || active=1
      [ "$pending" = 0 ] || active=1
      # Bare historical thread IDs have no process witness. Do not scan all
      # session markers for each old role just to infer activity.
      if agmsg_instance_is_composite "$owner" && agmsg_instance_alive "$owner"; then active=1; fi
      # A registration alone is not a historical destination. Keep actionable
      # bridge/pending evidence visible, but omit seats never recorded at all.
      if [ "$action" = status ] && [ "$active" = 0 ] && [ "$bridge" = stopped ] \
        && [ ! -f "$_AGMSG_ROLE_SESSION_PATH" ]; then
        continue
      fi
      if [ "$action" = status ] && [ "${AGMSG_DAEMON_ALL:-0}" != 1 ] && [ "$active" = 0 ] && [ "$recent" != 1 ]; then
        omitted=$((omitted + 1))
        continue
      fi
      case "$cached" in
        thread_archived*) record_status='conversation archived; resume an active conversation and run actas again' ;;
        codex_home_mismatch*) record_status='the recorded Codex profile has no rollout for this conversation; run actas again from the Codex session you are using' ;;
      esac
      label="Codex $team/$agent"
      if [ "${REDACTED:-0}" = 1 ]; then label='Codex seat (redacted)'; cached=""; fi
      case "$cached" in
        awaiting_confirmation|*pending:*|child_*|queue_child_*) record_status='waiting for delivery confirmation; unread messages are preserved' ;;
        codex_executable_unavailable*) record_status='Codex executable unavailable; run agmsg daemon enable with Codex on PATH' ;;
        spawn_failed:*) record_status="notice could not start ($cached); delivery will retry" ;;
        queue_failed:*|queue_timeout:*|queue_cancelled:*) record_status="notice attempt needs confirmation ($cached); unread messages are preserved" ;;
        thread_observation_failed) record_status='conversation could not be verified; resume it and run actas again' ;;
        bridge_state_unknown*) : ;; # Current bridge evidence is authoritative for this display.
        '') : ;;
        *) record_status="$record_status; $cached" ;;
      esac
      if [ "$pending" != 0 ]; then
        case "$record_status" in
          *confirmation*) : ;;
          *) record_status="$record_status; waiting for delivery confirmation" ;;
        esac
      fi
      case "$action:$bridge" in
        disable:running) display='already using a bridge; no restart needed' ;;
        disable:stopped) display="no bridge attached; restart Codex to restore notices ($record_status)" ;;
        disable:unknown) display="bridge could not be verified; inspect delivery.sh status codex before restarting ($record_status)" ;;
        *:running) display='bridge process running; reopen Codex to switch to agmsgd' ;;
        *:unknown) display="bridge could not be verified; inspect delivery.sh status codex ($record_status)" ;;
        *) display="$record_status" ;;
      esac
      if [ -n "$chosen" ]; then
        [ "$chosen" != monitor ] || chosen='monitor (legacy)'
        display="$chosen chosen; agmsgd does not deliver here"
      fi
      if [ "$driver" != sqlite ]; then
        local storage_label="$driver"
        [ "$driver" != jsonl ] || storage_label=JSONL
        display="$display; $storage_label storage needs the bridge. Disable agmsgd before reopening this seat"
      fi
      if [ "$action" != status ]; then
        echo "$label: $display"
      elif [ "$active" = 1 ]; then
        printf -v active_lines '%s%s: %s\n' "$active_lines" "$label" "$display"
      elif [ "$recent" = 1 ]; then
        printf -v recent_lines '%s%s: %s\n' "$recent_lines" "$label" "$display"
      else
        printf -v older_lines '%s%s: %s\n' "$older_lines" "$label" "$display"
      fi
    done <<< "$roster"
  done
  printf '%s' "$active_lines"
  if [ -n "$recent_lines" ]; then
    echo 'Recently recorded destinations (last 24 hours; activity not verified):'
    printf '%s' "$recent_lines"
  fi
  if [ -n "$older_lines" ]; then
    echo 'Older destination records (activity not verified):'
    printf '%s' "$older_lines"
  fi
  if [ "$omitted" -gt 0 ]; then
    echo "Codex seats: $omitted older destination records hidden. View them with: agmsg daemon status --all"
  fi
}
