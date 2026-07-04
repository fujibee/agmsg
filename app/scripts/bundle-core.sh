#!/usr/bin/env bash
# Bundles a pinned snapshot of agmsg-core (scripts/, install.sh, uninstall.sh)
# into src-tauri/resources/agmsg-core/ for the app's first-run auto-install
# flow — see agmsg_install in src-tauri/src/agmsg.rs. At runtime the app runs
# this bundled install.sh directly, with no network access.
#
# The ref is a committed pin (AGMSG_CORE_REF), not resolved dynamically at
# build time — that's the point of bundling instead of curl|bash at runtime:
# what ships is fixed and auditable via git history. Bump AGMSG_CORE_REF by
# hand to pick up newer agmsg-core fixes.
#
# Called from three places that must stay in sync: app-release.yml's macOS
# and Windows jobs, and build-notarize.sh for local builds.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$APP_DIR/.."
REF_FILE="$APP_DIR/AGMSG_CORE_REF"
DEST="$APP_DIR/src-tauri/resources/agmsg-core"

REF="$(tr -d '[:space:]' < "$REF_FILE")"
if [ -z "$REF" ]; then
  echo "bundle-core: $REF_FILE is empty" >&2
  exit 1
fi

cd "$ROOT_DIR"
echo "bundle-core: fetching tag $REF..."
# No --depth here — this runs against the same checkout a developer is
# working in (build-notarize.sh calls this directly), and a shallow fetch
# there leaves the whole local repo shallow: git log/merge-base/rebase
# against origin/main silently stop at the new shallow boundary. CI
# checkouts are disposable, so this is a non-issue there either way.
git fetch origin tag "$REF" --no-tags

rm -rf "$DEST"
mkdir -p "$DEST"
git archive "$REF" -- scripts/ install.sh uninstall.sh VERSION | tar -x -C "$DEST"
chmod +x "$DEST/install.sh" "$DEST/uninstall.sh"

# Sanity check: the pin must actually satisfy what the app needs from
# agmsg-core, not just exist. v0.1.0 shipped pinned to a tag that predated
# the agmsg-app type registration, so a fresh auto-install died the moment
# a user tried to add an app-user ("Unknown agent type: agmsg-app") — this
# would have caught it at build time instead of in the field. Add to this
# list whenever the app starts depending on more of agmsg-core.
REQUIRED_PATHS=(
  "scripts/api.sh"
  "scripts/drivers/types/agmsg-app/type.conf"
  "VERSION"
)
for p in "${REQUIRED_PATHS[@]}"; do
  if [ ! -f "$DEST/$p" ]; then
    echo "bundle-core: pinned ref $REF is missing required path '$p' — bump AGMSG_CORE_REF" >&2
    exit 1
  fi
done

echo "bundle-core: bundled agmsg-core @ $REF into $DEST"
