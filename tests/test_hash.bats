#!/usr/bin/env bats
#
# agmsg_sha256's fallback chain, exercised by taking the tools away.
#
# This suite is unusual for a portability fix and worth saying why: the bug it
# covers (#861) is `shasum` missing from Git for Windows' Git Bash, and yet
# NOTHING here needs Windows. The behaviour that broke is selected by
# `command -v`, so a PATH holding only the tools we choose reproduces each
# platform's choice exactly, on any platform. Where a capability branch is
# probed rather than switched on an OS name, the probe is the thing to drive.
#
# Every case asserts the same LITERAL digest rather than "the arms agree with
# each other". Three arms that agree could agree on a wrong answer; the literal
# says each one computes SHA-256.

load test_helper

# printf '%s' agmsg | sha256sum
readonly AGMSG_SHA256=5d2d1e5ffb2742e3830c7b49e324852dbcc6c16056d9cc0a900247a403ae60f2

setup() {
  setup_test_env
  # Absolute, because the tests below run commands under a PATH that
  # deliberately does not contain a shell.
  BASH_BIN="$(command -v bash)"
  PATHBOX="$TEST_SKILL_DIR/pathbox"
}

teardown() {
  teardown_test_env
}

# pathbox <name> <tool>... -> prints a directory containing ONLY those tools.
#
# Symlinks to the real binaries, not copies: a copy that arrives without its
# executable bit fails every case for a reason that has nothing to do with what
# is under test, and looks exactly like the fallback working.
#
# Returns 1 (and the caller skips) when a tool this machine does not have is
# asked for -- macOS runners have no `sha256sum`, and a silently-skipped arm
# that reports success is the failure mode this file exists to avoid.
pathbox() {
  local dir="$PATHBOX/$1"; shift
  mkdir -p "$dir"
  local tool src
  for tool in "$@"; do
    src="$(command -v "$tool")" || return 1
    ln -sf "$src" "$dir/$tool"
  done
  printf '%s' "$dir"
}

# Run `printf '%s' agmsg | agmsg_sha256` with PATH set to $1 and nothing else.
sha256_under() {
  local box="$1"
  PATH="$box" "$BASH_BIN" -c '
    set -euo pipefail
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256
  ' _ "$SCRIPTS"
}

@test "hash: agmsg_sha256 on the unrestricted PATH returns the real digest" {
  run sha256_under "$PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "$AGMSG_SHA256" ]
}

# The negative control for every case below it. If a pathbox did NOT hide the
# tool it claims to hide, the fallback tests would pass without ever leaving
# the first arm -- green, and measuring nothing.
@test "hash: a pathbox really does hide the tools it leaves out" {
  local box; box="$(pathbox control awk)" || skip "awk not found"
  run env PATH="$box" "$BASH_BIN" -c 'command -v shasum || echo ABSENT'
  [ "$status" -eq 0 ]
  [ "$output" = "ABSENT" ]
  # ...and the positive half: a tool that IS in the box is found.
  run env PATH="$box" "$BASH_BIN" -c 'command -v awk >/dev/null && echo PRESENT'
  [ "$output" = "PRESENT" ]
}

@test "hash: the shasum arm computes SHA-256" {
  local box; box="$(pathbox shasum awk shasum)" || skip "shasum not installed"
  run sha256_under "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$AGMSG_SHA256" ]
}

@test "hash: without shasum it falls through to sha256sum, same value" {
  local box; box="$(pathbox sha256sum awk sha256sum)" || skip "sha256sum not installed"
  run sha256_under "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$AGMSG_SHA256" ]
}

@test "hash: without shasum or sha256sum it falls through to openssl, same value" {
  local box; box="$(pathbox openssl awk openssl)" || skip "openssl not installed"
  run sha256_under "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$AGMSG_SHA256" ]
}

# The whole point of the different last resort. agmsg_sha1 ends in `cksum` and
# always answers; this one must refuse.
@test "hash: with no SHA-256 tool at all it FAILS instead of answering" {
  local box; box="$(pathbox none awk)" || skip "awk not found"
  # stderr discarded INSIDE: bats' `run` merges the two streams, so the
  # diagnostic would land in $output and the "nothing was printed" assertion
  # below would be measuring the error message.
  run env PATH="$box" "$BASH_BIN" -c '
    set -euo pipefail
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  # And nothing on stdout: an empty success is the outcome that would be
  # carried forward as a fingerprint or a checkpoint.
  [ -z "$output" ]
}

@test "hash: the failure says which tools were looked for" {
  local box; box="$(pathbox nonemsg awk)" || skip "awk not found"
  run env PATH="$box" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>&1 >/dev/null
  ' _ "$SCRIPTS"
  [[ "$output" == *shasum* ]]
  [[ "$output" == *sha256sum* ]]
  [[ "$output" == *openssl* ]]
}

@test "hash: agmsg_sha256_usable reports what agmsg_sha256 can actually do" {
  local box; box="$(pathbox usable-no awk)" || skip "awk not found"
  run env PATH="$box" "$BASH_BIN" -c '. "$1/lib/hash.sh"; agmsg_sha256_usable' _ "$SCRIPTS"
  [ "$status" -ne 0 ]

  box="$(pathbox usable-yes awk openssl)" || skip "openssl not installed"
  run env PATH="$box" "$BASH_BIN" -c '. "$1/lib/hash.sh"; agmsg_sha256_usable' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
}

# The reason the probe runs the tool instead of asking `command -v`. A digest
# tool that is installed and broken is exactly the case where a presence check
# says yes and the digest says no -- and the whole value of a preflight is that
# it disagrees with nothing later.
@test "hash: agmsg_sha256_usable says no when the tools are present but broken" {
  local shim="$TEST_SKILL_DIR/broken"
  mkdir -p "$shim"
  local tool
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\nexit 1\n' > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  # Control first: they ARE on PATH, so a `command -v` probe would say yes.
  run env PATH="$shim:$PATH" "$BASH_BIN" -c 'command -v shasum >/dev/null && echo PRESENT'
  [ "$output" = "PRESENT" ]

  run env PATH="$shim:$PATH" "$BASH_BIN" -c '. "$1/lib/hash.sh"; agmsg_sha256_usable' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

@test "hash: agmsg_require_sha256 names a way to install one" {
  local box; box="$(pathbox require awk)" || skip "awk not found"
  run env PATH="$box" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    agmsg_require_sha256 2>&1 >/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [[ "$output" == *install* ]]
}

# agmsg_sha1 is deliberately NOT changed by this work. Asserted here so that
# "make the two consistent" has to break a test rather than pass review.
@test "hash: agmsg_sha1 still answers with no digest tool at all (cksum arm)" {
  local box; box="$(pathbox sha1 awk cksum)" || skip "cksum not found"
  run env PATH="$box" "$BASH_BIN" -c '
    set -euo pipefail
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha1
  ' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
