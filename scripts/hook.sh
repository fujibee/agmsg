#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible alias for delivery.sh.
#
# Usage: hook.sh on  <type> <project_path>   → delivery.sh set turn ...
#        hook.sh off <type> <project_path>   → delivery.sh set off ...
#
# hook.sh predates the delivery-mode redesign. Prefer delivery.sh directly:
#   delivery.sh set <monitor|turn|both|off> <type> <project_path>

ACTION="${1:?Usage: hook.sh on|off <type> <project_path>}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "agmsg: hook.sh is deprecated; use 'delivery.sh set <mode>' or '/agmsg mode <mode>' instead." >&2

case "$ACTION" in
  on)  exec "$SCRIPT_DIR/delivery.sh" set turn "$@" ;;
  off) exec "$SCRIPT_DIR/delivery.sh" set off  "$@" ;;
  *)   echo "Unknown action: $ACTION (use on|off)" >&2; exit 1 ;;
esac
