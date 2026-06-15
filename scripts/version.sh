#!/usr/bin/env bash
set -euo pipefail

# Print the installed agmsg version — the git-describe provenance string that
# install.sh recorded at install time (see #117). This identifies the exact
# source an install came from, including commits past the last tagged release
# and a `-dirty` marker when it was installed from a tree with uncommitted
# changes. Falls back gracefully if no version was recorded (older install).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$SKILL_DIR/VERSION" ]; then
  cat "$SKILL_DIR/VERSION"
else
  echo "unknown (no VERSION recorded — reinstall/--update to record provenance)"
fi
