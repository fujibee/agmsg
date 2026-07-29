#!/usr/bin/env bash
# Persistent delivery cursor for one registered (team, agent, type, project).

[ -n "${_AGMSG_DELIVERY_CURSOR_SH:-}" ] && return 0
_AGMSG_DELIVERY_CURSOR_SH=1

: "${SKILL_DIR:?delivery-cursor.sh requires SKILL_DIR}"

# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/resolve-project.sh"

_agmsg_delivery_cursor_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

_AGMSG_DELIVERY_CURSOR_SCHEMA_READY=""
agmsg_delivery_cursor_ensure_schema() {
  [ "$_AGMSG_DELIVERY_CURSOR_SCHEMA_READY" = "1" ] && return 0
  agmsg_storage_ensure_initialized || return 1
  agmsg_sqlite "$(agmsg_db_path)" <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS delivery_cursors (
  team TEXT NOT NULL,
  agent TEXT NOT NULL,
  type TEXT NOT NULL,
  project TEXT NOT NULL,
  last_id INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (team, agent, type, project)
);
SQL
  _AGMSG_DELIVERY_CURSOR_SCHEMA_READY=1
}

agmsg_delivery_cursor_get() {
  local team="$1" agent="$2" type="$3" project="$4"
  local db team_sql agent_sql type_sql project_sql_in
  agmsg_delivery_cursor_ensure_schema || return 1
  db="$(agmsg_db_path)"
  team_sql="$(_agmsg_delivery_cursor_escape "$team")"
  agent_sql="$(_agmsg_delivery_cursor_escape "$agent")"
  type_sql="$(_agmsg_delivery_cursor_escape "$type")"
  project_sql_in="$(agmsg_project_sql_in_list "$project")"
  agmsg_sqlite "$db" "
    SELECT MAX(last_id)
    FROM delivery_cursors
    WHERE team='$team_sql' AND agent='$agent_sql' AND type='$type_sql'
      AND project IN ($project_sql_in);
  " 2>/dev/null
}

# Start a newly visible registration immediately after the current message id.
# join.sh calls this before publishing the registration in config.json.
agmsg_delivery_cursor_seed() {
  local team="$1" agent="$2" type="$3" project="$4"
  local db team_sql agent_sql type_sql project_norm project_sql last_id
  agmsg_delivery_cursor_ensure_schema || return 1
  db="$(agmsg_db_path)"
  team_sql="$(_agmsg_delivery_cursor_escape "$team")"
  agent_sql="$(_agmsg_delivery_cursor_escape "$agent")"
  type_sql="$(_agmsg_delivery_cursor_escape "$type")"
  project_norm="$(agmsg_normalize_project_path "$project")"
  project_sql="$(_agmsg_delivery_cursor_escape "$project_norm")"
  last_id="$(agmsg_sqlite "$db" "SELECT COALESCE(MAX(id), 0) FROM messages;" 2>/dev/null || printf '0')"
  case "$last_id" in ''|*[!0-9]*) last_id=0 ;; esac
  agmsg_sqlite "$db" "
    INSERT OR REPLACE INTO delivery_cursors(team, agent, type, project, last_id, updated_at)
    VALUES('$team_sql', '$agent_sql', '$type_sql', '$project_sql', $last_id,
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));
  " >/dev/null
  printf '%s' "$last_id"
}

# Existing installations have registrations without cursor rows. Seed those at
# first observation so old live output is not replayed after an upgrade.
agmsg_delivery_cursor_initialize_missing() {
  local team="$1" agent="$2" type="$3" project="$4" current
  current="$(agmsg_delivery_cursor_get "$team" "$agent" "$type" "$project" 2>/dev/null || true)"
  case "$current" in
    ''|*[!0-9]*) agmsg_delivery_cursor_seed "$team" "$agent" "$type" "$project" ;;
    *) printf '%s' "$current" ;;
  esac
}

agmsg_delivery_cursor_advance() {
  local team="$1" agent="$2" type="$3" project="$4" message_id="$5"
  local db team_sql agent_sql type_sql project_norm project_sql
  case "$message_id" in ''|*[!0-9]*) return 0 ;; esac
  agmsg_delivery_cursor_ensure_schema || return 1
  db="$(agmsg_db_path)"
  team_sql="$(_agmsg_delivery_cursor_escape "$team")"
  agent_sql="$(_agmsg_delivery_cursor_escape "$agent")"
  type_sql="$(_agmsg_delivery_cursor_escape "$type")"
  project_norm="$(agmsg_normalize_project_path "$project")"
  project_sql="$(_agmsg_delivery_cursor_escape "$project_norm")"
  agmsg_sqlite "$db" "
    INSERT OR IGNORE INTO delivery_cursors(team, agent, type, project, last_id, updated_at)
    VALUES('$team_sql', '$agent_sql', '$type_sql', '$project_sql', $message_id,
           strftime('%Y-%m-%dT%H:%M:%SZ','now'));
    UPDATE delivery_cursors
    SET last_id=CASE WHEN last_id < $message_id THEN $message_id ELSE last_id END,
        updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE team='$team_sql' AND agent='$agent_sql' AND type='$type_sql'
      AND project='$project_sql';
  " >/dev/null
}
