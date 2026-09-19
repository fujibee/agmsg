#!/usr/bin/env bats

# scripts/drivers/ext-tools/slack/handle, against a loopback fixture --
# never the real Slack API (design note memory/design/2026-09-19-ext-tool-design.md §5b).

load test_helper

setup() {
  setup_test_env
  MOCK_PYTHON3="$(command -v python3)"
  local key_file="$TEST_SKILL_DIR/slack-bot.token"
  printf 'xoxb-test-token-do-not-print\n' > "$key_file"
  chmod 600 "$key_file"
  CONFIG_PATH="$TEST_SKILL_DIR/ext-tools-slack-member.conf"
  {
    printf 'key_file=%s\n' "$key_file"
    printf 'channel=%s\n' "C0DEPLOYS"
  } > "$CONFIG_PATH"
  INPUT="$(jq -cn --arg cp "$CONFIG_PATH" '{
    team: "ops", from: "alice", to: "slack-ops",
    body: "deploy complete: v1.3.2",
    message_id: "018f0000-0000-7000-8000-000000000001",
    config_path: $cp
  }')"
}

teardown() {
  _stop_mock_slack
  teardown_test_env
}

_stop_mock_slack() {
  if [ -n "${MOCK_SERVER_PID:-}" ]; then
    kill "$MOCK_SERVER_PID" 2>/dev/null || true
    wait "$MOCK_SERVER_PID" 2>/dev/null || true
    MOCK_SERVER_PID=""
  fi
}

# Starts (or restarts) the fixture with the given MOCK_SLACK_* env
# assignments and sets $MOCK_PORT. One fixture at a time -- each call tears
# down the previous one first, so a table of scenarios in one test does not
# accumulate listening sockets.
_start_mock_slack() {
  _stop_mock_slack
  env "$@" "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_slack_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
}

@test "slack handle: posts the configured channel/text, and turns every failure into one line" {
  # No agmsg-slack-curl.* work_dir survives ANY of this test's calls, success
  # or failure -- a before/after snapshot of the whole run rather than one
  # call, since that is the property that matters: _slack_api_call's trap
  # covers EXIT/INT/TERM, but only running it is evidence, not reading the
  # code.
  local tmp_root="${TMPDIR:-/tmp}" leftover_before leftover_after
  leftover_before="$(find "$tmp_root" -maxdepth 1 -name 'agmsg-slack-curl.*' 2>/dev/null | sort)"

  local request_log="$TEST_SKILL_DIR/slack-request.json"
  _start_mock_slack MOCK_SLACK_ERROR="not_in_channel" MOCK_SLACK_REQUEST_LOG="$request_log"

  run env AGMSG_SLACK_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/slack/handle" <<<"$INPUT"

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
  # bearer header ONLY (never in argv, per the design note's §3 contract), and the
  # configured channel + body as the JSON payload, sent over stdin rather
  # than the command line.
  wait_for_file_contains "$request_log" '"path"'
  [ "$(jq -r '.path' "$request_log")" = "/chat.postMessage" ]
  [ "$(jq -r '.authorization' "$request_log")" = "Bearer xoxb-test-token-do-not-print" ]
  [ "$(jq -r '.body.channel' "$request_log")" = "C0DEPLOYS" ]
  [ "$(jq -r '.body.text' "$request_log")" = "deploy complete: v1.3.2" ]

  # Every other failure shape handle can produce, table-style: one Slack
  # error code per row still through the same not_in_channel-style envelope,
  # plus the two shapes that are NOT a plain {"ok":false} envelope -- rate
  # limiting (Slack's one non-200 status) and a transport failure (nothing is
  # listening at all). Each still collapses to exactly one line.
  local case_name
  for case_name in invalid_auth missing_scope; do
    _start_mock_slack MOCK_SLACK_ERROR="$case_name"
    run env AGMSG_SLACK_API_BASE="http://127.0.0.1:$MOCK_PORT" \
      "$SCRIPTS/drivers/ext-tools/slack/handle" <<<"$INPUT"
    [ "$status" -ne 0 ]
    case "$output" in
      *$'\n'*) echo "[$case_name] handle printed more than one line: $output" >&2; return 1 ;;
    esac
    printf '%s\n' "$output" | grep -qF "$case_name"
  done

  _start_mock_slack MOCK_SLACK_HTTP_STATUS=429
  run env AGMSG_SLACK_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/slack/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[429] handle printed more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "429"

  # A closed port: nothing is listening, so this is a transport failure, not
  # a Slack-reported one -- the one shape curl's own stderr has to be folded
  # into a single line for.
  _start_mock_slack MOCK_SLACK_ERROR=""
  local dead_port="$MOCK_PORT"
  _stop_mock_slack
  run env AGMSG_SLACK_API_BASE="http://127.0.0.1:$dead_port" \
    "$SCRIPTS/drivers/ext-tools/slack/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[transport] handle printed more than one line: $output" >&2; return 1 ;;
  esac
  refute grep -qF "xoxb-test-token-do-not-print" <<<"$output"

  # A corrupt/multi-line key file is refused BEFORE curl is ever invoked:
  # an unescaped embedded newline could otherwise end the `header = "..."`
  # config line early and let the rest of the token be read as a further
  # curl -K directive. Point at a real, logging fixture: if curl ran at
  # all, the log would exist.
  local bad_key_file="$TEST_SKILL_DIR/slack-bot-multiline.token" \
    bad_config="$TEST_SKILL_DIR/ext-tools-slack-member-bad.conf" \
    bad_request_log="$TEST_SKILL_DIR/slack-request-bad.json"
  printf 'xoxb-test-token-do-not-print\nSecond-Line-Injected\n' > "$bad_key_file"
  chmod 600 "$bad_key_file"
  {
    printf 'key_file=%s\n' "$bad_key_file"
    printf 'channel=%s\n' "C0DEPLOYS"
  } > "$bad_config"
  _start_mock_slack MOCK_SLACK_ERROR="" MOCK_SLACK_REQUEST_LOG="$bad_request_log"
  local bad_input
  bad_input="$(jq -cn --arg cp "$bad_config" \
    '{team: "ops", from: "alice", to: "slack-ops", body: "x", message_id: "m", config_path: $cp}')"
  run env AGMSG_SLACK_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/slack/handle" <<<"$bad_input"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[bad token] handle printed more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qiF "single-line"
  refute grep -qF "Second-Line-Injected" <<<"$output"
  [ ! -e "$bad_request_log" ]

  # curl's OWN argv, inspected while a request is genuinely in flight: a
  # slow fixture holds the connection open long enough to read /bin/ps for
  # the curl child handle spawned, proving neither the token nor the body
  # ever appear there -- not just that the final result happens not to
  # show them.
  #
  # `pgrep -x curl` (exact comm match), not a full-command PATTERN search:
  # this test file's own source contains the literal text being searched
  # for, and a pattern search (`pgrep -f`/`ps -ef | grep`) over the whole
  # process table matches THAT -- the classic "grep finds grep" trap, just
  # one layer removed. Matching curl by name and then reading each
  # candidate's OWN argv (filtered by this call's unique temp-dir marker,
  # since a busy shared machine may run an unrelated curl at the same
  # moment) cannot self-match.
  _start_mock_slack MOCK_SLACK_ERROR="" MOCK_SLACK_DELAY_SECONDS=3
  AGMSG_SLACK_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/slack/handle" <<<"$INPUT" &
  local handle_pid=$!
  local curl_argv="" curl_pid attempt
  for attempt in $(seq 1 20); do
    for curl_pid in $(pgrep -x curl 2>/dev/null || true); do
      curl_argv="$(ps -o command= -p "$curl_pid" 2>/dev/null || true)"
      case "$curl_argv" in *agmsg-slack-curl*) break 2 ;; esac
      curl_argv=""
    done
    [ -n "$curl_argv" ] && break
    sleep 0.2
  done
  wait "$handle_pid" || true
  [ -n "$curl_argv" ]
  refute grep -qF "xoxb-test-token-do-not-print" <<<"$curl_argv"
  refute grep -qF "deploy complete" <<<"$curl_argv"

  leftover_after="$(find "$tmp_root" -maxdepth 1 -name 'agmsg-slack-curl.*' 2>/dev/null | sort)"
  [ "$leftover_before" = "$leftover_after" ]
}
