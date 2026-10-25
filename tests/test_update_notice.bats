#!/usr/bin/env bats
# The output helper is pure: no installer, HOME change, or service manager.
setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  SKILL="$BATS_TEST_TMPDIR/install with spaces"
  mkdir -p "$SKILL"
  sed -n '/^agmsg_install_update_reading_hint() {/,/^}/p' "$REPO/install.sh" > "$BATS_TEST_TMPDIR/hint.sh"
}

@test "update: fixed reading instruction fills the release version and installation paths" {
  local version
  for version in 1.6.0 1.6.1-rc.1; do
    run /bin/bash -euo pipefail -c 'source "$1"; agmsg_install_update_reading_hint "$2" "$3"' _ "$BATS_TEST_TMPDIR/hint.sh" "$SKILL" "$version"
    [ "$status" -eq 0 ]
    [ "$output" = "agmsg was updated to $version. This session still has the old skill loaded. Re-read \"$SKILL/SKILL.md\", read the $version section of \"$SKILL/CHANGELOG.md\", and tell the user what changed and which settings it recommends." ]
  done
}

@test "update: final output prints the reading instruction after Update complete" {
  local tail="$BATS_TEST_TMPDIR/update-tail.sh"
  sed -n '/^  echo "  ✓ Update complete"/,/^  exit 0/p' "$REPO/install.sh" > "$tail"
  run /bin/bash -euo pipefail -c 'source "$1"; SKILL_DIR="$2"; SCRIPT_DIR="$3"; INSTALLED_VERSION=provenance-test; source "$4"' _ "$BATS_TEST_TMPDIR/hint.sh" "$SKILL" "$REPO" "$tail"
  [ "$status" -eq 0 ]
  grep -Fq 'Update complete' <<< "$output"
  grep -Fq "agmsg was updated to $(cat "$REPO/VERSION")" <<< "$output"
  grep -Fq "$SKILL/SKILL.md" <<< "$output"
  grep -Fq "$SKILL/CHANGELOG.md" <<< "$output"
}

@test "update: the npm files list already ships CHANGELOG.md" {
  run node -e 'const p=require(process.argv[1]); if (!p.files.includes("CHANGELOG.md")) process.exit(1);' "$REPO/package.json"
  [ "$status" -eq 0 ]
}
