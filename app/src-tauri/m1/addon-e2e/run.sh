#!/usr/bin/env bash
set -euo pipefail

# End-to-end run of the two built-in add-ons (File view, Diff view) in the REAL app
# window, against a safe copy of the agmsg home and a throwaway git repository.
#
#   cd app/src-tauri && m1/addon-e2e/run.sh
#
# What it does:
#   1. builds the frontend in `--mode e2e` (the only mode that contains the folder
#      seam in AddonPaneHost) and a debug app with its own identifier
#      (cc.agmsg.addon-e2e), so it never forwards to an installed agmsg app;
#   2. makes a safe copy of the agmsg home (m1/make-check-copy.sh) and a fixture repo;
#   3. starts the app with AGMSG_APP_BASE pointing at the copy, the debug-only driver
#      (AGMSG_ADDON_E2E) and the broker trace (AGMSG_ADDON_TRACE);
#   4. the driver clicks the real UI: team, "+ New" > File view / Diff view, the grant
#      cards; the frames then talk to the broker through the real relay. It then
#      asks the broker directly (the same addon_request command) for the ops the
#      frames do not use, and reports each answer;
#   5. prints the trace and the answers, and stops the app by its own pid.
#
# The window stays in the background: macOS delays its timers while it is hidden, so
# the run re-wakes the page on a schedule (AGMSG_ADDON_E2E_LATER). Panes run no
# terminal and no agent. Nothing outside the temporary folders is written.

here="$(cd "$(dirname "$0")" && pwd)"
tauri_dir="$(cd "$here/../.." && pwd)"
app_dir="$(cd "$tauri_dir/.." && pwd)"
work="$(mktemp -d)"
trap 'if [ -n "${app_pid:-}" ]; then kill "$app_pid" 2>/dev/null || true; fi' EXIT

echo "== build (frontend --mode e2e, debug app)"
(cd "$app_dir" && pnpm exec vite build --mode e2e >/dev/null \
  && pnpm tauri build --debug --no-bundle \
       --config '{"identifier":"cc.agmsg.addon-e2e","build":{"beforeBuildCommand":""}}' 2>&1 | tail -1)

echo "== safe copy of the agmsg home and a fixture repository"
base="$work/base"; mkdir -p "$base"
"$tauri_dir/m1/make-check-copy.sh" "$base" > "$work/copy.log"
head -1 "$work/copy.log"
team="${AGMSG_E2E_TEAM:-$(ls "$base/db/teams" 2>/dev/null | head -1)}"
[ -n "$team" ] || { echo "no team in the copy; set AGMSG_E2E_TEAM" >&2; exit 1; }
fx="$work/proj"; mkdir -p "$fx/src"
(
  cd "$fx"
  git init -q -b main
  printf '# E2E project\n\nHello **world**.\n' > README.md
  printf 'export const a = 1;\nexport const b = 2;\n' > src/main.ts
  printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' > logo.png
  git add -A
  git -c user.name=T -c user.email=t@example.com commit -q -m first
  printf '# E2E project\n\nHello **there**.\n' > README.md
  printf 'untracked file\n' > new.txt
)

sed -e "s|__FIXTURE__|$fx|g" -e "s|__TEAM__|$team|g" "$here/driver.js" > "$work/driver.js"
later=""
for t in $(seq 30 6 300); do later="$later,$here/alive.js@$t"; done

log="$work/run.log"
echo "== run (team: $team, fixture: $fx)"
AGMSG_APP_BASE="$base" AGMSG_ADDON_E2E="$work/driver.js" AGMSG_ADDON_E2E_LATER="${later#,}" \
  AGMSG_ADDON_E2E_DELAY=15 AGMSG_ADDON_TRACE=1 \
  "$tauri_dir/target/debug/agmsg-app" > "$log" 2>&1 < /dev/null &
app_pid=$!

for _ in $(seq 1 150); do
  grep -qE '"(FAILED|finished)' "$log" && break
  sleep 2
done
grep -E 'resolved:' "$log" | cut -c1-160
grep -E 'git:read|add-ons:|addons-trace|addons-e2e\] "(ASK|opening|file view|diff view|FAILED|finished)' "$log" | cut -c1-420
echo "== full log: $log (the safe copy and fixture are in $work; delete by hand)"
grep -q '"finished' "$log"
