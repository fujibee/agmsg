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
git fetch origin tag "$REF" --no-tags --depth 1

rm -rf "$DEST"
mkdir -p "$DEST"
git archive "$REF" -- scripts/ install.sh uninstall.sh | tar -x -C "$DEST"
chmod +x "$DEST/install.sh" "$DEST/uninstall.sh"

echo "bundle-core: bundled agmsg-core @ $REF into $DEST"
