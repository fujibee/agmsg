#!/usr/bin/env bats

@test "agmsgd db: schema is idempotent, readOnly never migrates or writes, transactions roll back on throw" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_db.test.mjs"
  [ "$status" -eq 0 ]
}
