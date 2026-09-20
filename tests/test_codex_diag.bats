#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  export DIAG="$TYPES/codex/codex-diagnose.sh"
}

teardown() {
  teardown_test_env
}

@test "codex diagnose: help separates thread confirmation from TUI visibility" {
  run bash "$DIAG" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- "THREAD_CONFIRMED"
  [[ "$output" == *"visibly"* ]]
}

@test "codex diagnose: legacy invocation keeps the binary non-match exit contract" {
  run bash "$DIAG" "$PROJ" team alice
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex diagnosis: UNKNOWN"* ]]
}

@test "codex diagnose: self-test requires the initiating Codex thread" {
  unset CODEX_THREAD_ID
  run bash "$DIAG" "$PROJ" team alice --self-test
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF -- "self-delivery: UNKNOWN reason=missing-or-invalid-CODEX_THREAD_ID"
  [ ! -d "$TEST_SKILL_DIR/run" ] || [ -z "$(find "$TEST_SKILL_DIR/run" -name 'codex-self-test.*.json' -print)" ]
}

@test "codex diagnose: sent record is exposed as PENDING with exit 3" {
  export CODEX_THREAD_ID="018f3f7e-0000-7000-8000-000000000099"
  run bash "$DIAG" "$PROJ" team alice --self-test
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -qF -- "self-delivery: PENDING"
  diagnosis_id="$(printf '%s\n' "$output" | sed -n 's/.*diagnosis_id=\([^ ]*\).*/\1/p' | tail -n 1)"
  [ -n "$diagnosis_id" ]
  run bash "$DIAG" "$PROJ" team alice --status "$diagnosis_id"
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -qF -- "self-delivery: PENDING diagnosis_id=$diagnosis_id"

  run bash "$DIAG" "$PROJ" team alice --self-test
  [ "$status" -eq 3 ]
  [[ "$output" == *"diagnosis_id=$diagnosis_id reason=existing-pending"* ]]
}

@test "codex diagnose: effective home prefers AGMSG_CODEX_HOME" {
  local isolated="$TEST_SKILL_DIR/orca-codex-home"
  mkdir -p "$isolated"
  export CODEX_THREAD_ID="018f3f7e-0000-7000-8000-000000000099"
  export AGMSG_CODEX_HOME="$isolated"
  export CODEX_HOME="$TEST_SKILL_DIR/default-codex-home"

  run bash "$DIAG" "$PROJ" team alice --self-test
  [ "$status" -eq 3 ]
  diagnosis_id="$(printf '%s\n' "$output" | sed -n 's/.*diagnosis_id=\([^ ]*\).*/\1/p' | tail -n 1)"
  [ -n "$diagnosis_id" ]

  expected_hash="$(printf '%s' "$isolated" | sha1sum | awk '{print $1}')"
  state_file="$TEST_SKILL_DIR/run/codex-self-test.$diagnosis_id.json"
  [ "$(node -e 'const fs=require("fs");const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(o.codex_home_hash)' "$state_file")" = "$expected_hash" ]
}
@test "codex diagnose: received marker records only THREAD_CONFIRMED and requires screen observation" {
  export CODEX_THREAD_ID="018f3f7e-0000-7000-8000-000000000099"
  run bash "$DIAG" "$PROJ" team alice --self-test
  [ "$status" -eq 3 ]
  diagnosis_id="$(printf '%s\n' "$output" | sed -n 's/.*diagnosis_id=\([^ ]*\).*/\1/p' | tail -n 1)"

  marker_json="$(bash "$TYPES/codex/codex-self-test-inbox.sh" peek team alice)"
  values="$(printf '%s' "$marker_json" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const o=JSON.parse(s);const m=o.body.match(/^agmsg-codex-self-test:v1:[^:]+:([a-f0-9]+)$/);if(!m)process.exit(1);process.stdout.write(`${m[1]} ${o.id}`)})')"
  nonce="${values%% *}"
  message_id="${values#* }"
  run bash "$DIAG" "$PROJ" team alice --confirm "$nonce" "$message_id"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF -- "self-delivery: THREAD_CONFIRMED diagnosis_id=$diagnosis_id"
  printf '%s\n' "$output" | grep -qF -- "tui-visible: REQUIRES_CURRENT_SCREEN_OBSERVATION"

  run bash "$DIAG" "$PROJ" team alice --status "$diagnosis_id"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- "self-delivery: THREAD_CONFIRMED"
  [[ "$output" != *"self-delivery: CONFIRMED"* ]]
}

@test "codex diagnose: malformed confirm values fail closed" {
  run bash "$DIAG" "$PROJ" team alice --confirm not-a-hex-nonce message-id
  [ "$status" -eq 2 ]
  [[ "$output" == *"self-delivery: UNKNOWN reason=invalid-nonce"* ]]
}

@test "send: print-id is opt-in and returns the stored opaque id" {
  run bash "$SCRIPTS/send.sh" team alice alice hello
  [ "$status" -eq 0 ]
  refute grep -qF -- "message_id=" <<<"$output"

  run bash "$SCRIPTS/send.sh" team alice alice hello-again --print-id
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- "message_id="
  id="$(printf '%s\n' "$output" | sed -n 's/^message_id=//p')"
  [[ "$id" =~ ^[A-Za-z0-9-]+$ ]]
}

@test "send: legacy trailing force preserves the positional body" {
  run bash "$SCRIPTS/send.sh" team alice alice "forced positional body" --force
  [ "$status" -eq 0 ]
  run agmsg_inbox team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"forced positional body"* ]]
}

@test "send: body-file with trailing force preserves the file body" {
  local body_file="$TEST_SKILL_DIR/send-body.txt"
  printf '%s\n' "forced file body" >"$body_file"
  run bash "$SCRIPTS/send.sh" team alice alice --body-file "$body_file" --force
  [ "$status" -eq 0 ]
  run agmsg_inbox team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"forced file body"* ]]
}

@test "send: force and print-id work in either trailing order without changing body" {
  run bash "$SCRIPTS/send.sh" team alice alice "flags force then id" --force --print-id
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- "message_id="
  run bash "$SCRIPTS/send.sh" team alice alice "flags id then force" --print-id --force
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- "message_id="
  run agmsg_inbox team alice --quiet
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- "flags force then id"
  [[ "$output" == *"flags id then force"* ]]
}

@test "bridge marker parser requires exact self sender and full structured body" {
  run node - "$TYPES/codex/codex-bridge.js" <<'NODE'
const { parseSelfTestMarker } = require(process.argv[2]);
const nonce = "a".repeat(48);
const pair = { team: "team", name: "alice" };
const good = { type: "message_sent", from: "alice", to: "alice", body: `agmsg-codex-self-test:v1:diag-1:${nonce}` };
if (!parseSelfTestMarker(good, pair)) process.exit(1);
if (parseSelfTestMarker({ ...good, from: "bob" }, pair)) process.exit(2);
if (parseSelfTestMarker({ ...good, body: `${good.body}:extra` }, pair)) process.exit(3);
NODE
  [ "$status" -eq 0 ]
}

@test "bridge inbox transport peeks exact ids and acknowledges only explicit rows" {
  bash "$SCRIPTS/send.sh" team alice alice first >/dev/null
  bash "$SCRIPTS/send.sh" team alice alice second >/dev/null
  run bash "$TYPES/codex/codex-self-test-inbox.sh" peek team alice
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  printf '%s\n' "$output" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{for(const l of s.trim().split(/\n/)){const o=JSON.parse(l);if(!o.id||o.type!=="message_sent")process.exit(1)}})'
  first_id="$(printf '%s\n' "${lines[0]}" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(String(JSON.parse(s).id)))')"
  run bash "$TYPES/codex/codex-self-test-inbox.sh" ack team alice "$first_id"
  [ "$status" -eq 0 ]
  run bash "$TYPES/codex/codex-self-test-inbox.sh" peek team alice
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  run agmsg_inbox team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"second"* ]]
}
