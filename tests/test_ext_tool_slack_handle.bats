#!/usr/bin/env bats

# scripts/drivers/ext-tools/slack/handle, against a loopback fixture --
# never the real Slack API (design note memory/design/2026-09-19-ext-tool-design.md §5b).

load test_helper

setup() {
  setup_test_env
  MOCK_PYTHON3="$(command -v python3)"
}

teardown() {
  if [ -n "${MOCK_SERVER_PID:-}" ]; then
    kill "$MOCK_SERVER_PID" 2>/dev/null || true
    wait "$MOCK_SERVER_PID" 2>/dev/null || true
  fi
  teardown_test_env
}

@test "slack handle: posts the configured channel/text and turns a Slack error into one failure line" {
  # A key file, never read by anything except handle itself; the test only
  # ever checks what handle SENT (the Authorization header), never prints it.
  local key_file="$TEST_SKILL_DIR/slack-bot.token"
  printf 'xoxb-test-token-do-not-print\n' > "$key_file"
  chmod 600 "$key_file"

  local config_path="$TEST_SKILL_DIR/ext-tools-slack-member.conf"
  {
    printf 'key_file=%s\n' "$key_file"
    printf 'channel=%s\n' "C0DEPLOYS"
  } > "$config_path"

  local request_log="$TEST_SKILL_DIR/slack-request.json"
  MOCK_SLACK_ERROR="not_in_channel" MOCK_SLACK_REQUEST_LOG="$request_log" \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_slack_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  local port
  port="$(cat "$TEST_SKILL_DIR/server.port")"

  local input
  input="$(jq -cn --arg cp "$config_path" '{
    team: "ops", from: "alice", to: "slack-ops",
    body: "deploy complete: v1.3.2",
    message_id: "018f0000-0000-7000-8000-000000000001",
    config_path: $cp
  }')"

  run env AGMSG_SLACK_API_BASE="http://127.0.0.1:$port" \
    "$SCRIPTS/drivers/ext-tools/slack/handle" <<<"$input"

  # Exactly one failure line, naming the reason Slack gave -- not agmsg's own
  # wrapping sentence (that belongs to whatever calls handle, not to handle).
  # `case` rather than a non-last `[[ ]]`, which is silent under errexit on
  # bash 3.2 (#670) when something follows it -- as it does here.
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "handle printed more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "not_in_channel"

  # What actually reached the fixture: the right endpoint, the token as a
  # bearer header (never logged anywhere else), and the configured channel +
  # body as the JSON payload.
  wait_for_file_contains "$request_log" '"path"'
  [ "$(jq -r '.path' "$request_log")" = "/chat.postMessage" ]
  [ "$(jq -r '.authorization' "$request_log")" = "Bearer xoxb-test-token-do-not-print" ]
  [ "$(jq -r '.body.channel' "$request_log")" = "C0DEPLOYS" ]
  [ "$(jq -r '.body.text' "$request_log")" = "deploy complete: v1.3.2" ]
}
