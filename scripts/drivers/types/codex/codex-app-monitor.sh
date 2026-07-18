#!/usr/bin/env bash
set -euo pipefail

# This entry point is retained only so older installations fail closed.
# A successful background `codex exec resume` can read and answer agmsg mail
# without rendering the work in Codex Desktop. That violates the visible
# monitor contract, so no environment variable can re-enable this transport.

usage() {
  cat <<'EOF'
Usage: codex-app-monitor.sh <project> <type> <team> <name> <thread_id>

This legacy background receiver is disabled.
Use a visible app-server bridge, or use turn delivery when no bridge is
available.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

echo "codex-app-monitor: disabled; background-only handling is prohibited." >&2
echo "codex-app-monitor: use a visible app-server bridge or visible turn delivery." >&2
exit 64
