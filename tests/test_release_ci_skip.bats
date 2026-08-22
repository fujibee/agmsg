#!/usr/bin/env bats

# #875. A release PR's whole diff is the version bump, and the workflow skips the
# heavy steps for it. What has to hold is not a list -- it is the DECISION: the
# light path only when the diff is entirely inside that set, and the full matrix
# the moment anything else rides along.
#
# Drift in the list itself falls to the safe side. A release that starts touching
# a fifth file puts that file outside the set, which forces the full run: slower,
# not wrong. So there is nothing to pin there, and an earlier version of this
# file pinned it anyway -- comparing the workflow's list against cut-release.sh's
# -- which guarded the direction that cannot hurt and left the one that can
# (a file in the set later becoming something the suite reads) uncovered by both.
# That one is not a drift a test can see; it is a fact measured once, recorded in
# the workflow's own comment, and re-measured by whoever adds such a test.
#
# This runs the workflow's real detect logic rather than restating it, because a
# restatement is a second implementation that can agree with itself while
# disagreeing with CI.

load test_helper

WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
BUMP=$'VERSION\npackage.json\n.claude-plugin/plugin.json\nCHANGELOG.md'

# Lift the detect step out of the workflow, with its file-list read replaced by
# one this test supplies. The anchors are asserted rather than assumed: if either
# moves, this fails loudly instead of silently testing an empty script.
detect() {
  local script="$BATS_TEST_TMPDIR/detect.sh" start end
  start=$(grep -n 'changed=\$(git diff --name-only' "$WORKFLOW" | head -1 | cut -d: -f1)
  end=$(grep -n 'echo "docs_only=\$docs_only" >> "\$GITHUB_OUTPUT"' "$WORKFLOW" | head -1 | cut -d: -f1)
  [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$start" ]
  { echo 'set -euo pipefail'
    sed -n "${start},$((end - 1))p" "$WORKFLOW" \
      | sed 's/^          //' \
      | sed 's|changed=\$(git diff --name-only "\$BASE_SHA\.\.\.\$HEAD_SHA")|changed="$CHANGED"|'
  } > "$script"
  CHANGED="$1" GITHUB_OUTPUT=/dev/null bash "$script" 2>&1 | sed -n 's/^Result: //p'
}

@test "release-ci: the harness runs the real logic and can say either answer" {
  # Without this, every assertion below could be passing on an empty script.
  [[ "$(detect "$BUMP")" == *"docs_only=true"* ]]
  [[ "$(detect 'scripts/lib/storage.sh')" == *"docs_only=false"* ]]
}

@test "release-ci: the version bump alone takes the light path (#875)" {
  [[ "$(detect "$BUMP")" == *"docs_only=true"* ]]
}

# A SUBSET is on the light path too, and that is not incidental. cut-release.sh
# leaves CHANGELOG.md out for a prerelease, so a prerelease PR's diff is three
# files, and a rule that required all four would never fire for one. The `changes`
# job classifies each changed file on its own, which gives the subset behaviour
# for free -- this records that it is the intended behaviour rather than a side
# effect nobody chose.
@test "release-ci: a prerelease bump without CHANGELOG.md still takes the light path (#875)" {
  local prerelease=$'VERSION\npackage.json\n.claude-plugin/plugin.json'
  [[ "$(detect "$prerelease")" == *"docs_only=true"* ]]
}

@test "release-ci: anything riding along with the bump forces the full matrix (#875)" {
  local extra
  for extra in scripts/lib/storage.sh tests/test_remote.bats SKILL.md cliff.toml; do
    run detect "$BUMP"$'\n'"$extra"
    # `grep`, not `[[ ]]`: a non-last `[[ ]]` cannot fail under errexit on bash
    # 3.2, and this one is inside a loop.
    grep -qF 'docs_only=false' <<<"$output" || {
      echo "a diff of the version bump plus '$extra' took the light path" >&2
      false
    }
  done
}
