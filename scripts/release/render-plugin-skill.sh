#!/usr/bin/env bash
set -euo pipefail

# render-plugin-skill.sh [output] -- regenerate the repo-root SKILL.md.
#
# The Claude Code plugin marketplace declares "source": "./", so it copies this
# repository tree verbatim into ~/.claude/plugins/cache/ and never runs
# agmsg_render_skill. The repo-root SKILL.md is therefore a shipped artifact of
# its own (#1286), and it must be a rendered file, not the template:
#
#   SKILL.md  =  render(scripts/skill-base.md, claude-code, agmsg)
#                with scripts/skill-plugin-step0.md inserted right after the
#                render-root marker
#
# The plugin is Claude Code by definition, hence the fixed type and name. The
# first-run bootstrap (Step 0) belongs to this file ONLY: install.sh renders the
# same base through agmsg_render_skill directly, so nothing installed carries it.
#
# Run this after changing scripts/skill-base.md, the claude-code overlay, or
# scripts/skill-plugin-step0.md, and commit the result. tests/test_install.bats
# fails when the committed file differs from this script's output.
#
# Usage: scripts/release/render-plugin-skill.sh            # rewrite ./SKILL.md
#        scripts/release/render-plugin-skill.sh <path>     # write elsewhere (tests)

die() { echo "render-plugin-skill: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$REPO_ROOT/SKILL.md}"
STEP0="$REPO_ROOT/scripts/skill-plugin-step0.md"
ROOT_MARKER='<!-- agmsg:render-root -->'

[ -s "$STEP0" ] || die "missing or empty: $STEP0"

# agmsg_render_skill reads its base from $SCRIPT_DIR/scripts/skill-base.md.
SCRIPT_DIR="$REPO_ROOT"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/scripts/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/scripts/lib/skill-render.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/render-plugin-skill.XXXXXX")"
trap 'rm -rf "$work"' EXIT

agmsg_render_skill claude-code agmsg "$work/rendered.md" || die "render failed"

# The marker line is followed by a blank line in the base; the step goes between
# that blank line and the text after it, so the layout is
#   marker / blank / step 0 / blank / first paragraph.
awk -v step0="$STEP0" -v marker="$ROOT_MARKER" '
  { print }
  $0 == marker && !done {
    print ""
    while ((getline line < step0) > 0) print line
    done = 1
  }
  END { if (!done) exit 1 }
' "$work/rendered.md" > "$work/final.md" || die "render-root marker not found in the rendered file"

mv -f "$work/final.md" "$OUT"
echo "render-plugin-skill: wrote $OUT"
