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
[ "$(uname -s)" = Linux ] || { echo 'Antigravity TUI monitor は初回対応ではLinux専用です' >&2; exit 1; }
if [ "$action" = run ]; then
  [ -t 0 ] && [ -t 1 ] || { echo 'Antigravity TUI monitor は対話端末から起動してください' >&2; exit 1; }
fi
exec python3 "$HERE/antigravity-tui-supervisor.py" --action "$action" "$@"
