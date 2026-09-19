#!/usr/bin/env bats

@test "Stage-1 sync engine protocol and security boundaries" {
  umask 0002
  run node --test "$BATS_TEST_DIRNAME/remote_sync_engine.test.mjs"
  [ "$status" -eq 0 ]
}
