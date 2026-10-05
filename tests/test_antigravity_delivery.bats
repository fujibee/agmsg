#!/usr/bin/env bats

load test_helper

# The Node fixtures create their own stores and processes. Use the common
# sandbox too so they cannot inherit a developer's HOME or terminal identity.
setup() { setup_test_env; }
teardown() { teardown_test_env; }

@test "Antigravity delivery: stream, TUI, protected claims and recovery" {
  run node --test --test-concurrency=1 \
    "$BATS_TEST_DIRNAME/antigravity_claims.test.mjs" \
    "$BATS_TEST_DIRNAME/antigravity_bridge.test.mjs" \
    "$BATS_TEST_DIRNAME/antigravity_tui_supervisor.test.mjs"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
