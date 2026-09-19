#!/usr/bin/env bash
# Type-neutral read reservation hook installed around storage readers.
_AGMSG_BRIDGE_CORE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AGMSG_BRIDGE_SKILL_DIR="$(cd "$_AGMSG_BRIDGE_CORE_LIB/../.." && pwd)"

# shellcheck disable=SC1091
. "$_AGMSG_BRIDGE_CORE_LIB/name-encode.sh"

_agmsg_bridge_guard_path() {
  local team="$1" agent="$2"
  printf '%s/run/read-reservation.%s__%s.json' "$_AGMSG_BRIDGE_SKILL_DIR" \
    "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$agent")"
}

_agmsg_bridge_guard_legacy_path() {
  local team="$1" agent="$2"
  printf '%s/run/antigravity-reservation.%s__%s.json' "$_AGMSG_BRIDGE_SKILL_DIR" \
    "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$agent")"
}

_agmsg_bridge_guard_reservation() {
  local neutral legacy
  neutral="$(_agmsg_bridge_guard_path "$1" "$2")" || return 2
  legacy="$(_agmsg_bridge_guard_legacy_path "$1" "$2")" || return 2
  if [ -e "$neutral" ] && [ -e "$legacy" ]; then
    printf 'agmsg: both read reservation formats exist for %s/%s; refusing to resolve one\n' "$1" "$2" >&2
    return 2
  fi
  if [ -e "$neutral" ]; then
    printf '%s\n' "$neutral"
    return 0
  fi
  if [ -e "$legacy" ]; then
    printf '%s\n' "$legacy"
    return 0
  fi
  return 1
}

_agmsg_bridge_guard_type() {
  local reservation="$1" type rc
  type="$(node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(!Object.prototype.hasOwnProperty.call(r,"type")) process.exit(3); if(typeof r.type!=="string") process.exit(4); process.stdout.write(r.type)' "$reservation" 2>/dev/null)" || {
    rc=$?
    if [ "$rc" -eq 3 ] && [[ "$(basename "$reservation")" == antigravity-reservation.*.json ]]; then
      type=antigravity
    else
      return 1
    fi
  }
  case "$type" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s\n' "$type"
}

agmsg_bridge_guard_check() {
  local reservation rc type driver
  reservation="$(_agmsg_bridge_guard_reservation "$1" "$2")" || {
    rc=$?
    [ "$rc" -eq 1 ] && return 0
    return 13
  }
  type="$(_agmsg_bridge_guard_type "$reservation")" || {
    printf 'agmsg: read reservation has no valid driver type: %s\n' "$reservation" >&2
    return 13
  }
  driver="$_AGMSG_BRIDGE_SKILL_DIR/scripts/drivers/types/$type"
  [ -d "$driver" ] || {
    printf 'agmsg: read reservation names an unknown driver type: %s\n' "$type" >&2
    return 13
  }
  [ -f "$driver/bridge-read-guard.sh" ] || {
    printf 'agmsg: driver type has no read reservation guard: %s\n' "$type" >&2
    return 13
  }
  # shellcheck disable=SC1090
  source "$driver/bridge-read-guard.sh" || return 13
  declare -F agmsg_type_bridge_guard_check >/dev/null 2>&1 || return 13
  agmsg_type_bridge_guard_check "$reservation" "$@"
}

agmsg_bridge_guard_install() {
  declare -F _bridge_original_mark >/dev/null && return 0
  declare -F storage_mark_read_batch >/dev/null || return 1
  declare -F storage_read_cursor_consume >/dev/null || return 1
  eval "$(declare -f storage_mark_read_batch | sed '1s/storage_mark_read_batch/_bridge_original_mark/')"
  eval "$(declare -f storage_read_cursor_consume | sed '1s/storage_read_cursor_consume/_bridge_original_consume/')"
  storage_mark_read_batch() {
    agmsg_bridge_guard_check "$@" || { echo runtime_error; return 13; }
    _bridge_original_mark "$@"
  }
  storage_read_cursor_consume() {
    local team="$1" agent="$2" cursor="$3"; shift 3
    agmsg_bridge_guard_check "$team" "$agent" "$@" || { echo runtime_error; return 13; }
    _bridge_original_consume "$team" "$agent" "$cursor" "$@"
  }
}
