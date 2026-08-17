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
#
# `cksum` IS in the box on purpose. Without it this test passed a mutation that
# added the cksum arm -- not because the refusal survived, but because the
# sandbox had no cksum for the fallback to reach. It was measuring the box, not
# the decision. On any real machine cksum is present, so that is the shape the
# test has to run in.
@test "hash: with no SHA-256 tool at all it FAILS instead of answering" {
  local box; box="$(pathbox none awk cksum)" || skip "awk/cksum not found"
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
  local box; box="$(pathbox nonemsg awk cksum)" || skip "awk/cksum not found"
  run env PATH="$box" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>&1 >/dev/null
  ' _ "$SCRIPTS"
  # grep, not `[[ ]]`: a non-last `[[ ]]` cannot fail a test on bash 3.2, so the
  # first two of three would have been decoration (#670).
  grep -qF -- shasum <<<"$output"
  grep -qF -- sha256sum <<<"$output"
  grep -qF -- openssl <<<"$output"
}

@test "hash: agmsg_sha256_usable reports what agmsg_sha256 can actually do" {
  local box; box="$(pathbox usable-no awk cksum)" || skip "awk/cksum not found"
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
  local box; box="$(pathbox require awk cksum)" || skip "awk/cksum not found"
  run env PATH="$box" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    agmsg_require_sha256 2>&1 >/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [[ "$output" == *install* ]]
}

# THE REFUSAL WITHOUT THE CALLER'S HELP. Every case above runs under
# `set -euo pipefail`, so none of them can tell "the helper failed" from "the
# caller's pipefail noticed that the last stage got nothing". This one turns
# pipefail OFF, which is the shell any caller that has not opted in provides.
#
# A PRESENT-BUT-BROKEN TOOL, NOT AN ABSENT ONE. The first version of this case
# used an empty pathbox and could not fail: with no tool at all the helper takes
# its `else` branch and returns 1 outright, which never depended on pipefail.
# It measured nothing, and the mutation that should have reddened it did not.
# A tool that is FOUND and then fails is the only path where the status of the
# tool has to survive on its own.
@test "hash: a broken tool is refused even when the caller has no pipefail" {
  local shim="$TEST_SKILL_DIR/nopipefail"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/shasum"
  chmod +x "$shim/shasum"
  run env PATH="$shim:$PATH" "$BASH_BIN" -c '
    set +o pipefail
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# THE HALF THE SHAPE CHECK CANNOT SEE. A tool that exits non-zero while still
# printing a well-formed digest passes every check on the answer and is caught
# only by the status of the tool itself. Without this case, reverting the arms
# to their piped form changes no result, because the 64-hex check happens to
# catch every other broken-tool shape.
@test "hash: a tool that fails while printing a plausible digest is refused" {
  local shim="$TEST_SKILL_DIR/failsloud"
  mkdir -p "$shim"
  printf '#!/bin/sh\ncat >/dev/null\necho "%s  -"\nexit 1\n' "$AGMSG_SHA256" > "$shim/shasum"
  chmod +x "$shim/shasum"
  # Control: the digest it prints is the RIGHT one, so nothing about the answer
  # is what makes this fail.
  run env PATH="$shim:$PATH" "$BASH_BIN" -c 'printf x | shasum -a 256 | cut -d" " -f1'
  [ "$output" = "$AGMSG_SHA256" ]

  run env PATH="$shim:$PATH" "$BASH_BIN" -c '
    set +o pipefail
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "hash: and it still answers correctly with no pipefail when a tool is there" {
  # The other half, so the case above cannot pass by refusing everything.
  run env PATH="$PATH" "$BASH_BIN" -c '
    set +o pipefail
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256
  ' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = "$AGMSG_SHA256" ]
}

# EXIT 0 IS NOT A DIGEST. The broken-tool case above uses `exit 1`, which any
# status check catches. This is the one that gets through a status check: a
# tool that succeeds and prints something else -- a warning, a path, an empty
# line -- and whose output would be carried into a fingerprint.
@test "hash: a tool that exits 0 and prints a non-digest is refused" {
  local shim="$TEST_SKILL_DIR/liar"
  mkdir -p "$shim"
  local tool
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\ncat >/dev/null\necho "warning: cannot read the input"\nexit 0\n' > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  # Control: it really does exit 0, so a status check alone would pass it.
  run env PATH="$shim:$PATH" "$BASH_BIN" -c 'printf x | shasum -a 256 >/dev/null'
  [ "$status" -eq 0 ]

  run env PATH="$shim:$PATH" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  run env PATH="$shim:$PATH" "$BASH_BIN" -c '. "$1/lib/hash.sh"; agmsg_sha256_usable' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

# 64 hex characters that are the WRONG 64. Nothing about the shape of an answer
# says it is the digest of the input, and this value is the one two people read
# to each other.
#
# THE REFUSAL IS agmsg_sha256'S OWN, not the preflight's. It was the preflight's
# for one head, which left `key.sh` — its own CLI, four subcommands, none of
# them going through `connect` — accepting the wrong value. Raised in review.
# The case now pins both halves: the shape layer accepts it, and the function
# every caller actually uses does not.
@test "hash: a tool returning a well-formed but wrong digest is refused" {
  local shim="$TEST_SKILL_DIR/plausible"
  mkdir -p "$shim"
  local tool
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\ncat >/dev/null\necho "%s  -"\n' \
      0000000000000000000000000000000000000000000000000000000000000000 > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  # Control: the shape layer accepts it, because it IS 64 lowercase hex. So the
  # refusal below is the self-test and not something about the answer's form.
  run env PATH="$shim:$PATH" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    printf "%s" agmsg | _agmsg_sha256_selected
  ' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  [ "$output" = 0000000000000000000000000000000000000000000000000000000000000000 ]

  run env PATH="$shim:$PATH" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  run env PATH="$shim:$PATH" "$BASH_BIN" -c '. "$1/lib/hash.sh"; agmsg_sha256_usable' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

# NOTHING IN THE ENVIRONMENT CAN SAY "ALREADY CHECKED". The self-test was
# memoised on one head, keyed on a plain shell variable that was read from the
# environment — so exporting it turned the check off, which is an undocumented
# override of a fail-closed contract. The memo is gone; this case is what stops
# it coming back in a form that can be preseeded.
#
# Every plausible name is tried, because guessing the private name of a future
# memo is not the point: the property is that NO inherited variable skips it.
@test "hash: a preseeded environment cannot skip the self-test" {
  local shim="$TEST_SKILL_DIR/preseeded"
  mkdir -p "$shim"
  local tool
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\ncat >/dev/null\necho "%s  -"\n' \
      2222222222222222222222222222222222222222222222222222222222222222 > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  run env PATH="$shim:$PATH" \
    _AGMSG_SHA256_VERIFIED=1 AGMSG_SHA256_VERIFIED=1 _AGMSG_SHA256_OK=1 \
    "$BASH_BIN" -c '
      . "$1/lib/hash.sh"
      printf "%s" agmsg | agmsg_sha256 2>/dev/null
    ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# THE FALLBACK IS FOR AN ABSENT TOOL, NOT A BROKEN ONE. Presence picks the arm;
# a chosen arm that fails ends it, and the working tool behind it is not tried.
# Asserted because it is a decision, and an undocumented decision becomes an
# accident the first time someone "fixes" it.
@test "hash: a broken first arm is not rescued by a working later one" {
  local shim="$TEST_SKILL_DIR/firstbroken"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/shasum"
  chmod +x "$shim/shasum"
  local box; box="$(pathbox firstbroken-real awk openssl)" || skip "openssl not installed"
  # Control: openssl alone, in that box, does answer.
  run sha256_under "$box"
  [ "$status" -eq 0 ]
  [ "$output" = "$AGMSG_SHA256" ]

  run env PATH="$shim:$box" "$BASH_BIN" -c '
    . "$1/lib/hash.sh"
    printf "%s" agmsg | agmsg_sha256 2>/dev/null
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
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
