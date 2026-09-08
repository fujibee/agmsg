#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(uname -s)" = Linux ] || { echo '初回対応はLinuxのみ' >&2; exit 1; }
command -v node >/dev/null
command -v flock >/dev/null
exec node "$HERE/antigravity-bridge.mjs" "$@"
