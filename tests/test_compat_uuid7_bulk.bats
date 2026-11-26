#!/usr/bin/env bats

# compat_uuid7_bulk: many UUIDv7s for a page of imported messages at a fixed
# number of process launches.

load test_helper

setup() {
  setup_test_env
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/compat.sh"
}

teardown() { teardown_test_env; }

@test "compat_uuid7_bulk: count valid, distinct v7 ids, one per line" {
  run compat_uuid7_bulk 300
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 300 ]
  [ "$(printf '%s\n' "$output" | grep -Ec '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$')" -eq 300 ]
  [ "$(printf '%s\n' "$output" | sort -u | wc -l | tr -d ' ')" -eq 300 ]
}

@test "compat_uuid7_bulk: the timestamp part matches compat_uuid7's" {
  single="$(compat_uuid7)"
  run compat_uuid7_bulk 2
  [ "$status" -eq 0 ]
  first="${output%%$'\n'*}"
  [ "${first:0:8}" = "${single:0:8}" ]
}

@test "compat_uuid7_bulk: zero is empty, a non-number is refused" {
  run compat_uuid7_bulk 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run compat_uuid7_bulk x
  [ "$status" -eq 1 ]
}

@test "compat_uuid7_bulk: launches the same few processes for 5 ids and for 500" {
  mkdir -p "$BATS_TEST_TMPDIR/sh"
  export SPAWN_LOG="$BATS_TEST_TMPDIR/spawn.log"
  for c in date head od tr; do
    printf '#!/bin/bash\necho %s >> "$SPAWN_LOG"\nexec %s "$@"\n' "$c" "$(command -v $c)" > "$BATS_TEST_TMPDIR/sh/$c"
    chmod +x "$BATS_TEST_TMPDIR/sh/$c"
  done
  : > "$SPAWN_LOG"
  PATH="$BATS_TEST_TMPDIR/sh:$PATH" compat_uuid7_bulk 5 >/dev/null
  small="$(wc -l < "$SPAWN_LOG" | tr -d ' ')"
  : > "$SPAWN_LOG"
  PATH="$BATS_TEST_TMPDIR/sh:$PATH" compat_uuid7_bulk 500 >/dev/null
  large="$(wc -l < "$SPAWN_LOG" | tr -d ' ')"
  [ "$small" -eq "$large" ]
  [ "$large" -le 4 ]
}
