#!/usr/bin/env bats
# changelog-section.sh prints one version's CHANGELOG.md section, which is the
# GitHub Release body for a stable tag.

load test_helper
bats_require_minimum_version 1.5.0
SCRIPT="${BATS_TEST_DIRNAME}/../scripts/release/changelog-section.sh"
CHANGELOG="${BATS_TEST_DIRNAME}/../CHANGELOG.md"

has() { printf '%s\n' "$output" | grep -qF -- "$1"; }
ends_with() { [ "$(printf '%s\n' "$output" | tail -n 1)" = "$1" ]; }

setup() {
  F="$BATS_TEST_TMPDIR/CHANGELOG.md"
  cat > "$F" <<'X'
# Changelog

## [2.0.0] - 2026-01-02

### Fixed
- thing two (#2)

[2.0.0]: https://example.invalid/compare/v1.0.0...v2.0.0

## [1.0.0] - 2026-01-01

### Added
- thing one (#1)

[1.0.0]: https://example.invalid/compare/v0.9.0...v1.0.0

## [0.9.0] - 2025-12-01

## [0.8.0] - 2025-11-01

### Added
- old
X
}

@test "prints the heading through the compare link, nothing from the next section" {
  run bash "$SCRIPT" 2.0.0 "$F"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "## [2.0.0] - 2026-01-02" ]
  has "thing two (#2)"
  ends_with "[2.0.0]: https://example.invalid/compare/v1.0.0...v2.0.0"
  refute has "thing one"
}

@test "the last section runs to the end of the file" {
  run bash "$SCRIPT" 0.8.0 "$F"
  [ "$status" -eq 0 ]
  ends_with "- old"
}

@test "a version with no section fails with the reason and prints nothing" {
  run --separate-stderr bash "$SCRIPT" 3.0.0 "$F"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -qF 'no "## [3.0.0]" section'
}

@test "a heading-only section is empty and fails" {
  run --separate-stderr bash "$SCRIPT" 0.9.0 "$F"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -qF "is empty"
}

@test "1.0 does not match 1.0.0 or 10.0.0 by prefix" {
  run bash "$SCRIPT" 1.0 "$F"
  [ "$status" -eq 1 ]
}

@test "a missing file and a missing argument fail" {
  run bash "$SCRIPT" 1.0.0 "$BATS_TEST_TMPDIR/none.md"
  [ "$status" -eq 1 ]
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "the repository CHANGELOG yields the 1.8.0 and 1.7.4 sections" {
  run bash "$SCRIPT" 1.8.0 "$CHANGELOG"
  [ "$status" -eq 0 ]
  has "(#1979)"
  has "(#1982)"
  ends_with "[1.8.0]: https://github.com/fujibee/agmsg/compare/v1.7.4...v1.8.0"
  refute has "1.7.4] - "
  run bash "$SCRIPT" 1.7.4 "$CHANGELOG"
  [ "$status" -eq 0 ]
  has "(#1975)"
  ends_with "[1.7.4]: https://github.com/fujibee/agmsg/compare/v1.7.3...v1.7.4"
  refute has "(#1979)"
}

@test "release.yml extracts the section before npm publish, so a bad section stops before anything is public" {
  W="${BATS_TEST_DIRNAME}/../.github/workflows/release.yml"
  extract=$(grep -n 'changelog-section.sh "\$VERSION"' "$W" | head -n 1 | cut -d: -f1)
  publish=$(grep -n 'npm publish --access public' "$W" | head -n 1 | cut -d: -f1)
  [ -n "$extract" ]
  [ -n "$publish" ]
  [ "$extract" -lt "$publish" ]
}

@test "release.yml feeds RELEASE_NOTES.md from the script for a stable tag" {
  grep -q 'changelog-section.sh "\$VERSION" CHANGELOG.md > RELEASE_NOTES.md' \
    "${BATS_TEST_DIRNAME}/../.github/workflows/release.yml"
}
