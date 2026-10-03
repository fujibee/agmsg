#!/usr/bin/env bash
set -euo pipefail

# Usage: rename-team.sh <old_team> <new_team>
#
# Renames a team:
#   1. moves teams/<old>/ to teams/<new>/
#   2. updates "name" field in the moved config.json
#   3. moves the team's store to <storage>/teams/<new>/
#   4. updates the moved store: UPDATE messages SET team=<new> WHERE team=<old>

OLD_TEAM="${1:?Usage: rename-team.sh <old_team> <new_team>}"
NEW_TEAM="${2:?Missing new team name}"

if [ "$OLD_TEAM" = "$NEW_TEAM" ]; then
  echo "Old and new team names are the same: $OLD_TEAM"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# Reject team names that would escape teams/ as a path segment, on either side
# of the rename (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# Whether this team owns a store decides whether there is a directory to move.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/driver-registry.sh"
agmsg_validate_team_name "$OLD_TEAM" || exit 1
agmsg_validate_team_name "$NEW_TEAM" || exit 1
TEAMS_DIR="$SCRIPT_DIR/../teams"
OLD_DIR="$TEAMS_DIR/$OLD_TEAM"
NEW_DIR="$TEAMS_DIR/$NEW_TEAM"
# The SQLite path uses persistent admission in both the selected store and
# the shared fallback used while a config name is absent.
_rename_team_sql() {
  local db="$1" table column sql old_lit new_lit
  old_lit=$(agmsg_sqlesc "$OLD_TEAM"); new_lit=$(agmsg_sqlesc "$NEW_TEAM")
  sql="UPDATE messages SET team='$new_lit' WHERE team='$old_lit';"
  for table in events read_cursors sync_bindings sync_messages sync_quarantine \
    sync_conflicts sync_read_members sync_read_remote_exact sync_read_aliases sync_read_prepared; do
    if [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';" | tr -d '\r')" = 1 ]; then
      case "$table" in events|read_cursors) column=team ;; *) column=local_team ;; esac
      sql="$sql UPDATE $table SET $column='$new_lit' WHERE $column='$old_lit';"
    fi
  done
  printf '%s\n' "$sql"
}

_rename_team_sqlite() {
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/delivery-maintenance.sh"
  agmsg_dm_load || return 1
  local shared old_db new_db source_db selected descriptor found partition token shared_token
  local config_before config_after journal_hash roster_sync_hash sync_before sync_after sync_plan updated
  local file hash src dst now sql guard shared_guard record target_db fresh=false
  shared="$(_agmsg_runtime_db_path)"
  old_db="$(agmsg_storage_dir)/teams/$OLD_TEAM/messages.db"
  new_db="$(agmsg_storage_dir)/teams/$NEW_TEAM/messages.db"
  agmsg_dm_find "$OLD_TEAM" rename-team "$NEW_TEAM" "$shared" "$old_db" "$new_db" || return 1
  if [ "${AGMSG_DM_FOUND:?maintenance result missing}" = false ]; then
    [ -f "$OLD_DIR/config.json" ] || { echo "Team not found: $OLD_TEAM"; return 1; }
    [ ! -f "$NEW_DIR/config.json" ] || { echo "Team already exists: $NEW_TEAM"; return 1; }
  fi
  mkdir -p "$OLD_DIR" "$NEW_DIR"
  LOCK_A=$(printf '%s\n%s\n' "$OLD_DIR" "$NEW_DIR" | LC_ALL=C sort | sed -n 1p)
  LOCK_B=$(printf '%s\n%s\n' "$OLD_DIR" "$NEW_DIR" | LC_ALL=C sort | sed -n 2p)
  agmsg_lock_acquire "$LOCK_A" manual-recovery || return 1
  agmsg_lock_acquire "$LOCK_B" manual-recovery || return 1
  agmsg_dm_find "$OLD_TEAM" rename-team "$NEW_TEAM" "$shared" "$old_db" "$new_db" || return 1
  if [ "${AGMSG_DM_FOUND:?maintenance result missing}" = false ]; then
    [ -f "$OLD_DIR/config.json" ] && [ ! -e "$NEW_DIR/config.json" ] || {
      agmsg_dm_error 'team registry changed before admission'; return 1;
    }
    partition=$(agmsg_driver_for_team partition "$OLD_TEAM" shared)
    source_db="$shared"; target_db="$shared"
    if [ "$partition" = per-team ]; then
      source_db="$old_db"; target_db="$new_db"
      [ ! -e "${new_db%/*}" ] && [ ! -L "${new_db%/*}" ] || {
        echo "A store already exists for $NEW_TEAM" >&2; return 1;
      }
    fi
    config_before=$(agmsg_dm_hash "$OLD_DIR/config.json")
    updated=$(agmsg_sqlite_mem "SELECT json_set(CAST(readfile('$(agmsg_sql_readfile_path "$OLD_DIR/config.json")') AS TEXT), '\$.name', '$(agmsg_sqlesc "$NEW_TEAM")');")
    config_after=$(printf '%s\n' "$updated" | agmsg_sha256)
    journal_hash=$(agmsg_dm_hash "$OLD_DIR/roster.jsonl")
    roster_sync_hash=$(agmsg_dm_hash "$OLD_DIR/roster-sync.json")
    sync_before=absent; sync_after=absent
    if [ -d "$(agmsg_storage_dir)/remote-sync" ]; then
      . "$SCRIPT_DIR/lib/node.sh"
      NODE_BIN=$(agmsg_resolve_node)
      sync_plan=$("$NODE_BIN" "$SCRIPT_DIR/internal/rename-sync-config.mjs" "$(agmsg_storage_dir)" "$OLD_TEAM" "$NEW_TEAM" --plan)
      sync_before=$(agmsg_dm_field "$sync_plan" source)
      sync_after=$(agmsg_dm_field "$sync_plan" target)
    fi
    descriptor=$(agmsg_sqlite_mem "SELECT json_object(
      'version',1,'nonce',lower(hex(randomblob(32))),'operation','rename-team',
      'team','$(agmsg_sqlesc "$OLD_TEAM")','argument','$(agmsg_sqlesc "$NEW_TEAM")',
      'source','$(agmsg_sqlesc "$source_db")','target','$(agmsg_sqlesc "$target_db")',
      'fallback','$(agmsg_sqlesc "$shared")','partition','$(agmsg_sqlesc "$partition")',
      'config_before','$config_before','config_after','$config_after',
      'journal','$journal_hash','roster_sync','$roster_sync_hash',
      'sync_before','$sync_before','sync_after','$sync_after');")
    agmsg_dm_begin "$shared" "$descriptor" "$OLD_TEAM" "$NEW_TEAM" || return 1
    shared_token="${AGMSG_DM_TOKEN:?maintenance result missing}"
    if [ "$source_db" != "$shared" ]; then
      if ! agmsg_dm_begin "$source_db" "$descriptor" "$OLD_TEAM" "$NEW_TEAM"; then
        _sqlite_delivery_maintenance_finish_db "$shared" "$descriptor" "$shared_token" "$OLD_TEAM" "$NEW_TEAM" >/dev/null || return 1
        return 1
      fi
    fi
    fresh=true
  else
    descriptor="${AGMSG_DM_DESCRIPTOR:?maintenance result missing}"
    source_db=$(agmsg_dm_field "$descriptor" source)
    target_db=$(agmsg_dm_field "$descriptor" target)
    partition=$(agmsg_dm_field "$descriptor" partition)
    [ "$(agmsg_dm_field "$descriptor" fallback)" = "$shared" ] || return 1
    if [ "$partition" = per-team ]; then
      [ "$source_db" = "$old_db" ] && [ "$target_db" = "$new_db" ] || return 1
    else
      [ "$partition" = shared ] && [ "$source_db" = "$shared" ] && [ "$target_db" = "$shared" ] || return 1
    fi
  fi
  config_before=$(agmsg_dm_field "$descriptor" config_before)
  config_after=$(agmsg_dm_field "$descriptor" config_after)
  journal_hash=$(agmsg_dm_field "$descriptor" journal)
  roster_sync_hash=$(agmsg_dm_field "$descriptor" roster_sync)
  # Each file has one recorded origin and one allowed destination. Never adopt
  # a recreated config or an unrelated target file on the strength of a name.
  if [ -e "$OLD_DIR/config.json" ]; then
    [ ! -e "$NEW_DIR/config.json" ] && [ ! -L "$NEW_DIR/config.json" ] || return 1
    agmsg_dm_expect "$OLD_DIR/config.json" "$config_before" || return 1
  else
    now=$(agmsg_dm_hash "$NEW_DIR/config.json")
    [ "$now" = "$config_before" ] || [ "$now" = "$config_after" ] || return 1
  fi
  for file in roster.jsonl roster-sync.json; do
    case "$file" in roster.jsonl) hash="$journal_hash" ;; *) hash="$roster_sync_hash" ;; esac
    src="$OLD_DIR/$file"; dst="$NEW_DIR/$file"
    if [ "$hash" = absent ]; then
      agmsg_dm_expect "$src" absent && agmsg_dm_expect "$dst" absent || return 1
    elif [ -e "$src" ]; then
      agmsg_dm_expect "$src" "$hash" && agmsg_dm_expect "$dst" absent || return 1
    else
      agmsg_dm_expect "$dst" "$hash" || return 1
    fi
  done
  selected="$source_db"
  if [ "$source_db" != "$shared" ] && [ -e "$target_db" ]; then
    [ ! -e "${source_db%/*}" ] && [ ! -L "${source_db%/*}" ] || return 1
    selected="$target_db"
  fi
  record=$(agmsg_dm_get "$shared" "$OLD_TEAM") || return 1
  shared_token=""
  if [ -n "$record" ]; then
    shared_token=$(agmsg_dm_verify_keys "$shared" "$descriptor" '' "$OLD_TEAM" "$NEW_TEAM") || return 1
  else
    # Shared admission is removed only after every externally visible step.
    # Verify those final states below before accepting this finalization case.
    agmsg_dm_expect "$OLD_DIR/config.json" absent || return 1
    agmsg_dm_expect "$NEW_DIR/config.json" "$config_after" || return 1
    [ "$selected" = "$target_db" ] || return 1
  fi
  record=$(agmsg_dm_get "$selected" "$OLD_TEAM") || return 1
  if [ -z "$record" ]; then
    # A crash between the two begins has not moved any registry/store data.
    [ -n "$shared_token" ] && [ "$selected" = "$source_db" ] || return 1
    agmsg_dm_expect "$OLD_DIR/config.json" "$config_before" || return 1
    agmsg_dm_expect "$NEW_DIR/config.json" absent || return 1
    agmsg_dm_begin "$selected" "$descriptor" "$OLD_TEAM" "$NEW_TEAM" || return 1
  fi
  token=$(agmsg_dm_verify_keys "$selected" "$descriptor" '' "$OLD_TEAM" "$NEW_TEAM") || return 1
  agmsg_dm_reservations_clear "$OLD_TEAM" && agmsg_dm_reservations_clear "$NEW_TEAM" || return 1
  sql=$(_rename_team_sql "$selected") || return 1
  guard=$(agmsg_dm_guard_sql "$descriptor" "$token" main "$OLD_TEAM" "$NEW_TEAM") || return 1
  if ! _sqlite_exec_stdin "$selected" "BEGIN IMMEDIATE; $guard $sql ROLLBACK;"; then
    if [ "$fresh" = true ]; then
      _sqlite_delivery_maintenance_finish_db "$selected" "$descriptor" "$token" "$OLD_TEAM" "$NEW_TEAM" >/dev/null || return 1
      if [ "$selected" != "$shared" ]; then
        _sqlite_delivery_maintenance_finish_db "$shared" "$descriptor" "$shared_token" "$OLD_TEAM" "$NEW_TEAM" >/dev/null || return 1
      fi
    fi
    return 1
  fi
  for file in config.json roster.jsonl roster-sync.json; do
    if [ -f "$OLD_DIR/$file" ]; then mv "$OLD_DIR/$file" "$NEW_DIR/$file"; fi
  done
  if [ "$source_db" != "$shared" ] && [ "$selected" = "$source_db" ]; then
    [ ! -e "${target_db%/*}" ] && [ ! -L "${target_db%/*}" ] || return 1
    mv "${source_db%/*}" "${target_db%/*}"
    selected="$target_db"
    token=$(agmsg_dm_verify_keys "$selected" "$descriptor" "$token" "$OLD_TEAM" "$NEW_TEAM") || return 1
  fi
  if [ "$(agmsg_dm_hash "$NEW_DIR/config.json")" != "$config_after" ]; then
    updated=$(agmsg_sqlite_mem "SELECT json_set(CAST(readfile('$(agmsg_sql_readfile_path "$NEW_DIR/config.json")') AS TEXT), '\$.name', '$(agmsg_sqlesc "$NEW_TEAM")');")
    [ "$(printf '%s\n' "$updated" | agmsg_sha256)" = "$config_after" ] || return 1
    agmsg_write_atomic "$NEW_DIR/config.json" "$updated"
  fi
  _sqlite_exec_stdin "$selected" "BEGIN IMMEDIATE; $guard $sql $(agmsg_dm_discard_claims_sql "$OLD_TEAM" "$NEW_TEAM") COMMIT;"
  sync_before=$(agmsg_dm_field "$descriptor" sync_before)
  sync_after=$(agmsg_dm_field "$descriptor" sync_after)
  if [ -d "$(agmsg_storage_dir)/remote-sync" ] || [ "$sync_before" != absent ]; then
    . "$SCRIPT_DIR/lib/node.sh"
    NODE_BIN=$(agmsg_resolve_node)
    "$NODE_BIN" "$SCRIPT_DIR/internal/rename-sync-config.mjs" "$(agmsg_storage_dir)" "$OLD_TEAM" "$NEW_TEAM" --resume "$sync_before" "$sync_after"
  fi
  agmsg_dm_expect "$NEW_DIR/config.json" "$config_after"
  agmsg_dm_expect "$NEW_DIR/roster.jsonl" "$journal_hash"
  agmsg_dm_expect "$NEW_DIR/roster-sync.json" "$roster_sync_hash"
  if [ "$selected" != "$shared" ] && [ -n "$shared_token" ]; then
    shared_guard=$(agmsg_dm_guard_sql "$descriptor" "$shared_token" main "$OLD_TEAM" "$NEW_TEAM") || return 1
    _sqlite_exec_stdin "$shared" "BEGIN IMMEDIATE; $shared_guard
      $(agmsg_dm_discard_claims_sql "$OLD_TEAM" "$NEW_TEAM")
      $(_sqlite_delivery_maintenance_finish_sql "$descriptor" "$shared_token" "$OLD_TEAM" "$NEW_TEAM") COMMIT;"
  fi
  _sqlite_delivery_maintenance_finish_db "$selected" "$descriptor" "$token" "$OLD_TEAM" "$NEW_TEAM" >/dev/null
  agmsg_lock_release
  rmdir "$OLD_DIR" 2>/dev/null || true
  echo "Renamed team $OLD_TEAM → $NEW_TEAM"
}

if [ "$(agmsg_storage_driver)" = sqlite ]; then
  _rename_team_sqlite
  exit $?
fi

# Only a team on the per-team partition owns a directory to move. On the shared
# partition its rows sit in a file with every other team's, so renaming rewrites
# the `team` column and moves nothing — which is what this script always did.
MOVES_STORE=false
if [ "$(agmsg_driver_for_team partition "$OLD_TEAM" shared)" = per-team ]; then
  MOVES_STORE=true
  # The store lives under the storage root, which AGMSG_STORAGE_PATH can move
  # independently of the config tree above — so it is resolved, never derived
  # from TEAMS_DIR. The whole directory moves, not just messages.db: the WAL
  # sidecars and the jsonl driver's events.jsonl are in it and belong to the
  # same team.
  OLD_STORE_DIR="$(dirname "$(agmsg_db_path "$OLD_TEAM")")"
  NEW_STORE_DIR="$(dirname "$(agmsg_storage_dir)/teams/$NEW_TEAM/messages.db")"
fi
DB="$(agmsg_db_path "$OLD_TEAM")"

if [ ! -d "$OLD_DIR" ]; then
  echo "Team not found: $OLD_TEAM"
  exit 1
fi

# Fast pre-check (re-checked authoritatively under the lock below): a real team
# has a config.json. An inert empty dir — e.g. left by an aborted rename — is not
# an existing team.
if [ -f "$NEW_DIR/config.json" ]; then
  echo "Team already exists: $NEW_TEAM"
  exit 1
fi

# Serialize against concurrent join/leave/reset/rename on BOTH the source and the
# target team (#141). A per-team lock can't reserve a not-yet-existent target by
# name, so we create the target dir and hold its lock too — a concurrent join to
# the new team then blocks on teams/<new>/.config.lock until the rename finishes.
# Acquire the two locks in a canonical (sorted) order so two crossing renames
# (a->b and b->a) can't deadlock.
mkdir -p "$OLD_DIR" "$NEW_DIR"
LOCK_A=$(printf '%s\n%s\n' "$OLD_DIR" "$NEW_DIR" | LC_ALL=C sort | sed -n 1p)
LOCK_B=$(printf '%s\n%s\n' "$OLD_DIR" "$NEW_DIR" | LC_ALL=C sort | sed -n 2p)
agmsg_lock_acquire "$LOCK_A" || exit 1
agmsg_lock_acquire "$LOCK_B" || exit 1

# Authoritative target check now that the target is locked: if it became a real
# team between the pre-check and the lock, abort.
if [ -f "$NEW_DIR/config.json" ]; then
  echo "Team already exists: $NEW_TEAM"
  exit 1
fi

# A store can outlive its config — leaving a team keeps its history — so the
# target name being free as a team does not mean it is free as a store. Checked
# before anything moves: refusing here costs nothing, while refusing after the
# config move would leave the rename half-applied.
if [ "$MOVES_STORE" = true ] && [ -e "$NEW_STORE_DIR" ]; then
  echo "A store already exists for $NEW_TEAM at $NEW_STORE_DIR" >&2
  echo "Remove or rename it before renaming this team; its history is not merged." >&2
  exit 1
fi

# Move the registry files into the locked, reserved target dir. Move the files
# (not the dir) because the target dir already exists — we created and locked
# it. The roster journal is name-independent identity history and follows the
# config unchanged.
mv "$OLD_DIR/config.json" "$NEW_DIR/config.json"
if [ -f "$OLD_DIR/roster.jsonl" ]; then
  mv "$OLD_DIR/roster.jsonl" "$NEW_DIR/roster.jsonl"
fi
if [ -f "$OLD_DIR/roster-sync.json" ]; then
  mv "$OLD_DIR/roster-sync.json" "$NEW_DIR/roster-sync.json"
fi

# Move the store with it, when the team has one of its own. A team that never
# sent anything has no store yet, which is not an error — the next send creates
# one under the new name. On the shared partition there is nothing to move and DB
# already names the file both names resolve to.
if [ "$MOVES_STORE" = true ] && [ -d "$OLD_STORE_DIR" ]; then
  mkdir -p "$(dirname "$NEW_STORE_DIR")"
  mv "$OLD_STORE_DIR" "$NEW_STORE_DIR"
  DB="$(agmsg_storage_dir)/teams/$NEW_TEAM/messages.db"
fi

# --- Update name in config.json ---
# Read the config with readfile() (not `.param set`, whose dot-command tokenizer
# does NOT honour SQL '' escaping, so an apostrophe in the config content breaks
# the binding) and escape the new team name as a SQL string literal (#223, #87):
# a team name may contain a single quote (validate.sh only blocks path traversal).
# Mirrors join.sh's readfile-based, apostrophe-safe registry read.
NEW_CONFIG="$NEW_DIR/config.json"
if [ -f "$NEW_CONFIG" ]; then
  CONFIG_SQL=$(agmsg_sql_readfile_path "$NEW_CONFIG")
  NEW_TEAM_LIT=$(agmsg_sqlesc "$NEW_TEAM")
  UPDATED=$(agmsg_sqlite_mem \
    "SELECT json_set(CAST(readfile('$CONFIG_SQL') AS TEXT), '\$.name', '$NEW_TEAM_LIT');")
  echo "$UPDATED" > "$NEW_CONFIG"
fi

# --- Update messages in DB ---
# Rewrite the team name in BOTH stores: the event log (where storage_send now
# writes) and the legacy messages table (pre-event-log installs). Without the
# events update a rename would orphan every message sent after the storage flip.
# Escape both team names as SQL string literals (#223, #87): a team name may
# contain a single quote (validate.sh only blocks path traversal), which would
# otherwise break the UPDATE and is an injection surface.
if [ -f "$DB" ]; then
  OLD_LIT=$(agmsg_sqlesc "$OLD_TEAM")
  NEW_LIT=$(agmsg_sqlesc "$NEW_TEAM")
  RENAME_SQL=""
  for TABLE in events read_cursors sync_bindings sync_messages sync_quarantine \
    sync_conflicts sync_read_members sync_read_remote_exact sync_read_aliases \
    sync_read_prepared; do
    if [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$TABLE';" | tr -d '\r')" = 1 ]; then
      case "$TABLE" in
        events|read_cursors) COLUMN=team ;;
        *) COLUMN=local_team ;;
      esac
      RENAME_SQL="$RENAME_SQL UPDATE $TABLE SET $COLUMN='$NEW_LIT' WHERE $COLUMN='$OLD_LIT';"
    fi
  done
  agmsg_sqlite "$DB" "BEGIN IMMEDIATE;
    UPDATE messages SET team='$NEW_LIT' WHERE team='$OLD_LIT';
    $RENAME_SQL
    COMMIT;"
fi


if [ "$(agmsg_storage_driver)" = jsonl ]; then
  agmsg_storage_load
  storage_rename_team "$OLD_TEAM" "$NEW_TEAM" >/dev/null
fi

SYNC_CONFIG_DIR="$(agmsg_storage_dir)/remote-sync"
if [ -d "$SYNC_CONFIG_DIR" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/node.sh"
  NODE_BIN=$(agmsg_resolve_node)
  "$NODE_BIN" "$SCRIPT_DIR/internal/rename-sync-config.mjs" \
    "$(agmsg_storage_dir)" "$OLD_TEAM" "$NEW_TEAM"
fi

agmsg_lock_release
# The old dir no longer holds a team (its config moved out); best-effort remove
# the now-empty dir. A concurrent join to the old name after this point
# legitimately creates a fresh team there.
rmdir "$OLD_DIR" 2>/dev/null || true
echo "Renamed team $OLD_TEAM → $NEW_TEAM"
echo
echo "Note: existing members in other projects/sessions still see the old"
echo "team name cached. Each member should re-run whoami in their project"
echo "to pick up the new name:"
echo
echo "  ~/.agents/skills/<skill>/scripts/whoami.sh \"\$(pwd)\" <type>"
