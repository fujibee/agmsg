#!/usr/bin/env bash
# Internal admission/recovery helpers for the SQLite identity/store transforms.
# No public barrier clearing operation: callers must prove their own exact
# before/final file invariants, while holding the existing registry lock.
[ -n "${_AGMSG_DELIVERY_MAINTENANCE_SH:-}" ] && return 0
_AGMSG_DELIVERY_MAINTENANCE_SH=1
_AGMSG_DM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_AGMSG_DM_LIB/name-encode.sh"

agmsg_dm_load() {
  [ "$(agmsg_storage_driver)" = sqlite ] || return 1
  agmsg_storage_load || return 1
  agmsg_dm_hash_probe
}

agmsg_dm_error() { printf 'agmsg: delivery maintenance: %s\n' "$1" >&2; return 1; }

agmsg_dm_field() {
  agmsg_sqlite_mem "SELECT json_extract('$(agmsg_sqlesc "$1")', '$.$2');"
}

# Maintenance uses one fixed algorithm from the SQLite CLI, independently of
# the external SHA-256 tools required by E2EE. The prefix keeps old or foreign
# descriptor fingerprints from being mistaken for this recovery contract.
agmsg_dm_fingerprint_valid() {
  local digest
  [ "$1" != absent ] || return 0
  case "$1" in sha3-256:*) digest="${1#sha3-256:}" ;; *) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
}

agmsg_dm_hash_probe() {
  local probe
  probe="$(set -o pipefail; agmsg_sqlite_mem "SELECT lower(hex(sha3(X'70726f6265',256)));")" || {
    agmsg_dm_error 'SQLite CLI SHA3-256 is unavailable'; return 1;
  }
  [ "$probe" = 62ee883ee174594990f5551d569e9e8a51995ea49287b3f81a030089c5ff3f4e ] || {
    agmsg_dm_error 'SQLite CLI SHA3-256 failed its known-input check'; return 1;
  }
}

# Fingerprints cover exact bytes, including empty files and trailing newlines.
# No credential-bearing contents enter descriptors or process arguments.
# Symlink inputs are never adopted for recovery. Check the digest implementation
# on every call, rather than trusting an environment-inherited memo.
agmsg_dm_hash() {
  local digest path
  [ ! -L "$1" ] || { agmsg_dm_error 'symbolic-link state is not recoverable'; return 1; }
  if [ ! -e "$1" ]; then printf 'absent\n'; return 0; fi
  [ -f "$1" ] || { agmsg_dm_error 'expected a regular state file'; return 1; }
  agmsg_dm_hash_probe || return 1
  path="$(agmsg_sql_readfile_path "$1")" || return 1
  digest="$(set -o pipefail; agmsg_sqlite_mem "SELECT CASE WHEN typeof(bytes)='blob'
    THEN lower(hex(sha3(bytes,256))) ELSE '' END
    FROM (SELECT readfile('$path') AS bytes);")" || return 1
  agmsg_dm_fingerprint_valid "sha3-256:$digest" || {
    agmsg_dm_error 'state file could not be fingerprinted'; return 1;
  }
  printf 'sha3-256:%s\n' "$digest"
}

# Hash the exact line agmsg_write_atomic will publish. This shell-function
# argument never becomes an external process argument; only SQL stdin carries
# the planned contents. A BLOB literal avoids the CLI normalizing CRLF in SQL
# text lines. No extra credential-bearing file is created.
agmsg_dm_hash_planned_line() {
  local digest bytes
  agmsg_dm_hash_probe || return 1
  bytes="$(set -o pipefail; printf '%s\n' "$1" | LC_ALL=C od -An -v -tx1 | LC_ALL=C tr -d '[:space:]')" || return 1
  case "$bytes" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ $(( ${#bytes} % 2 )) -eq 0 ] || return 1
  digest="$(
    set -o pipefail
    printf "SELECT lower(hex(sha3(X'%s',256)));\n" "$bytes" |
      agmsg_sqlite_mem -bail -batch
  )" || return 1
  agmsg_dm_fingerprint_valid "sha3-256:$digest" || {
    agmsg_dm_error 'planned state could not be fingerprinted'; return 1;
  }
  printf 'sha3-256:%s\n' "$digest"
}

agmsg_dm_expect() {
  local actual
  agmsg_dm_fingerprint_valid "$2" || {
    agmsg_dm_error 'unsupported state fingerprint'; return 1;
  }
  actual="$(agmsg_dm_hash "$1")" || return 1
  [ "$actual" = "$2" ] || {
    agmsg_dm_error 'state differs from the recorded operation; refusing recovery'; return 1;
  }
}

# The legacy filename separator is ambiguous when names contain '__'. Refuse
# any possibly matching reservation, including malformed files and symlinks;
# neither lease expiry nor --yes authorizes discarding an uncertain batch.
agmsg_dm_reservations_clear() {
  local team="$1" key file root
  key="$(_actas_lock_encode "$team")" || return 1
  root="$(cd "$_AGMSG_DM_LIB/../.." && pwd)/run"
  for file in "$root/read-reservation.$key"__*.json "$root/antigravity-reservation.$key"__*.json; do
    if [ -e "$file" ] || [ -L "$file" ]; then
      agmsg_dm_error 'durable read reservation exists; stop or recover its bridge first'
      return 1
    fi
  done
}

# Read existing barriers without initializing absent/old stores. Descriptor
# matching is the operation caller's responsibility; this never clears one.
agmsg_dm_get() { _sqlite_delivery_maintenance_get_db "$1" "$2"; }

# Locate an interrupted operation only in caller-enumerated canonical stores.
# Multiple copies are accepted only for a paired operation with the identical
# descriptor. Callers then validate every expected key/path and each fence.
agmsg_dm_find() {
  local team="$1" op="$2" argument="$3" db record descriptor seen=""
  shift 3
  AGMSG_DM_FOUND=false
  AGMSG_DM_DESCRIPTOR=""
  for db in "$@"; do
    case "$seen" in *"|$db|"*) continue ;; esac
    seen="$seen|$db|"
    record="$(agmsg_dm_get "$db" "$team")" || return 1
    [ -n "$record" ] || continue
    descriptor="$(agmsg_dm_field "$record" descriptor)" || return 1
    if [ "$AGMSG_DM_FOUND" = true ] && [ "$descriptor" != "$AGMSG_DM_DESCRIPTOR" ]; then
      agmsg_dm_error 'conflicting operations in candidate stores'; return 1
    fi
    agmsg_dm_adopt "$db" "$record" "$op" "$team" "$argument" || return 1
    AGMSG_DM_FOUND=true
  done
}

agmsg_dm_verify_keys() {
  local db="$1" descriptor="$2" expected_token="${3:-}" team record token
  shift 3
  for team in "$@"; do
    record="$(agmsg_dm_get "$db" "$team")" || return 1
    [ -n "$record" ] && [ "$(agmsg_dm_field "$record" descriptor)" = "$descriptor" ] || {
      agmsg_dm_error 'missing or mismatched paired operation'; return 1;
    }
    token="$(agmsg_dm_field "$record" token)"
    _sqlite_delivery_token "$token" || return 1
    [ -z "$expected_token" ] || [ "$token" = "$expected_token" ] || return 1
    expected_token="$token"
  done
  [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM delivery_maintenance WHERE descriptor='$(agmsg_sqlesc "$descriptor")' AND token='$expected_token';")" = "$#" ] || {
    agmsg_dm_error 'unexpected keys in paired operation'; return 1;
  }
  printf '%s\n' "$expected_token"
}

agmsg_dm_begin() {
  local db="$1" descriptor="$2" rows team
  shift 2
  for team in "$@"; do agmsg_dm_reservations_clear "$team" || return 1; done
  rows="$(_sqlite_delivery_maintenance_begin_db "$db" "$descriptor" "$@")" || return 1
  AGMSG_DM_DB="$db"
  AGMSG_DM_DESCRIPTOR="$descriptor"
  AGMSG_DM_TOKEN="$(agmsg_dm_field "$(printf '%s\n' "$rows" | sed -n 1p)" token)"
  _sqlite_delivery_token "$AGMSG_DM_TOKEN" || return 1
  for team in "$@"; do
    if ! agmsg_dm_reservations_clear "$team"; then
      _sqlite_delivery_maintenance_finish_db "$db" "$descriptor" "$AGMSG_DM_TOKEN" "$@" >/dev/null || return 1
      return 1
    fi
  done
}

agmsg_dm_adopt() {
  local db="$1" record="$2" op="$3" team="$4" arg="$5" descriptor fields field fingerprint
  descriptor="$(agmsg_dm_field "$record" descriptor)" || return 1
  [ "$(agmsg_dm_field "$descriptor" version)" = 1 ] &&
    [ "$(agmsg_dm_field "$descriptor" operation)" = "$op" ] &&
    [ "$(agmsg_dm_field "$descriptor" team)" = "$team" ] &&
    [ "$(agmsg_dm_field "$descriptor" argument)" = "$arg" ] || {
      agmsg_dm_error 'another or malformed operation blocks this team'; return 1;
    }
  _sqlite_delivery_token "$(agmsg_dm_field "$descriptor" nonce)" || {
    agmsg_dm_error 'invalid operation nonce'; return 1;
  }
  case "$op" in
    rename-agent) fields='config_before config_after journal_before journal_after' ;;
    rename-team) fields='config_before config_after journal roster_sync' ;;
    migrate-team-store) fields='config_before config_after' ;;
    delete-team) fields='config journal roster_sync' ;;
    *) agmsg_dm_error 'unsupported maintenance operation'; return 1 ;;
  esac
  for field in $fields; do
    fingerprint="$(agmsg_dm_field "$descriptor" "$field")" || return 1
    agmsg_dm_fingerprint_valid "$fingerprint" || {
      agmsg_dm_error 'unsupported state fingerprint'; return 1;
    }
    case "$field" in
      config|config_before|config_after)
        [ "$fingerprint" != absent ] || { agmsg_dm_error 'missing config fingerprint'; return 1; } ;;
    esac
  done
  # The optional Node sync-config plan has its own unchanged SHA-256 contract.
  # Validate both ends even if its source directory has already disappeared.
  if [ "$op" = rename-team ]; then
    for field in sync_before sync_after; do
      fingerprint="$(agmsg_dm_field "$descriptor" "$field")" || return 1
      [ "$fingerprint" != absent ] || continue
      [ "${#fingerprint}" -eq 64 ] || { agmsg_dm_error 'invalid sync fingerprint'; return 1; }
      case "$fingerprint" in *[!0-9a-f]*) agmsg_dm_error 'invalid sync fingerprint'; return 1 ;; esac
    done
  fi
  AGMSG_DM_DB="$db"
  AGMSG_DM_DESCRIPTOR="$descriptor"
  AGMSG_DM_TOKEN="$(agmsg_dm_field "$record" token)"
  _sqlite_delivery_token "$AGMSG_DM_TOKEN" || { agmsg_dm_error 'invalid operation token'; return 1; }
}

# Compile before invoking SQLite, then place directly after BEGIN IMMEDIATE.
# A surviving SQL descendant must prove the operation is still current inside
# the transaction; a shell-side check cannot fence it after recovery finishes.
# Only the fixed attached source alias is allowed for staged migration copies.
agmsg_dm_guard_sql() {
  [ "$#" -ge 4 ] && [ -n "$1" ] && _sqlite_delivery_token "$2" || return 1
  local descriptor="$1" token="$2" database="$3" team quoted team_quoted sql
  shift 3
  case "$database" in main|src) ;; *) return 1 ;; esac
  quoted=$(_sqlite_quote "$descriptor") || return 1
  sql='CREATE TEMP TABLE _delivery_transform_ids(id TEXT PRIMARY KEY NOT NULL);'
  for team in "$@"; do
    [ -n "$team" ] || return 1
    team_quoted=$(_sqlite_quote "$team") || return 1
    sql="$sql INSERT INTO _delivery_transform_ids VALUES($team_quoted);"
  done
  printf '%s\n' "$sql" || return 1
  _sqlite_delivery_assert_sql maintenance_fence "
    NOT EXISTS(SELECT 1 FROM _delivery_transform_ids i
      WHERE NOT EXISTS(SELECT 1 FROM $database.delivery_maintenance m
        WHERE m.team=i.id AND m.descriptor=$quoted AND m.token='$token'))
    AND NOT EXISTS(SELECT 1 FROM $database.delivery_maintenance m
      WHERE (m.descriptor=$quoted OR m.token='$token')
        AND m.team NOT IN(SELECT id FROM _delivery_transform_ids))"
}

agmsg_dm_discard_claims_sql() {
  local team lit
  for team in "$@"; do
    lit="$(agmsg_sqlesc "$team")"
    printf "DELETE FROM delivery_claims WHERE team='%s'; DELETE FROM delivery_ack_receipts WHERE team='%s';\n" "$lit" "$lit"
  done
}

agmsg_dm_finish() {
  _sqlite_delivery_maintenance_finish_db "$AGMSG_DM_DB" "$AGMSG_DM_DESCRIPTOR" "$AGMSG_DM_TOKEN" "$@" >/dev/null
}

# Only call this for a directory created by this process or whose exact token
# and contents were checked against a live maintenance descriptor.
agmsg_dm_remove_stage() {
  local stage="$1" name
  for name in config.json roster.jsonl; do
    [ ! -e "$stage/$name" ] || rm -f "$stage/$name" || return 1
  done
  rmdir "$stage"
}

agmsg_dm_stage_files() {
  local stage="$1" file base
  [ -d "$stage" ] && [ ! -L "$stage" ] || return 1
  for file in "$stage"/* "$stage"/.[!.]* "$stage"/..?*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    base="${file##*/}"
    case "$base" in config.json|roster.jsonl) ;; *) return 1 ;; esac
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
  done
}

agmsg_dm_publish_file() {
  local source="$1" target="$2" expected="$3"
  [ "$expected" != absent ] || { [ ! -e "$target" ] && [ ! -L "$target" ]; return; }
  agmsg_dm_expect "$source" "$expected" || return 1
  agmsg_write_atomic "$target" "$(cat "$source")" || return 1
  agmsg_dm_expect "$target" "$expected"
}
