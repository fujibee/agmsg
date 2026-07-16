#!/usr/bin/env bats

BIN="$BATS_TEST_DIRNAME/../bin/agmsg.js"

@test "bin/agmsg.js: --version exits successfully" {
  run node "$BIN" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg bootstrapper" ]]
}

@test "bin/agmsg.js: --help exits successfully" {
  run node "$BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "npm bootstrapper for cross-agent messaging" ]]
}

@test "bin/agmsg.js: toBashPath converts backslashes to forward slashes (#262)" {
  run node -e 'const { toBashPath } = require(process.argv[1]); const input = String.raw`C:\Users\me\AppData\Local\Temp\agmsg-bootstrap-abc123\setup.sh`; const expected = "C:/Users/me/AppData/Local/Temp/agmsg-bootstrap-abc123/setup.sh"; if (toBashPath(input) !== expected) process.exit(1);' "$BIN"
  [ "$status" -eq 0 ]
}

@test "bin/agmsg.js: toBashPath is a no-op on POSIX paths" {
  run node -e 'const { toBashPath } = require(process.argv[1]); const p = "/tmp/agmsg-bootstrap-abc123/setup.sh"; if (toBashPath(p) !== p) process.exit(1);' "$BIN"
  [ "$status" -eq 0 ]
}
