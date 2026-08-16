#!/usr/bin/env bats

# The release workflow decides npm's dist-tag from the version string (#663).
#
# Without it, `npm publish` has no --tag and npm reads nothing from the version
# on its own: `v1.2.0-rc.1` would publish as `latest`, and the next
# `npm i -g agmsg` anywhere would install the release candidate. When this was
# written `npm view agmsg dist-tags` was `{ latest: 1.1.13 }` and nothing else,
# so a prerelease had no other tag to land on.
#
# The derivation is RUN here, not described: the block is lifted out of the
# workflow and evaluated, so the rule has one home. A copy of the condition in
# this file would pass forever after someone edited the workflow's copy.
#
# What is only pinned structurally is the wiring — which step exports the
# output and which flag consumes it — because that part is YAML, not shell.

WORKFLOW="${BATS_TEST_DIRNAME}/../.github/workflows/release.yml"

# The `if` that sets dist_tag, taken from the workflow itself.
#
# `.version` rather than an escaped `$version` in the pattern: awk would need
# the dollar escaped, and the escape behaves differently across the GNU and BSD
# awks this suite runs on. Matching any character there costs nothing.
extract_derivation() {
  awk '/if \[\[ ".version" == \*-\* \]\]; then/,/^ *fi$/' "$WORKFLOW"
}

# What the workflow would write to GITHUB_OUTPUT for a given version.
dist_tag_for() {
  local version="$1"
  local block
  block="$(extract_derivation)"
  # A positive control. If the workflow is reformatted so the range stops
  # matching, every case below would evaluate an empty string and read the
  # tag as empty — which must be a failure, not a quiet pass.
  [ -n "$block" ]
  GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh_output"
  : > "$GITHUB_OUTPUT"
  export GITHUB_OUTPUT
  eval "$block"
  sed -n 's/^dist_tag=//p' "$GITHUB_OUTPUT"
}

@test "release: the derivation is present and lifts out of the workflow" {
  # Stated separately from the cases so a failure says WHICH half broke: a
  # missing derivation and a wrong one are different repairs.
  run extract_derivation
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"dist_tag=next"* ]]
  [[ "$output" == *"dist_tag=latest"* ]]
}

@test "release: a plain version publishes as latest" {
  [ "$(dist_tag_for 1.2.3)" = "latest" ]
  [ "$(dist_tag_for 10.0.0)" = "latest" ]
}

@test "release: any prerelease publishes as next, not latest" {
  # rc is the one being cut, but the rule is the hyphen, so the others have to
  # hold too — a rule that only works for the spelling in front of us is the
  # kind that admits the next one silently.
  [ "$(dist_tag_for 1.2.0-rc.1)" = "next" ]
  [ "$(dist_tag_for 1.2.0-beta.1)" = "next" ]
  [ "$(dist_tag_for 1.2.0-alpha)" = "next" ]
  [ "$(dist_tag_for 2.0.0-0)" = "next" ]
}

@test "release: publish consumes the derived tag, and keeps provenance" {
  # --tag without the export is a publish under an empty tag; the export
  # without --tag is what this issue was. Both halves, or neither means
  # anything.
  grep -q 'DIST_TAG: ${{ steps.ver.outputs.dist_tag }}' "$WORKFLOW"
  grep -q 'npm publish --access public --provenance --tag "\$DIST_TAG"' "$WORKFLOW"
}

@test "release: provenance is not dropped the way the private copy dropped it" {
  # `run` + status, not a bare `!`: bats enables set -e for the body, which
  # exempts a negated command, so a bare `! grep` would not abort and only the
  # last statement's status would decide the test.
  #
  # The private copy of this workflow publishes without --provenance because
  # provenance attests against a PUBLIC source repository and that one is not.
  # This one is. The reason is inverted, not shared, so it must not travel back
  # with the dist-tag it was sitting next to.
  run grep -q 'npm publish --access public --tag' "$WORKFLOW"
  [ "$status" -ne 0 ]
}

@test "release: a prerelease is not the repository's latest release either" {
  # The same decision on the other surface. `gh release create` marks whatever
  # it makes as latest unless told otherwise, so an rc would sit on the front
  # page as the current release while npm correctly served 1.1.13.
  grep -q 'if \[ "\$DIST_TAG" != latest \]; then prerelease=--prerelease; fi' "$WORKFLOW"
  grep -q '\${prerelease:+"\$prerelease"}' "$WORKFLOW"
}

@test "release: the prerelease flag survives set -u, both ways" {
  # Run, not asserted about. The private copy builds this as an array, and
  # expanding an EMPTY array is an unbound variable under `set -u` in bash
  # 3.2 — the release step is the last place to discover that. The runner
  # does not set -u today; this holds whether or not that stays true.
  #
  # bash, explicitly: this must hold under the oldest shell CI runs (macOS
  # /bin/bash is 3.2), not under whatever the developer's login shell is.
  run bash -euo pipefail -c '
    DIST_TAG=latest
    prerelease=
    if [ "$DIST_TAG" != latest ]; then prerelease=--prerelease; fi
    set -- create v1 ${prerelease:+"$prerelease"}
    echo "$#"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  run bash -euo pipefail -c '
    DIST_TAG=next
    prerelease=
    if [ "$DIST_TAG" != latest ]; then prerelease=--prerelease; fi
    set -- create v1 ${prerelease:+"$prerelease"}
    echo "$# $3"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "3 --prerelease" ]
}

@test "release: the version guard this sits next to is untouched" {
  # Not in scope, and worth a line: the derivation was inserted into the step
  # that already refuses a tag disagreeing with VERSION, and inserting it
  # there must not have displaced that refusal.
  grep -q 'Tag ($version) does not match VERSION file' "$WORKFLOW"
  guard_line="$(grep -n 'does not match VERSION file' "$WORKFLOW" | head -1 | cut -d: -f1)"
  derive_line="$(grep -n 'dist_tag=next' "$WORKFLOW" | head -1 | cut -d: -f1)"
  [ -n "$guard_line" ]
  [ -n "$derive_line" ]
  # The guard exits non-zero before anything is derived for a tag that should
  # not be releasing at all.
  [ "$guard_line" -lt "$derive_line" ]
}
