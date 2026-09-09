#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/../../../.." && pwd)"
source "$SKILL_DIR/scripts/lib/require-python3.sh"
agmsg_require_python3 'Antigravity TUI monitor' || exit 1
action=run
case "${1:-}" in
  status|stop|resume|reset-guard|ack|replay) action="$1"; shift ;;
esac
# こちらも Linux 専用に戻します。supervisor(Python)は移植しましたが、status / stop / resume /
# reset-guard の制御はどれも antigravity-mode.mjs を通り、そこが未移植の /proc 読みを持っています
# ---- 起動はできて停止はできない状態になり、それは提供しないより悪い。(#1090 レビュー)
case "$(uname -s)" in
  Linux) ;;
  *) echo 'Antigravity TUI monitor は Linux 専用です（antigravity-mode.mjs が /proc に依存）' >&2; exit 1 ;;
esac
if [ "$action" = run ]; then
  [ -t 0 ] && [ -t 1 ] || { echo 'Antigravity TUI monitor は対話端末から起動してください' >&2; exit 1; }
fi
exec python3 "$HERE/antigravity-tui-supervisor.py" --action "$action" "$@"
