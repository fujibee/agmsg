#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Linux は検証済み、macOS は未検証だが動くはずの経路(#1073)。それ以外は拒否する ----
# 「試していない」と「動かないと分かっている」は別の事実なので、後者だけを止める。
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'Antigravity monitor は Linux / macOS のみです' >&2; exit 1 ;;
esac
command -v node >/dev/null
command -v flock >/dev/null
exec node "$HERE/antigravity-bridge.mjs" "$@"
