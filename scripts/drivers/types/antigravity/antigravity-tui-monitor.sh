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
# 同上(#1073)。macOS は未検証: 失敗したら issue を上げてください。
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'Antigravity TUI monitor は Linux / macOS のみです' >&2; exit 1 ;;
esac
if [ "$action" = run ]; then
  [ -t 0 ] && [ -t 1 ] || { echo 'Antigravity TUI monitor は対話端末から起動してください' >&2; exit 1; }
fi
exec python3 "$HERE/antigravity-tui-supervisor.py" --action "$action" "$@"
