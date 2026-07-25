#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# --- generate ---------------------------------------------------------------

@test "recovery-key generate: prints a canonical AGMSG-xxxxx-xxxxx-xxxxx-xxxxx-xxxxx key" {
  run python3 "$SCRIPTS/internal/recovery-key.py" generate
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^AGMSG(-[0-9A-Z]{5}){5}$ ]]
  [ "${#output}" -eq 35 ]
}

@test "recovery-key generate: two calls produce different keys" {
  run python3 "$SCRIPTS/internal/recovery-key.py" generate
  first="$output"
  run python3 "$SCRIPTS/internal/recovery-key.py" generate
  [ "$first" != "$output" ]
}

@test "recovery-key generate: never emits the excluded Crockford letters I, L, O, U" {
  run python3 "$SCRIPTS/internal/recovery-key.py" generate
  body="${output#AGMSG-}"
  [[ "$body" != *I* ]]
  [[ "$body" != *L* ]]
  [[ "$body" != *O* ]]
  [[ "$body" != *U* ]]
}

# --- verify: round trip ------------------------------------------------------

@test "recovery-key verify: a freshly generated key round-trips to itself" {
  key=$(python3 "$SCRIPTS/internal/recovery-key.py" generate)
  run bash -c "printf '%s' '$key' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 0 ]
  [ "$output" = "$key" ]
}

@test "recovery-key verify: tolerates lowercase, extra whitespace, and stripped hyphens" {
  key=$(python3 "$SCRIPTS/internal/recovery-key.py" generate)
  messy="  $(echo "$key" | tr '[:upper:]' '[:lower:]' | tr -d '-')  "
  run bash -c "printf '%s' '$messy' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 0 ]
  [ "$output" = "$key" ]
}

@test "recovery-key verify: maps O/I/L confusables to their Crockford digit" {
  key=$(python3 "$SCRIPTS/internal/recovery-key.py" generate)
  # Substitute any '0' in the body with 'O' -- must still parse identically.
  confused=$(echo "$key" | sed 's/0/O/g')
  run bash -c "printf '%s' '$confused' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 0 ]
  [ "$output" = "$key" ]
}

# --- verify: fail-closed on corruption ---------------------------------------

@test "recovery-key verify: rejects a key with a corrupted check digit" {
  key=$(python3 "$SCRIPTS/internal/recovery-key.py" generate)
  last="${key: -1}"
  replacement="0"
  [ "$last" = "0" ] && replacement="1"
  corrupted="${key%?}${replacement}"
  run bash -c "printf '%s' '$corrupted' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 1 ]
  [[ "$output" == *"check digit mismatch"* ]]
}

@test "recovery-key verify: rejects a key that is too short" {
  run bash -c "printf 'AGMSG-AAAAA-AAAAA' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected 25 symbols"* ]]
}

@test "recovery-key verify: rejects a key that is too long" {
  key=$(python3 "$SCRIPTS/internal/recovery-key.py" generate)
  run bash -c "printf '%sAA' '$key' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected 25 symbols"* ]]
}

@test "recovery-key verify: rejects a missing AGMSG prefix" {
  run bash -c "printf 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must start with 'AGMSG'"* ]]
}

@test "recovery-key verify: rejects an invalid character outside the Crockford alphabet" {
  key=$(python3 "$SCRIPTS/internal/recovery-key.py" generate)
  bad="${key%?}!"
  run bash -c "printf '%s' '$bad' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid character"* ]]
}

@test "recovery-key verify: never emits partial output on a rejected key" {
  run bash -c "printf 'not-a-key-at-all' | python3 '$SCRIPTS/internal/recovery-key.py' verify"
  [ "$status" -eq 1 ]
  [[ "$output" != *"AGMSG-"* ]]
}
