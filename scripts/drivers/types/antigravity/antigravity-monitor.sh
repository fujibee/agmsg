#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Linux and macOS are supported. Windows is refused because it cannot provide
# equivalent POSIX process identity and advisory-lock guarantees.
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'Antigravity monitor requires POSIX process and lock primitives; this host is unsupported' >&2; exit 1 ;;
esac
# A bare `command -v X >/dev/null` lets set -e exit without a reason. A silent
# failure would regress the distinction between ownership mismatch and an
# unreadable lock.
command -v node >/dev/null || { echo 'Antigravity monitor には node が要ります（PATH に見つかりません）' >&2; exit 1; }
if [ "$(uname -s)" = Darwin ]; then
  command -v python3 >/dev/null || { echo 'Antigravity monitor requires python3 for advisory locks on macOS' >&2; exit 1; }
else
  command -v flock >/dev/null || { echo 'Antigravity monitor には flock が要ります（PATH に見つかりません）' >&2; exit 1; }
fi
exec node "$HERE/antigravity-bridge.mjs" "$@"
