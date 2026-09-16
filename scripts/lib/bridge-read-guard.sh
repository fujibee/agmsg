#!/usr/bin/env bash
# 予約はインストール単位。環境変数を落とした通常inboxも同じ入口を通す。
_AGMSG_BRIDGE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agmsg_bridge_guard_path() {
  local SKILL_DIR; SKILL_DIR="$(cd "$_AGMSG_BRIDGE_LIB/../.." && pwd)"
  source "$_AGMSG_BRIDGE_LIB/actas-lock.sh"
  printf '%s/run/antigravity-reservation.%s__%s.json' "$SKILL_DIR" "$(_actas_lock_encode "$1")" "$(_actas_lock_encode "$2")"
}
agmsg_bridge_guard_check() {
  local reservation; reservation="$(agmsg_bridge_guard_path "$1" "$2")" || return 13
  [ -e "$reservation" ] || return 0
  # fd3はtransportで一度だけ読み、非export変数として保持。二段guardも再検査する。
  printf '%s' "${_AGMSG_BRIDGE_ACK_CAP:-}" | node "$_AGMSG_BRIDGE_LIB/bridge-read-guard.mjs" check "$reservation" "$$" "$@"
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
  # cursor値はshift前に保存する必要がある。
  storage_read_cursor_consume() {
    local team="$1" agent="$2" cursor="$3"; shift 3
    agmsg_bridge_guard_check "$team" "$agent" "$@" || { echo runtime_error; return 13; }
    _bridge_original_consume "$team" "$agent" "$cursor" "$@"
  }
}
