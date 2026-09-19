#!/usr/bin/env bash
# Compatibility wrapper. The canonical command is codex-diag.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/codex-diag.sh" "$@"
