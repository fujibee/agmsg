#!/usr/bin/env bats

# bump-app-version.sh derives its ROOT from the script's own location
# ($(dirname)/../..), so we exercise it against a temp tree: a copy of the real
# script under <tmp>/scripts/release/ plus fixture version files under <tmp>/app.
# This keeps the test from mutating the real repo's version files.

setup() {
  BUMP_ROOT="$(mktemp -d)"
  mkdir -p "$BUMP_ROOT/scripts/release" "$BUMP_ROOT/app/src-tauri"
  cp "${BATS_TEST_DIRNAME}/../scripts/release/bump-app-version.sh" "$BUMP_ROOT/scripts/release/"
  BUMP="$BUMP_ROOT/scripts/release/bump-app-version.sh"

  printf '{\n  "productName": "agmsg",\n  "version": "0.1.3"\n}\n' \
    > "$BUMP_ROOT/app/src-tauri/tauri.conf.json"
  printf '{\n  "name": "agmsg-app",\n  "version": "0.1.3"\n}\n' \
    > "$BUMP_ROOT/app/package.json"
  printf '[package]\nname = "agmsg-app"\nversion = "0.1.3"\nedition = "2021"\n\n[dependencies]\nserde = "1"\n' \
    > "$BUMP_ROOT/app/src-tauri/Cargo.toml"
  # An unrelated package precedes agmsg-app so we can prove only the app entry moves.
  printf '[[package]]\nname = "other"\nversion = "9.9.9"\n\n[[package]]\nname = "agmsg-app"\nversion = "0.1.3"\ndependencies = []\n' \
    > "$BUMP_ROOT/app/src-tauri/Cargo.lock"
  printf 'v1.1.6\n' > "$BUMP_ROOT/app/AGMSG_CORE_REF"
}

teardown() { rm -rf "$BUMP_ROOT"; }

@test "bump-app-version: rejects a v/app-v prefixed version" {
  run bash "$BUMP" app-v0.1.4
  [ "$status" -ne 0 ]
  [[ "$output" == *"bare semver"* ]]
  run bash "$BUMP" v0.1.4
  [ "$status" -ne 0 ]
}

@test "bump-app-version: rejects a non-semver version" {
  run bash "$BUMP" 1.2
  [ "$status" -ne 0 ]
  [[ "$output" == *"semver"* ]]
}

@test "bump-app-version: requires a version argument" {
  run bash "$BUMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "bump-app-version: bumps all four version files to the new version" {
  run bash "$BUMP" 0.1.4
  [ "$status" -eq 0 ]
  grep -q '"version": "0.1.4"' "$BUMP_ROOT/app/src-tauri/tauri.conf.json"
  grep -q '"version": "0.1.4"' "$BUMP_ROOT/app/package.json"
  grep -q '^version = "0.1.4"' "$BUMP_ROOT/app/src-tauri/Cargo.toml"
  # the agmsg-app lock entry moves; an unrelated package's version must not.
  run grep -A1 'name = "agmsg-app"' "$BUMP_ROOT/app/src-tauri/Cargo.lock"
  [[ "$output" == *'version = "0.1.4"'* ]]
  run grep -A1 'name = "other"' "$BUMP_ROOT/app/src-tauri/Cargo.lock"
  [[ "$output" == *'version = "9.9.9"'* ]]
}

@test "bump-app-version: surfaces the agmsg-core pin for confirmation" {
  run bash "$BUMP" 0.1.4
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGMSG_CORE_REF=v1.1.6"* ]]
}
