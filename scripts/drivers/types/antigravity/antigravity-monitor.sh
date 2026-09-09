#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Linux 専用に戻しました。私が一度 Darwin を通しましたが、それは誤りです ---- 「試していない」
# ではなく「動かないと分かっている」側でした。headless の実体 antigravity-bridge.mjs は
# lib/bridge-read-guard.mjs を通り、そこが /proc/<pid>/stat を直接読み、flock を spawn します。
# macOS では flock が無く(通過しても Bridge の constructor で例外)、Python 側の proc_start だけ
# 移植しても headless は成立しません。mjs 側の移植は別 issue。(#1073, #1090 レビュー)
case "$(uname -s)" in
  Linux) ;;
  *) echo 'Antigravity monitor は Linux 専用です（bridge-read-guard.mjs が /proc と flock に依存）' >&2; exit 1 ;;
esac
# `command -v X >/dev/null` のままだと set -e で**理由を言わずに** 1 で落ちます。落ちる理由を
# 言わない失敗は、直前まで直していた「所有権不一致 と lock を読めない」の取り違えと同じ後退です。
command -v node >/dev/null || { echo 'Antigravity monitor には node が要ります（PATH に見つかりません）' >&2; exit 1; }
command -v flock >/dev/null || { echo 'Antigravity monitor には flock が要ります（PATH に見つかりません）' >&2; exit 1; }
exec node "$HERE/antigravity-bridge.mjs" "$@"
