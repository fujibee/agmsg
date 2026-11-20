#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version: from its "## [X.Y.Z]"
# heading up to (not including) the next "## [" heading, trailing compare link
# included. This is the text the GitHub Release carries.
#
# Usage: changelog-section.sh <version> [changelog-file]
#
# Exits non-zero, with the reason on stderr and nothing on stdout, when the
# file is unreadable, has no such section, or the section has no body. The
# caller must not paper over that with another source of notes.
set -euo pipefail

version="${1:-}"
file="${2:-CHANGELOG.md}"

if [[ -z "$version" ]]; then
  echo "usage: changelog-section.sh <version> [changelog-file]" >&2
  exit 2
fi
if [[ ! -r "$file" ]]; then
  echo "changelog-section: cannot read $file" >&2
  exit 1
fi

section="$(awk -v want="## [$version]" '
  index($0, want) == 1 { on = 1; print; next }
  on && index($0, "## [") == 1 { exit }
  on { print }
' "$file")"

if [[ -z "$section" ]]; then
  echo "changelog-section: no \"## [$version]\" section in $file" >&2
  exit 1
fi

# Body = everything after the heading line; blank-only means empty.
body="$(printf '%s\n' "$section" | tail -n +2 | tr -d '[:space:]')"
if [[ -z "$body" ]]; then
  echo "changelog-section: the \"## [$version]\" section in $file is empty" >&2
  exit 1
fi

printf '%s\n' "$section"
