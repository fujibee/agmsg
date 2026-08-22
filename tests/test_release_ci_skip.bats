#!/usr/bin/env bats

# #875. A release PR's whole diff is the version bump, and the workflow treats
# those files as safe to skip the bash suite for. That is only true while the
# two lists agree: the files `cut-release.sh` actually commits, and the files
# the workflow calls safe.
#
# They live in different files and nothing connects them, so this does. Adding a
# file to the release commit without classifying it is the failure that would
# otherwise skip the suite for something nobody measured -- silently, and only
# on release branches, which is where it would be noticed last.

load test_helper

CUT="$BATS_TEST_DIRNAME/../scripts/release/cut-release.sh"
WORKFLOW="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

# The set cut-release.sh commits: its FILES variable, including the CHANGELOG
# line it appends for a non-prerelease. Read from the script rather than
# restated here, or this test would be a third copy of the same list.
release_files() {
  local base extra
  base=$(grep -E '^FILES="[^"]+"$' "$CUT" | head -1 | sed 's/^FILES="//; s/"$//')
  extra=$(grep -E '^  FILES="\$FILES [^"]+"$' "$CUT" | head -1 | sed 's/^  FILES="\$FILES //; s/"$//')
  printf '%s\n' $base $extra | sort -u
}

# The set the workflow calls safe, from the two case arms that name them.
workflow_safe_files() {
  {
    grep -oE '^ +VERSION\|package\.json\|\.claude-plugin/plugin\.json\) ;;' "$WORKFLOW" \
      | sed 's/) ;;//' | tr '|' '\n'
    grep -oE '^ +README\.md\|CHANGELOG\.md\|[A-Za-z.|]+\) ;;' "$WORKFLOW" \
      | sed 's/) ;;//' | tr '|' '\n'
  } | sed 's/^ *//' | grep -v '^$' | sort -u
}

@test "release-ci: every file cut-release.sh commits is classified in the workflow" {
  local f missing=""
  # The premise: both readers found something. An empty set on either side would
  # make the comparison below vacuously pass.
  [ -n "$(release_files)" ]
  [ -n "$(workflow_safe_files)" ]

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! printf '%s\n' "$(workflow_safe_files)" | grep -qxF -- "$f"; then
      missing="${missing}${missing:+, }$f"
    fi
  done < <(release_files)
  [ -z "$missing" ] || {
    echo "cut-release.sh commits these, and the workflow does not classify them: $missing" >&2
    echo "Either add them to the safe arm in tests.yml, or -- if the suite reads them --" >&2
    echo "leave them out and this skip no longer applies to a release PR." >&2
    false
  }
}

@test "release-ci: the reader sees cut-release.sh's real list, not an empty one" {
  # A control for the test above: without it, a rename of FILES would leave
  # release_files empty and the comparison would pass while checking nothing.
  local files
  files="$(release_files)"
  printf '%s\n' "$files" | grep -qxF VERSION
  printf '%s\n' "$files" | grep -qxF CHANGELOG.md
  printf '%s\n' "$files" | grep -qxF package.json
  printf '%s\n' "$files" | grep -qxF .claude-plugin/plugin.json
}
