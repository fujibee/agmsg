#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  source "$SCRIPTS/lib/claims.sh"
  export TEST_TEAM=claims-team TEST_AGENT=grok-pane TEST_OWNER=daemon-a
  "$SCRIPTS/send.sh" "$TEST_TEAM" sender "$TEST_AGENT" "claim payload" >/dev/null
}

teardown() { teardown_test_env; }

@test "claim is exclusive until release" {
  run agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" "$TEST_OWNER" 60
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  run agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" daemon-b 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "released claim can be claimed and acknowledged exactly once" {
  first="$(agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" "$TEST_OWNER" 60)"
  id="${first%%$'\x1f'*}"
  agmsg_release_claim "$id" "$TEST_OWNER"

  second="$(agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" daemon-b 60)"
  [ -n "$second" ]
  id="${second%%$'\x1f'*}"
  agmsg_ack_claim "$id" daemon-b

  run agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" daemon-c 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wrong owner cannot acknowledge a claim" {
  first="$(agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" "$TEST_OWNER" 60)"
  id="${first%%$'\x1f'*}"
  agmsg_ack_claim "$id" wrong-owner
  run agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" daemon-b 60
  [ -z "$output" ]
}

@test "expired claim is reclaimed by another daemon" {
  first="$(agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" "$TEST_OWNER" 0)"
  [ -n "$first" ]
  run agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" daemon-b 60
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "claim preserves escaped body text" {
  "$SCRIPTS/send.sh" "$TEST_TEAM" sender "$TEST_AGENT" $'line one\nline two\tend' >/dev/null
  first="$(agmsg_claim_next "$TEST_TEAM" "$TEST_AGENT" "$TEST_OWNER" 60)"
  [[ "$first" == *'line one\\nline two\\tend'* ]]
}
