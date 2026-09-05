#!/usr/bin/env bash
set -euo pipefail

# Codex の host プロセス操作を fail-closed にする読み取り・操作境界。
#
# このスクリプトは、sandbox 内の ps 結果を host の事実として補完しない。
# 対象または現在の実行チェーンを観測できない場合は UNKNOWN を返し、kill
# を実行しない。停止操作を行う場合は --approve を明示し、対象の起動引数
# を完全な期待値として指定する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/instance-id.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  codex-process-guard.sh inspect <pid> <expected-args-glob>
  codex-process-guard.sh kill --approve <pid> <expected-args-glob>
EOF
}

pid_is_visible() {
  local pid="$1"
  _agmsg_pid_valid "$pid" || return 1
  if [ -n "$(ps -o pid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" ]; then
    return 0
  fi
  return 1
}

pid_args() {
  local args
  args="$(ps -o args= -p "$1" 2>/dev/null | sed -e 's/[[:space:]]*$//' | head -n 1 || true)"
  printf '%s' "$args"
}

# 0: target is in the current process chain.
# 1: target is visible and outside the chain.
# 2: the chain or target cannot be observed, therefore UNKNOWN.
target_chain_state() {
  local target="$1" current="${2:-$$}" line parent
  _agmsg_pid_valid "$target" || return 2
  pid_is_visible "$target" || return 2

  while :; do
    _agmsg_pid_valid "$current" || return 2
    line="$(ps -o pid=,ppid= -p "$current" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
    [ -n "$line" ] || return 2
    read -r _ parent <<EOF
$line
EOF
    [ "$current" != "$target" ] || return 0
    [ -n "${parent:-}" ] || return 2
    [ "$parent" != "$current" ] || return 1
    [ "$parent" != "1" ] || return 1
    current="$parent"
  done
}

inspect_target() {
  local pid="$1" expected="$2" args chain
  if ! _agmsg_pid_valid "$pid"; then
    echo "UNKNOWN invalid-pid"
    return 2
  fi
  args="$(pid_args "$pid")"
  if [ -z "$args" ]; then
    echo "UNKNOWN target-not-observable"
    return 2
  fi
  case "$args" in
    $expected) ;;
    *) printf 'REJECT args-mismatch args=%s\n' "$args"; return 1 ;;
  esac
  if target_chain_state "$pid"; then
    chain=0
  else
    chain="$?"
  fi
  case "$chain" in
    0) echo "REJECT current-process-chain"; return 1 ;;
    1) echo "SAFE target-outside-current-chain"; return 0 ;;
    *) echo "UNKNOWN process-chain-not-observable"; return 2 ;;
  esac
}

main() {
  local action="${1:-}" pid expected
  case "$action" in
    inspect)
      [ "$#" -eq 3 ] || { usage; return 2; }
      inspect_target "$2" "$3"
      ;;
    kill)
      [ "${2:-}" = "--approve" ] && [ "$#" -eq 4 ] || { usage; return 2; }
      pid="$3"; expected="$4"
      inspect_target "$pid" "$expected" || return $?
      kill "$pid"
      echo "KILLED pid=$pid"
      ;;
    *) usage; return 2 ;;
  esac
}

main "$@"
