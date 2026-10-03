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
  local bridge record_status cached key driver record_type record_home label
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
          if [ "$meta_pid" != "$pid" ] || [ "$meta_type" != codex ] || [ "$meta_project" != "$project" ]; then
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
      case "$cached" in
        thread_archived*) record_status='conversation archived; resume an active conversation and run actas again' ;;
        codex_home_mismatch*) record_status='incorrect CODEX_HOME record; run actas from the correct Codex profile' ;;
      esac
      label="Codex $team/$agent"
      if [ "${REDACTED:-0}" = 1 ]; then label='Codex seat (redacted)'; cached=""; fi
      case "$action:$bridge" in
        disable:running) echo "$label: already using a bridge; no restart needed" ;;
        disable:stopped) echo "$label: no bridge attached; restart Codex to restore notices ($record_status)" ;;
        disable:unknown) echo "$label: bridge state unknown; inspect delivery.sh status codex before restarting ($record_status)" ;;
        *:running) echo "$label: still using a bridge; restart Codex to move to agmsgd" ;;
        *:unknown) echo "$label: bridge state unknown ($record_status)" ;;
        *) echo "$label: $record_status${cached:+; last channel observation: $cached}" ;;
      esac
      if [ "$driver" != sqlite ]; then
        echo "$label: agmsgd beta does not support $driver storage (including JSONL). Keep using the bridge; disable agmsgd before restarting this seat."
      fi
    done <<< "$roster"
  done
}
