#!/usr/bin/env bats

# The sync engine outlives the command that starts it, so every descriptor it
# inherits it holds for as long as it runs. Under bats that included fd 144 --
# a descriptor internal to the harness -- and the shard then ran to the CI job's
# cap with every test already reported ok, because bats was waiting for an EOF
# the engine was keeping from arriving.
#
# Captured from a hung macOS shard: the engine and three bats processes all held
# the same pipe, 0xc9aea28a590ca110, at fd 144.
#
#   node .../remote-sync.mjs   fd 144  PIPE 0xc9aea28a590ca110   (ppid 1)
#   bats ...                   fd 144  PIPE 0xc9aea28a590ca110
#   bats ...                   fd 144  PIPE 0xc9aea28a590ca110
#   bats-format-cat            fd 144  PIPE 0xc9aea28a590ca110

setup() {
  SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
  WORK="$(mktemp -d)"
  FD_REPORT="$WORK/fds.txt"
  export FD_REPORT
  # Stands in for node. It reports its descriptors to a file, because command
  # substitution rearranges descriptors itself and that is the thing being
  # measured, and it also speaks over all three standard streams so a close that
  # went too far shows up as silence rather than as a passing test.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'ls /dev/fd > "$FD_REPORT" 2>/dev/null'
    printf '%s\n' 'echo MARKER-OUT'
    printf '%s\n' 'echo MARKER-ERR >&2'
    printf '%s\n' 'cat > "$FD_REPORT.stdin"'
  } > "$WORK/fake-node"
  chmod +x "$WORK/fake-node"
  export AGMSG_NODE="$WORK/fake-node"
  export AGMSG_STORAGE_PATH="$WORK/store"
  mkdir -p "$AGMSG_STORAGE_PATH"
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

@test "the engine does not inherit descriptors the harness opened" {
  # 144 is the number seen in the captured hang; 77 is arbitrary, so passing
  # cannot come from something particular about 144. A closed descriptor is not
  # reissued at its old number -- reuse takes the lowest free one -- so absence
  # here is meaningful.
  bash "$SCRIPTS/remote-sync.sh" probe 144>/dev/null 77>/dev/null \
    </dev/null >/dev/null 2>/dev/null || true

  # That the stand-in ran at all: with an empty report every "absent" assertion
  # below would hold for the wrong reason.
  [ -s "$FD_REPORT" ]

  run grep -qx 144 "$FD_REPORT"
  [ "$status" -ne 0 ]
  run grep -qx 77 "$FD_REPORT"
  [ "$status" -ne 0 ]
}

@test "the three standard streams still reach the engine" {
  # The close is by range above stderr, and this is what stops that range from
  # creeping downwards. Asserted by using the streams, not by listing them: a
  # closed 0/1/2 is immediately reissued to whatever opens next, so a listing
  # shows all three either way and cannot tell the two cases apart. An earlier
  # revision of this file asserted exactly that and passed while the code
  # closed all three.
  printf 'ping\n' | bash "$SCRIPTS/remote-sync.sh" probe \
    > "$WORK/out.txt" 2> "$WORK/err.txt" || true

  grep -qx MARKER-OUT "$WORK/out.txt"
  grep -qx MARKER-ERR "$WORK/err.txt"
  grep -qx ping "$FD_REPORT.stdin"
}
