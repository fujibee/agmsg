#!/usr/bin/env bats
# The shared install fixtures, through `npx agmsg addon check`. The app's Rust
# installer runs the same corpus (app/src-tauri/src/addons/install).

@test "addon check refuses and accepts exactly what the shared fixtures say" {
  command -v node >/dev/null || skip "node is needed"
  run node "$BATS_TEST_DIRNAME/addon_fixtures_runner.js"
  echo "$output"
  [ "$status" -eq 0 ]
}
