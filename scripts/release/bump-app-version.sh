#!/usr/bin/env bash
# Bump the desktop app version across every file that carries it, in one shot.
#
# The app version (currently 0.1.x) is separate from the CLI's VERSION file
# (sync-version.sh handles that one). Four files carry the app version and must
# move together, or a release ships an installer whose in-app version disagrees
# with the tag — the app-release.yml tag guard now fails such a mismatch, and
# this script is the paired "do it right in one command" so the human never
# hand-edits three of four and forgets the last.
#
# Usage:
#   scripts/release/bump-app-version.sh <X.Y.Z>   # bare semver, no leading v/app-v
#
# Release flow:
#   1. scripts/release/bump-app-version.sh 0.1.4
#   2. review the diff, confirm the agmsg-core pin it prints
#   3. git commit -am "chore(app): bump version to 0.1.4"
#   4. git tag app-v0.1.4 && git push --follow-tags
set -euo pipefail

die() { echo "bump-app-version: $*" >&2; exit 1; }

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: bump-app-version.sh <X.Y.Z>  (bare semver, no leading v/app-v)"
# Reject a tag-shaped or v-prefixed argument up front (same guard style as
# update-cask.sh) so `app-v0.1.4` or `v0.1.4` can't slip in as the version.
case "$VERSION" in
  v*|app-*) die "version must be bare semver, no leading v/app-v (got '$VERSION')" ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || die "version must be semver MAJOR.MINOR.PATCH (got '$VERSION')"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/app"

# Replace only the FIRST `"version": "..."` in a JSON file — the top-level one
# (both tauri.conf.json and package.json carry it there). awk keeps the edit to
# a single line so the diff is a one-liner and file formatting is untouched
# (portable across GNU/BSD, unlike sed's `0,/re/` address).
bump_json() {
  local f="$1"
  [ -f "$f" ] || die "not found: $f"
  awk -v v="$VERSION" '
    !done && /"version":[[:space:]]*"[^"]*"/ {
      sub(/"version":[[:space:]]*"[^"]*"/, "\"version\": \"" v "\""); done=1
    } { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  grep -q "\"version\": \"$VERSION\"" "$f" || die "failed to bump version in $f"
}

bump_json "$APP/src-tauri/tauri.conf.json"
bump_json "$APP/package.json"

# Cargo.toml: the [package] version is the first `version = ` line in the file.
awk -v v="$VERSION" '
  !done && /^version[[:space:]]*=/ { sub(/^version[[:space:]]*=.*/, "version = \"" v "\""); done=1 }
  { print }
' "$APP/src-tauri/Cargo.toml" > "$APP/src-tauri/Cargo.toml.tmp" \
  && mv "$APP/src-tauri/Cargo.toml.tmp" "$APP/src-tauri/Cargo.toml"

# Cargo.lock: bump only the version line inside the agmsg-app package block.
awk -v v="$VERSION" '
  /^name = "agmsg-app"$/ { inpkg=1 }
  inpkg && /^version[[:space:]]*=/ { sub(/^version[[:space:]]*=.*/, "version = \"" v "\""); inpkg=0 }
  { print }
' "$APP/src-tauri/Cargo.lock" > "$APP/src-tauri/Cargo.lock.tmp" \
  && mv "$APP/src-tauri/Cargo.lock.tmp" "$APP/src-tauri/Cargo.lock"

echo "Bumped app version -> $VERSION:"
echo "  app/src-tauri/tauri.conf.json"
echo "  app/package.json"
echo "  app/src-tauri/Cargo.toml"
echo "  app/src-tauri/Cargo.lock (agmsg-app)"

# The bundled agmsg-core is pinned separately (app/AGMSG_CORE_REF); a version
# bump is the moment to confirm it, since the app ships whatever it points at.
CORE_REF="$(tr -d '[:space:]' < "$APP/AGMSG_CORE_REF" 2>/dev/null || true)"
echo
echo "NOTE: bundled agmsg-core pin is AGMSG_CORE_REF=${CORE_REF:-<unset>}"
echo "      Is that the core version to ship with app v$VERSION? Edit app/AGMSG_CORE_REF if not."
