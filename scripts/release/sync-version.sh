#!/usr/bin/env bash
# Sync derived version fields from the canonical VERSION file.
#
# `VERSION` (plain text at the repo root) is the single source of truth for
# the agmsg release version. Everything else — `package.json` (npm),
# `.claude-plugin/plugin.json` (Claude Code plugin marketplace) — is derived.
#
# Usage:
#   scripts/release/sync-version.sh           # write derived files
#   scripts/release/sync-version.sh --check   # exit 1 if any derived file is out of sync
#
# Local release flow:
#   1. echo 1.2.3 > VERSION
#   2. scripts/release/sync-version.sh
#   3. git commit -am "release: 1.2.3" && git tag v1.2.3 && git push --follow-tags
#
# CI uses --check so a forgotten step 2 fails the pre-release guard.

set -euo pipefail

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

[[ -f "$VERSION_FILE" ]] || { echo "VERSION file not found at $VERSION_FILE" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -n "$VERSION" ]] || { echo "VERSION file is empty" >&2; exit 1; }

# Reject anything that is not a semver-shaped string. The release workflow
# keys off this, so a stray "v1.0.0" or trailing whitespace would silently
# break the tag-matching guard.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must be semver (got: $VERSION)" >&2
  exit 1
fi

DERIVED=(
  "package.json"
  ".claude-plugin/plugin.json"
)

echo "VERSION = $VERSION"
rc=0
for rel in "${DERIVED[@]}"; do
  path="$REPO_ROOT/$rel"
  [[ -f "$path" ]] || { echo "missing derived file: $rel" >&2; exit 1; }
  current=$(jq -r '.version // ""' "$path")
  if [[ "$current" == "$VERSION" ]]; then
    echo "  $rel: already $VERSION"
    continue
  fi
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "  $rel: out of sync (file=$current, VERSION=$VERSION)" >&2
    rc=1
    continue
  fi
  tmp=$(mktemp)
  jq --arg v "$VERSION" '.version = $v' "$path" > "$tmp"
  mv "$tmp" "$path"
  echo "  $rel: $current -> $VERSION"
done

exit "$rc"
