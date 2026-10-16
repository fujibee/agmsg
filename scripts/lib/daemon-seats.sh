#!/usr/bin/env bash
# User-facing transition inventory. Reads current registrations and bridge
# evidence rather than trusting the daemon's last poll after it has stopped.
[ -n "${_AGMSG_DAEMON_SEATS_SH:-}" ] && return 0
_AGMSG_DAEMON_SEATS_SH=1
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance-id.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/role-session.sh"

agmsg_daemon_seat_report() {
  local action="${1:-status}" cfg cfg_sql roster team agent project pid meta_type meta_project meta_pid
  local bridge record_status cached key driver record_type record_home label latest
  local seen='|' omitted=0 pending owner updated recent active display
  local active_lines='' recent_lines='' older_lines='' recovery
  source "$SKILL_DIR/scripts/lib/type-registry.sh"
  source "$SKILL_DIR/scripts/lib/boot-command.sh"
  recovery="$(agmsg_actas_prompt codex '<name>')"
  driver="$(agmsg_storage_driver)" || driver=unknown
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
          agent_match="$(printf '%s' "$agent" | sed "s/'/''/g")"
          project_match="$(printf '%s' "$meta_project" | sed "s/'/''/g")"
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
      key="$(printf '%s' "$team" | sed "s/'/''/g")"
      local agent_sql
      agent_sql="$(printf '%s' "$agent" | sed "s/'/''/g")"
      local thread_sql
      thread_sql="$(printf '%s' "${AGMSG_ROLE_SESSION_UUID:-}" | sed "s/'/''/g")"
      cached="$(sqlite3 -readonly -cmd '.timeout 100' "$SKILL_DIR/run/install.db" "SELECT reason FROM beta_codex_seat WHERE seat=json_array('$key','$agent_sql') AND thread='$thread_sql';" 2>/dev/null)" || cached=""
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
      updated="$(printf '%s' "$updated" | sed "s/'/''/g")"
      recent="$(sqlite3 :memory: "SELECT COALESCE(strftime('%s','$updated') >= strftime('%s','now','-1 day'),0);" 2>/dev/null)" || recent=0
      active=0
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
        codex_home_mismatch*) record_status='incorrect CODEX_HOME record; run actas from the correct Codex profile' ;;
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
