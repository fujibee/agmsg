#!/bin/bash
# usage: m1/make-check-copy.sh <empty-dir>
# Makes a safe copy of the agmsg home for a UI test: no live daemon files, no cloud-sync
# state, and every message store taken with sqlite's own .backup (a plain cp of a live
# WAL database can be inconsistent). Nothing in the real install is changed.
set -eu
src=${AGMSG_SRC:-$HOME/.agents/skills/agmsg}
dst=${1:?usage: make-check-copy.sh <empty-dir>}
[ -d "$src" ] || { echo "no agmsg install at $src" >&2; exit 2; }
[ -d "$dst" ] || { echo "$dst is not a directory" >&2; exit 2; }
[ -z "$(ls -A "$dst")" ] || { echo "$dst is not empty" >&2; exit 2; }
command -v sqlite3 >/dev/null || { echo "sqlite3 is needed" >&2; exit 2; }

# everything except live state and the stores themselves
rsync -a \
  --exclude '/run/' \
  --exclude '/db/remote-sync/' \
  --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' --exclude '*.db-journal' \
  --exclude '.git/' \
  "$src"/ "$dst"/

# each store, consistently
n=0
while IFS= read -r -d '' f; do
  rel=${f#"$src"/}
  case "$rel" in run/*|db/remote-sync/*) continue ;; esac
  mkdir -p "$dst/$(dirname "$rel")"
  sqlite3 -readonly "$f" ".backup '$dst/$rel'"
  n=$((n + 1))
done < <(find "$src/db" "$src/teams" -maxdepth 4 -type f -name '*.db' -print0 2>/dev/null)

# the copy must not point anywhere else: report any storage/config override or sync setting
cfg="$dst/db/config.yaml"
echo "copied to $dst ($n store file(s) via sqlite .backup; run/ and db/remote-sync/ left out)"
if [ -f "$cfg" ] && grep -n -i -E 'storage|remote|sync|endpoint' "$cfg"; then
  echo "WARNING: the lines above in the copied config may point outside the copy or enable sync; review them before launching." >&2
fi
echo "launch with:  AGMSG_APP_BASE=$dst   (the app prints a '[agmsg-app] resolved:' line; every path in it must start with $dst)"
