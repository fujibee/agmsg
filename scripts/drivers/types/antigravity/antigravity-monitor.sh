#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Linux/macOS で動作します。Windows では POSIX のプロセス識別と advisory lock を
# 同じ保証で提供できないため、起動後に止められない状態を作らないよう拒否します。
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'Antigravity monitor requires POSIX process and lock primitives; this host is unsupported' >&2; exit 1 ;;
esac
# `command -v X >/dev/null` のままだと set -e で**理由を言わずに** 1 で落ちます。落ちる理由を
# 言わない失敗は、直前まで直していた「所有権不一致 と lock を読めない」の取り違えと同じ後退です。
command -v node >/dev/null || { echo 'Antigravity monitor には node が要ります（PATH に見つかりません）' >&2; exit 1; }
if [ "$(uname -s)" = Darwin ]; then
  command -v python3 >/dev/null || { echo 'Antigravity monitor requires python3 for advisory locks on macOS' >&2; exit 1; }
else
  command -v flock >/dev/null || { echo 'Antigravity monitor には flock が要ります（PATH に見つかりません）' >&2; exit 1; }
fi
exec node "$HERE/antigravity-bridge.mjs" "$@"
