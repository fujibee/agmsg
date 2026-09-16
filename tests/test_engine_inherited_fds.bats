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

# Reports its OWN descriptors above stderr. A stand-in that shells out to `ls`
# would add that child's directory descriptor to the count; this one adds
# nothing the baseline below does not also see.
_write_self_reporter() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' ': > "$FD_REPORT"'
    printf '%s\n' 'for f in /dev/fd/*; do'
    printf '%s\n' '  n="${f##*/}"'
    printf '%s\n' '  case "$n" in ""|*[!0-9]*) continue ;; esac'
    printf '%s\n' '  [ "$n" -gt 2 ] && printf "%s " "$n" >> "$FD_REPORT"'
    printf '%s\n' 'done'
  } > "$1"
  chmod +x "$1"
}

@test "the engine does not inherit descriptors the harness opened" {
  # Run under EVERY bash on this machine, because they disagree. bash 3.2 --
  # /bin/bash on macOS, and what runs this on the macOS runner -- relocates
  # descriptors into the range at and above 10 while processing an exec's
  # redirections, so a close 5.x honours can come back to the child at a new
  # number. A single-shell version of this test stayed green through exactly
  # that regression while a CI shard hung.
  #
  # Compared against a BASELINE rather than against named numbers: what 3.2
  # leaves behind is renumbered, so asserting "144 and 77 are absent" cannot
  # see it. The baseline is the stand-in's own descriptors, measured with
  # nothing inherited to lose; anything beyond that came through the close.
  local reporter="$WORK/self-report"
  _write_self_reporter "$reporter"
  export AGMSG_NODE="$reporter"

  local sh found=0
  for sh in /bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash "$(command -v bash)"; do
    [ -x "$sh" ] || continue
    found=$((found + 1))

    : > "$FD_REPORT"
    "$sh" "$SCRIPTS/remote-sync.sh" probe </dev/null >/dev/null 2>/dev/null || true
    local baseline; baseline="$(cat "$FD_REPORT")"

    # Pipes, not files: the relocation only shows up on pipes, which is what a
    # harness holds. 143 is the shape seen in the captured hang; 10 is low and
    # arbitrary, so a pass cannot come from something particular about 143.
    : > "$FD_REPORT"
    (
      exec 143> >(sleep 20)
      exec 10> >(sleep 20)
      "$sh" "$SCRIPTS/remote-sync.sh" probe </dev/null >/dev/null 2>/dev/null || true
    )
    local measured; measured="$(cat "$FD_REPORT")"

    [ -n "$baseline$measured" ] || { echo "$sh: the stand-in never ran"; false; }
    [ "$baseline" = "$measured" ] || {
      echo "$sh ($("$sh" --version 2>/dev/null | head -1))"
      echo "  baseline [$baseline]  measured [$measured]"
      false
    }
  done
  [ "$found" -gt 0 ]
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

# The mock remote server has the same shape as the engine above: a test
# backgrounds it and it runs until killed, so any harness descriptor it inherits
# and never closes it holds for the life of the shard. Under a parallel bats run
# that was the harness's own high pipes -- measured, fd 143 and 146, held by six
# survivors -- and bats then waited forever for an EOF the mock kept from
# arriving, hanging the shard with every test already ok (#1107). The start sites
# close fd 3 by name (`3>&-`), which never reaches 143/146; the mock closes the
# range itself, mirroring the engine. Measured against a baseline, the descriptor
# the listing opens appears in both and cancels; only a surviving inherited fd
# shows as a difference.
@test "the mock remote server does not inherit descriptors the harness opened (#1107)" {
  local mock="$BATS_TEST_DIRNAME/helpers/mock_remote_server.py"
  local py="${MOCK_PYTHON3:-$(command -v python3 || true)}"
  [ -n "$py" ] || skip "python3 not on PATH"

  # Baseline: nothing beyond 0/1/2 inherited.
  MOCK_FD_REPORT="$WORK/fd-base" "$py" "$mock" 0 \
    </dev/null >"$WORK/base.port" 2>/dev/null 3>&- &
  local bpid=$! i
  for i in $(seq 1 100); do [ -s "$WORK/fd-base" ] && break; sleep 0.1; done
  kill "$bpid" 2>/dev/null || true; wait "$bpid" 2>/dev/null || true
  local baseline; baseline="$(cat "$WORK/fd-base" 2>/dev/null)"

  # Measured: high pipes inherited, exactly what the `3>&-` at each start site
  # leaves open. The numbers are the ones the captured hang held; the assertion is
  # only that a high inherited pipe does not survive into the server.
  (
    exec 143> >(cat >/dev/null) 146> >(cat >/dev/null)
    MOCK_FD_REPORT="$WORK/fd-meas" "$py" "$mock" 0 \
      </dev/null >"$WORK/meas.port" 2>/dev/null 3>&- &
    mpid=$!
    for i in $(seq 1 100); do [ -s "$WORK/fd-meas" ] && break; sleep 0.1; done
    kill "$mpid" 2>/dev/null || true; wait "$mpid" 2>/dev/null || true
  )
  local measured; measured="$(cat "$WORK/fd-meas" 2>/dev/null)"

  [ -n "$baseline$measured" ] || { echo "the report never appeared"; false; }
  [ "$baseline" = "$measured" ] || {
    echo "baseline [$baseline]  measured [$measured]"
    false
  }
  if grep -qxE '143|146' <<<"$measured"; then
    echo "an inherited harness pipe survived into the server: [$measured]"
    false
  fi
}
