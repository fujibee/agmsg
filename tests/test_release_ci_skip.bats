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

# The dangerous direction, and the one the cases below cannot see.
#
# Those cases name the files that ride along, so they catch the arm getting
# NARROWER. They cannot catch it getting WIDER: adding `scripts/foo.sh` to the
# arm leaves every one of them green, because none of them happens to be about
# `scripts/foo.sh`. Measured, not assumed -- an earlier version of this file had
# exactly that hole and stayed green through the mutation.
#
# A widening is what actually hurts: it skips the suite for a file nobody
# measured. So the arm's contents are pinned literally. Anything added has to be
# added here too, which is where someone reads why the set is what it is.
@test "release-ci: the release arm names these files and no others (#875)" {
  local arm expected
  arm=$(grep -oE '^ +VERSION\|[^)]*\) ;;' "$WORKFLOW" | sed 's/) ;;$//; s/^ *//' | tr '|' '\n' | sort)
  expected=$(printf '%s\n' VERSION package.json .claude-plugin/plugin.json | sort)
  # The premise: the grep found the arm at all. An empty match would make the
  # comparison below a comparison of two things that are not there.
  [ -n "$arm" ]
  [ "$arm" = "$expected" ] || {
    echo "the release arm in tests.yml is not what this test expects." >&2
    echo "found:    $(printf '%s ' $arm)" >&2
    echo "expected: $(printf '%s ' $expected)" >&2
    echo "Widening it skips the bash suite for a file nobody has measured." >&2
    echo "If the addition is right, measure that the suite does not read it," >&2
    echo "record that measurement in the workflow comment, and update this test." >&2
    false
  }
}

# CHANGELOG.md is deliberately NOT in that arm -- it was already classified with
# the other top-level prose before this change, and a release just happens to
# touch it too. Its arm is not pinned here: it predates this work, and pinning
# every safe arm in the file is a different change from adding one.
@test "release-ci: the harness runs the real logic and can say either answer" {
  # Without this, every assertion below could be passing on an empty script.
  # `grep -q`, never `[[ ]]`. A non-last `[[ ]]` cannot fail under errexit on
  # bash 3.2, and "last" is a property of where a line happens to sit, not of
  # what it asserts -- one appended line below would silently disarm it. CI's
  # enforced-assertions check caught exactly that here, in the PR whose subject
  # is a checker that could not see the direction that hurts.
  grep -q 'docs_only=true' <<<"$(detect "$BUMP")"
  grep -q 'docs_only=false' <<<"$(detect 'scripts/lib/storage.sh')"
}

@test "release-ci: the version bump alone takes the light path (#875)" {
  grep -q 'docs_only=true' <<<"$(detect "$BUMP")"
}

# A SUBSET is on the light path too, and that is not incidental. cut-release.sh
# leaves CHANGELOG.md out for a prerelease, so a prerelease PR's diff is three
# files, and a rule that required all four would never fire for one. The `changes`
# job classifies each changed file on its own, which gives the subset behaviour
# for free -- this records that it is the intended behaviour rather than a side
# effect nobody chose.
@test "release-ci: a prerelease bump without CHANGELOG.md still takes the light path (#875)" {
  local prerelease=$'VERSION\npackage.json\n.claude-plugin/plugin.json'
  grep -q 'docs_only=true' <<<"$(detect "$prerelease")"
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
