#!/usr/bin/env bash
# team-delete.sh — destructive team-removal helpers for team.sh's --delete
# and --purge-messages (#1475).
#
# Requires: SKILL_DIR set; storage.sh, sqlpath.sh, roster-journal.sh,
# actas-lock.sh and role-session.sh already sourced by the caller.

[ -n "${_AGMSG_TEAM_DELETE_SH:-}" ] && return 0
_AGMSG_TEAM_DELETE_SH=1

: "${SKILL_DIR:?team-delete.sh requires SKILL_DIR}"

# Every team-scoped SQL table rename-team.sh knows how to move, and the
# column each keys its rows on. --purge-messages reuses this exact list
# (DELETE instead of UPDATE) so the two operations can never disagree about
# what "this team's rows" means.
_AGMSG_TEAM_SCOPED_TABLES="events read_cursors sync_bindings sync_messages sync_quarantine sync_conflicts sync_read_members sync_read_remote_exact sync_read_aliases sync_read_prepared"

# Every agent name ever seen in this team: the current config cache plus,
# when the team is journaled, every member_joined/member_renamed name in its
# history. Best-effort input for the run/ sweep below -- a name that never
# actually backed a per-agent file costs nothing to look up and not find.
_agmsg_team_delete_all_names() {
  local team_dir="$1" config="$2" names="" journal jsql journal_names
  if [ -f "$config" ]; then
    names="$(sqlite3 :memory: \
      "SELECT key FROM json_each(json_extract(CAST(readfile('$(agmsg_sql_readfile_path "$config")') AS TEXT), '\$.agents'));" \
      2>/dev/null | tr -d '\r')"
  fi
  journal="$(agmsg_roster_journal_path "$team_dir")"
  if [ -f "$journal" ]; then
    jsql="$(agmsg_sql_readfile_path "$journal")"
    journal_names="$(sqlite3 :memory: "
      WITH source(doc) AS (
        SELECT CASE
          WHEN length(rtrim(CAST(readfile('$jsql') AS TEXT), char(10))) = 0
            THEN '[]'
          ELSE '[' || replace(
            rtrim(CAST(readfile('$jsql') AS TEXT), char(10)),
            char(10), ',') || ']'
        END
      ),
      events(event) AS (SELECT value FROM source, json_each(source.doc))
      SELECT DISTINCT n FROM (
        SELECT json_extract(event,'\$.name') AS n FROM events
         WHERE json_extract(event,'\$.type')='member_joined'
        UNION
        SELECT json_extract(event,'\$.from') AS n FROM events
         WHERE json_extract(event,'\$.type')='member_renamed'
        UNION
        SELECT json_extract(event,'\$.to') AS n FROM events
         WHERE json_extract(event,'\$.type')='member_renamed'
      ) WHERE n IS NOT NULL;" 2>/dev/null | tr -d '\r')"
    names="$(printf '%s\n%s\n' "$names" "$journal_names" | sed '/^$/d' | LC_ALL=C sort -u)"
  fi
  printf '%s\n' "$names"
}

# True IFF <encoded_team>__<encoded_name> has exactly one possible split back
# into (team, name) -- i.e. neither half itself contains "__". actas-lock.sh's
# own #1023 comment gives the failing case: team "a__b" agent "c" and team "a"
# agent "b__c" both encode to the same legacy path, since "__" is a plain,
# unescaped separator and either name may legally contain it. Only when this
# returns true is the legacy path provably this (team, name) pair's alone; a
# name that fails this check is left untouched rather than guessed at, the
# same "check, don't guess" rule actas-lock.sh already applies to the lock's
# own three-valued read.
_agmsg_team_delete_legacy_unambiguous() {   # <encoded_team> <encoded_name>
  case "$1" in *__*) return 1 ;; esac
  case "$2" in *__*) return 1 ;; esac
  return 0
}

# Removes the id-keyed file when id-resolution succeeds (its key is
# <team_id>__<member_id>, both fixed-alphabet UUIDs that can never contain
# "__" themselves, so it never suffers the collision above) and, only when
# _agmsg_team_delete_legacy_unambiguous allows it, the legacy name-keyed file
# too (#1023 dual-keying) for one (team, name, prefix, suffix) state-file
# family. rm_reclaim also removes the reclaim mutex and any of its tombstones
# beside whichever path(s) were actually removed -- see actas-lock.sh's
# _agmsg_lock_mutex_path / _agmsg_lock_mutex_take.
_agmsg_team_delete_rm_family() {   # <team> <name> <prefix> <suffix> [rm_reclaim]
  local team="$1" name="$2" prefix="$3" suffix="$4" rm_reclaim="${5:-0}"
  local t a legacy key krc=0 idpath
  t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$name")"
  if _agmsg_team_delete_legacy_unambiguous "$t" "$a"; then
    legacy="$(printf '%s/%s.%s__%s%s' "$(_actas_lock_dir)" "$prefix" "$t" "$a" "$suffix")"
    rm -f "$legacy" 2>/dev/null || true
    [ "$rm_reclaim" = 1 ] && rm -f "$legacy.reclaim" "$legacy.reclaim".dead.* 2>/dev/null || true
  fi
  key="$(_agmsg_id_key_or_legacy "$team" "$name" 2>/dev/null)" && krc=0 || krc=$?
  if [ "$krc" -eq 0 ] && [ -n "$key" ]; then
    idpath="$(printf '%s/%s.%s%s' "$(_actas_lock_dir)" "$prefix" "$key" "$suffix")"
    rm -f "$idpath" 2>/dev/null || true
    [ "$rm_reclaim" = 1 ] && rm -f "$idpath.reclaim" "$idpath.reclaim".dead.* 2>/dev/null || true
  fi
}

# Best-effort sweep of run/'s per-(team,agent) state: actas locks (plus
# their reclaim mutex/tombstones), readiness sentinels, spawn/placement
# records, role-session records, and single-pair codex bridge files.
# Matched by the exact encoded team+name every writer already uses (never a
# substring/glob against the team name alone), so a team whose name is a
# prefix of another team's cannot lose the other team's state.
#
# Known gap, deliberately out of scope: a watcher's own pidfile
# (run/watch.<session_id>.pid) is keyed by session id, not by team/agent, so
# it is not addressable here -- and killing a LIVE watcher's pidfile out
# from under it is exactly the class of danger #1470 ruled unsafe. A stale
# watcher for a deleted team finds nothing on its next poll and is harmless.
agmsg_team_delete_run_records() {
  local team="$1" team_dir="$2" config="$3" name t a
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    _agmsg_team_delete_rm_family "$team" "$name" actas .session 1
    _agmsg_team_delete_rm_family "$team" "$name" ready "" 0
    _agmsg_team_delete_rm_family "$team" "$name" spawn "" 0
    t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$name")"
    # role-session.sh has no id-keyed form at all (see its own header) -- the
    # unambiguous check is this record's ONLY protection against the #1023
    # collision, not a belt-and-suspenders on top of an id fallback.
    if _agmsg_team_delete_legacy_unambiguous "$t" "$a"; then
      rm -f "$(printf '%s/role-session.%s__%s' "$(_actas_lock_dir)" "$t" "$a")" 2>/dev/null || true
    fi
    # Single-pair codex bridge key (see drivers/types/codex/_bridge-key.sh);
    # the rarer multi-pair hashed-key form needs the set of still-registered
    # codex pairs to re-derive and is not attempted here.
    rm -f "$(_actas_lock_dir)/codex-bridge.$team.$name."* 2>/dev/null || true
  done <<EOF
$(_agmsg_team_delete_all_names "$team_dir" "$config")
EOF
}

# Deletes every row this team owns from the legacy messages table and every
# team-scoped SQL table (see _AGMSG_TEAM_SCOPED_TABLES), leaving the team
# itself and every other team's rows untouched. Caller decides whether the
# team's config/run records are also removed (--delete is independent of
# --purge-messages).
agmsg_team_purge_messages() {
  local team="$1" db lit purge_sql table column
  db="$(agmsg_db_path "$team")" || return 1
  [ -f "$db" ] || return 0
  lit="$(agmsg_sqlesc "$team")"
  purge_sql=""
  for table in $_AGMSG_TEAM_SCOPED_TABLES; do
    if [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';" | tr -d '\r')" = 1 ]; then
      case "$table" in
        events|read_cursors) column=team ;;
        *) column=local_team ;;
      esac
      purge_sql="$purge_sql DELETE FROM $table WHERE $column='$lit';"
    fi
  done
  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    DELETE FROM messages WHERE team='$lit';
    $purge_sql
    COMMIT;"
}
