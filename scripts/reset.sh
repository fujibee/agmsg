#!/usr/bin/env bash
set -euo pipefail

# Usage: reset.sh <project_path> <type> [agent_id] [session_id] [--exact-owner]
#
# Removes registrations for the given project/type across all teams.
# If agent_id is omitted, it is resolved from whoami.sh for the current project/type.
# If session_id is given, any actas exclusivity locks owned by that session_id
# for the touched (team, agent_id) pairs are released too — this is how `drop`
# returns the role to the pool so peer sessions can pick it up immediately
# without waiting for stale-lock GC.

PROJECT_PATH="${1:?Usage: reset.sh <project_path> <type> [agent_id] [session_id]}"
AGENT_TYPE="${2:?Usage: reset.sh <project_path> <type> [agent_id] [session_id]}"
TARGET_AGENT="${3:-}"
SESSION_ID="${4:-}"
EXACT_OWNER=0
case "${5:-}" in
  '') ;;
  --exact-owner) EXACT_OWNER=1 ;;
  *)
    echo "Usage: reset.sh <project_path> <type> [agent_id] [session_id] [--exact-owner]" >&2
    exit 1
    ;;
esac
[ "$#" -le 5 ] || {
  echo "Usage: reset.sh <project_path> <type> [agent_id] [session_id] [--exact-owner]" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SKILL_DIR/teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# Agent names that would misroute the $.agents.<name> JSON path below (#87
# cluster — '.', '/', '\', '"', '[', ']' all have path meaning to json1).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# Escape as a SQL string literal (parity with join.sh/rename.sh/leave.sh):
# concatenated into JSON paths below as `'$.agents.' || '<escaped>'` rather
# than spliced into the path text, so a single quote can't break the
# statement (#87 cluster).
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

# Resolve the session's real project root (see #92) so a drop issued from a
# subdir/worktree clears the registration on the project the session lives in.
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"
# Equivalent path spellings (#268) — a drop must remove a registration stored
# in any Windows/MSYS form, not just the exact resolved string.
PROJECT_SQL_IN=$(agmsg_project_sql_in_list "$PROJECT_PATH")

# A normal drop releases the actas lock keyed under this session's per-process
# instance id (#93). The template passes a bare $CLAUDE_CODE_SESSION_ID;
# normalize to the same composite the watcher/claim used so the release matches
# the real owner token. `--exact-owner` is internal force-despawn plumbing: it
# passes a record read from the lock itself, which must not be re-derived (a
# stored bare owner could otherwise be upgraded to a different composite).
RELEASE_REQUESTED=0
if [ -n "$SESSION_ID" ] || [ "$EXACT_OWNER" -eq 1 ]; then
  RELEASE_REQUESTED=1
fi
if [ "$RELEASE_REQUESTED" -eq 1 ] && [ "$EXACT_OWNER" -ne 1 ]; then
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$AGENT_TYPE")"
fi

if [ -z "$TARGET_AGENT" ]; then
  WHOAMI=$(bash "$SCRIPT_DIR/whoami.sh" "$PROJECT_PATH" "$AGENT_TYPE")
  if echo "$WHOAMI" | grep -q '^agent='; then
    TARGET_AGENT=$(echo "$WHOAMI" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')
  elif echo "$WHOAMI" | grep -q '^multiple=true'; then
    echo "Multiple identities match this project/type. Pass an agent_id explicitly." >&2
    exit 1
  else
    echo "No registered identity found for this project/type." >&2
    exit 1
  fi
fi

agmsg_validate_agent_name "$TARGET_AGENT" || exit 1
TARGET_AGENT_SQL=$(_agmsg_sqlesc "$TARGET_AGENT")
AGENT_TYPE_SQL=$(_agmsg_sqlesc "$AGENT_TYPE")

if [ ! -d "$TEAMS_DIR" ]; then
  echo "No team registrations found."
  exit 0
fi

REMOVED=0
TOUCHED_TEAMS=0
LOCK_FAILED=0
RELEASE_FAILED=0
FINALIZE_FAILED=0
RETAINED_LOCKS=""

for TEAM_CONFIG in "$TEAMS_DIR"/*/config.json; do
  [ -f "$TEAM_CONFIG" ] || continue
  TEAM_DIR="$(dirname "$TEAM_CONFIG")"
  TEAM_NAME="$(basename "$TEAM_DIR")"

  # Serialize this team's read-modify-write so a concurrent join/leave/rename on
  # the same team can't be clobbered (#141). Per team, released before moving on.
  # A lock timeout is NOT silently skipped: flag it and fail at the end, so a
  # `drop`/reset never reports success while leaving a team unprocessed.
  if ! agmsg_lock_acquire "$TEAM_DIR"; then
    echo "Warning: could not lock $TEAM_NAME, skipped" >&2
    LOCK_FAILED=1
    continue
  fi
  # Keep the original complete config while the per-team registry lock is
  # held.  When a session-scoped reset cannot prove that its actas lock was
  # released, this is atomically restored below so the registration and lock
  # remain retryable as one local outcome.  Do not delete a last config before
  # the checked release: that used to turn an infrastructure failure into a
  # successful-looking, irrecoverable drop.
  ORIGINAL_CONFIG=$(<"$TEAM_CONFIG")
  CONFIG_ESCAPED=$(printf '%s' "$ORIGINAL_CONFIG" | sed "s/'/''/g")

  # CONFIG_ESCAPED is spliced as a genuine SQL string literal below, NOT
  # bound via `.param set`: the sqlite3 shell's dot-command tokenizer does
  # not honour SQL '' escaping (unlike a real SQL statement's string
  # literals), so `.param set :json '...'` silently mis-parses as soon as
  # the config contains any single quote — e.g. an existing agent name like
  # "al'ice" — corrupting :json for every query below it (#87 cluster; see
  # resolve-project.sh's `resolve_team` for the same caveat).
  AGENT_JSON=$(agmsg_sqlite_mem \
    "SELECT json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$TARGET_AGENT_SQL');")
  if [ -z "$AGENT_JSON" ] || [ "$AGENT_JSON" = "null" ]; then
    agmsg_lock_release
    continue
  fi

  AGENT_ESCAPED=$(printf '%s' "$AGENT_JSON" | sed "s/'/''/g")
  NORMALIZED=$(agmsg_sqlite_mem "
    WITH agent(a) AS (SELECT '$AGENT_ESCAPED')
    SELECT CASE
      WHEN json_type(json_extract(a, '\$.registrations')) = 'array' THEN a
      ELSE json_object(
        'registrations',
        json_array(json_object(
          'type', json_extract(a, '\$.type'),
          'project', json_extract(a, '\$.project')
        ))
      )
    END
    FROM agent;
  ")
  NORMALIZED_ESCAPED=$(printf '%s' "$NORMALIZED" | sed "s/'/''/g")

  MATCH_COUNT=$(agmsg_sqlite_mem "
    SELECT count(*)
    FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
    WHERE json_extract(value, '\$.type') = '$AGENT_TYPE_SQL'
      AND json_extract(value, '\$.project') IN ($PROJECT_SQL_IN);
  ")
  if [ "$MATCH_COUNT" -eq 0 ]; then
    agmsg_lock_release
    continue
  fi

  FILTERED=$(agmsg_sqlite_mem "
    SELECT json_object(
      'registrations',
      COALESCE((
        SELECT json_group_array(json(value))
        FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
        WHERE NOT (
          json_extract(value, '\$.type') = '$AGENT_TYPE_SQL'
          AND json_extract(value, '\$.project') IN ($PROJECT_SQL_IN)
        )
      ), json('[]'))
    );
  ")
  FILTERED_ESCAPED=$(printf '%s' "$FILTERED" | sed "s/'/''/g")
  REMAINING=$(agmsg_sqlite_mem "
    SELECT json_array_length(json_extract('$FILTERED_ESCAPED', '\$.registrations'));
  ")

  if [ "$REMAINING" -eq 0 ]; then
    UPDATED=$(agmsg_sqlite_mem \
      "SELECT json_remove('$CONFIG_ESCAPED', '\$.agents.' || '$TARGET_AGENT_SQL');")
  else
    UPDATED=$(agmsg_sqlite_mem \
      "SELECT json_set('$CONFIG_ESCAPED', '\$.agents.' || '$TARGET_AGENT_SQL', json('$FILTERED_ESCAPED'));")
  fi

  AGENT_COUNT=$(agmsg_sqlite_mem "
    SELECT count(*)
    FROM json_each(json_extract('$(printf '%s' "$UPDATED" | sed "s/'/''/g")', '\$.agents'));
  ")

  # Write the prospective registration set first while holding the team
  # registry lock.  A release-first ordering creates a peer-claim window in
  # which a failed reset would restore registration after another session had
  # already claimed the role.  `agmsg_write_atomic` keeps unlocked readers from
  # seeing a partial config; a failed checked release restores ORIGINAL_CONFIG
  # before this registry lock is released.
  if ! agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"; then
    echo "Warning: could not update $TEAM_NAME, skipped" >&2
    LOCK_FAILED=1
    agmsg_lock_release
    continue
  fi

  if [ "$RELEASE_REQUESTED" -eq 1 ] \
    && ! actas_lock_release_checked "$TEAM_NAME" "$TARGET_AGENT" "$SESSION_ID"; then
    local_label="$(_actas_lock_encode "$TEAM_NAME")/$(_actas_lock_encode "$TARGET_AGENT")"
    RETAINED_LOCKS="${RETAINED_LOCKS:+$RETAINED_LOCKS,}$local_label"
    RELEASE_FAILED=1
    # This write is deliberately checked too.  If the filesystem cannot
    # restore the old config, never claim success: the retained lock is still
    # reported explicitly for operator recovery.
    if ! agmsg_write_atomic "$TEAM_CONFIG" "$ORIGINAL_CONFIG"; then
      echo "Warning: could not restore $TEAM_NAME after retained actas lock" >&2
      FINALIZE_FAILED=1
    fi
    agmsg_lock_release
    continue
  fi

  # Only finalize an empty team after checked release succeeded.  The config
  # stayed in place through the release above so a failure could restore the
  # original registration atomically.  Keep the registry lock through removal
  # too: releasing it first would let a concurrent join recreate config.json
  # just before this reset unlinked it.
  if [ "$AGENT_COUNT" -eq 0 ]; then
    if ! rm -f "$TEAM_CONFIG"; then
      echo "Warning: could not finalize empty team $TEAM_NAME" >&2
      FINALIZE_FAILED=1
      agmsg_lock_release
      continue
    fi
    agmsg_lock_release
    rmdir "$TEAM_DIR" 2>/dev/null || true
  else
    agmsg_lock_release
  fi

  REMOVED=$((REMOVED + MATCH_COUNT))
  TOUCHED_TEAMS=$((TOUCHED_TEAMS + 1))
  echo "Cleared $MATCH_COUNT registration(s) for $TARGET_AGENT from $TEAM_NAME"
done

if [ "$LOCK_FAILED" -ne 0 ] || [ "$RELEASE_FAILED" -ne 0 ] || [ "$FINALIZE_FAILED" -ne 0 ]; then
  # A team we could not lock or whose checked lock release failed was left
  # unprocessed.  Surface partial progress, but never call it complete.  Exact
  # percent-encoded labels make the retained retry target unambiguous.
  if [ "$REMOVED" -gt 0 ]; then
    echo "Reset incomplete: removed $REMOVED registration(s) across $TOUCHED_TEAMS team(s)" >&2
  fi
  if [ "$LOCK_FAILED" -ne 0 ]; then
    echo "Reset incomplete: one or more teams could not be locked." >&2
  fi
  if [ -n "$RETAINED_LOCKS" ]; then
    echo "Reset incomplete: retained=$RETAINED_LOCKS" >&2
  fi
  exit 1
fi

if [ "$REMOVED" -eq 0 ]; then
  echo "No registrations removed."
else
  echo "Reset complete: removed $REMOVED registration(s) across $TOUCHED_TEAMS team(s)"
fi
