#!/usr/bin/env bats

# scripts/drivers/ext-tools/jev/handle, against a loopback fixture -- never
# the real OpenRouter API (design note memory/design/2026-09-19-ext-tool-design.md §5b).

load test_helper

setup() {
  setup_test_env
  MOCK_PYTHON3="$(command -v python3)"
  KEY_FILE="$TEST_SKILL_DIR/openrouter.key"
  printf 'or-test-key-do-not-print\n' > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  CONFIG_PATH="$TEST_SKILL_DIR/ext-tools-jev-member.conf"
  printf 'key_file=%s\n' "$KEY_FILE" > "$CONFIG_PATH"

  # The one accepted shape: JSON with state + questions, built by the
  # calling agent itself -- no bundled question catalog, see USAGE.md.
  local body
  body="$(jq -cn '{
    state: "Pick a color.",
    questions: {color: {type: "choice", instructions: "Pick one.", criteria: {red: "warm", blue: "cool"}}}
  }')"
  INPUT="$(jq -cn --arg cp "$CONFIG_PATH" --arg body "$body" '{
    team: "ops", from: "alice", to: "jev-bot", body: $body,
    message_id: "018f0000-0000-7000-8000-000000000002",
    config_path: $cp
  }')"
}

teardown() {
  _stop_mock_openrouter
  teardown_test_env
}

_stop_mock_openrouter() {
  if [ -n "${MOCK_SERVER_PID:-}" ]; then
    kill "$MOCK_SERVER_PID" 2>/dev/null || true
    wait "$MOCK_SERVER_PID" 2>/dev/null || true
    MOCK_SERVER_PID=""
  fi
}

# Starts (or restarts) the fixture with the given MOCK_OPENROUTER_* env
# assignments and sets $MOCK_PORT. One fixture at a time -- each call tears
# down the previous one first, so a table of scenarios in one test does not
# accumulate listening sockets.
_start_mock_openrouter() {
  _stop_mock_openrouter
  env "$@" "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_openrouter_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  MOCK_PORT="$(wait_for_mock_server_port "$TEST_SKILL_DIR/server.port")" || return 1
}

@test "jev handle: sends the right request, replies with one line, and turns every failure into one line" {
  # No agmsg-jev-curl.* work_dir survives ANY of this test's calls, success
  # or failure -- a before/after snapshot of the whole run rather than one
  # call, since that is the property that matters: _jev_api_call's trap
  # covers EXIT/INT/TERM, but only running it is evidence, not reading the
  # code.
  local tmp_root="${TMPDIR:-/tmp}" leftover_before leftover_after
  leftover_before="$(find "$tmp_root" -maxdepth 1 -name 'agmsg-jev-curl.*' 2>/dev/null | sort)"

  # --- success: JSON body with state + questions, passed through close to
  # unchanged (the only accepted shape) ---
  local request_log="$TEST_SKILL_DIR/jev-request.json"
  _start_mock_openrouter MOCK_OPENROUTER_REQUEST_LOG="$request_log"

  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"

  [ "$status" -eq 0 ]
  case "$output" in
    *$'\n'*) echo "handle printed more than one line: $output" >&2; return 1 ;;
  esac
  # p and confidence are the product across both of the mock fixture's own
  # fixed answers (0.80 * 0.80 = 0.64, 0.90 * 0.70 = 0.63) -- the mock's
  # response never actually depends on what questions were asked, only the
  # REQUEST assertions below prove those were sent correctly. cost is the
  # call's own usage.cost, rounded to 6 places. The label is always "jev"
  # now -- there is no more named/bundled question type to label it with.
  [ "$output" = "jev: sonnet / high (choice p=0.64, confidence=0.63, cost \$0.000019)" ]

  wait_for_file_contains "$request_log" '"path"'
  [ "$(jq -r '.path' "$request_log")" = "/api/alpha/decisions" ]
  [ "$(jq -r '.authorization' "$request_log")" = "Bearer or-test-key-do-not-print" ]
  [ "$(jq -r '.body.model' "$request_log")" = "typesafe/jev-1.13" ]
  [ "$(jq -r '.body.state' "$request_log")" = "Pick a color." ]
  [ "$(jq -r '.body.questions.color.type' "$request_log")" = "choice" ]
  [ "$(jq -r '.body.questions.color.criteria.red' "$request_log")" = "warm" ]
  [ "$(jq -r '.body.questions.color.criteria.blue' "$request_log")" = "cool" ]

  # --- provider=typesafe: hits TypeSafe's own URL/model, reports tokens
  # instead of cost (maintainer decision, 2026-09-21 -- TypeSafe's real
  # response carries no cost figure at all, measured directly against
  # production, so this is never shown as if it were one) ---
  local typesafe_log="$TEST_SKILL_DIR/jev-request-typesafe.json"
  _start_mock_openrouter MOCK_OPENROUTER_REQUEST_LOG="$typesafe_log" MOCK_OPENROUTER_NO_COST=1
  local typesafe_config typesafe_input default_body
  typesafe_config="$TEST_SKILL_DIR/ext-tools-jev-member-typesafe.conf"
  {
    printf 'key_file=%s\n' "$KEY_FILE"
    printf 'provider=typesafe\n'
  } > "$typesafe_config"
  default_body="$(jq -r '.body' <<<"$INPUT")"
  typesafe_input="$(jq -cn --arg cp "$typesafe_config" --arg body "$default_body" '{
    team: "ops", from: "alice", to: "jev-bot", body: $body,
    message_id: "m", config_path: $cp
  }')"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$typesafe_input"
  [ "$status" -eq 0 ]
  case "$output" in
    *$'\n'*) echo "[typesafe] more than one line: $output" >&2; return 1 ;;
  esac
  [ "$output" = "jev: sonnet / high (choice p=0.64, confidence=0.63, tokens 441 in / 85 out)" ]
  refute grep -qF 'cost' <<<"$output"
  wait_for_file_contains "$typesafe_log" '"path"'
  [ "$(jq -r '.path' "$typesafe_log")" = "/v1/systemone" ]
  [ "$(jq -r '.body.model' "$typesafe_log")" = "jev-latest" ]

  # --- failure: an unrecognized provider is refused BEFORE any URL is
  # built or key sent -- both handle and setup test validate this (review
  # finding, #1364: setup test originally read provider without checking
  # it, so a typo would silently fall through to openrouter's URL/model
  # and send that member's real key there instead).
  local bad_provider_config bad_provider_input
  bad_provider_config="$TEST_SKILL_DIR/ext-tools-jev-member-badprovider.conf"
  {
    printf 'key_file=%s\n' "$KEY_FILE"
    printf 'provider=bogus\n'
  } > "$bad_provider_config"
  bad_provider_input="$(jq -cn --arg cp "$bad_provider_config" --arg body "$default_body" '{
    team: "ops", from: "alice", to: "jev-bot", body: $body,
    message_id: "m", config_path: $cp
  }')"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$bad_provider_input"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[bad provider] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "unknown provider"

  local bad_provider_test_log="$TEST_SKILL_DIR/jev-request-badprovider-test.json"
  _start_mock_openrouter MOCK_OPENROUTER_REQUEST_LOG="$bad_provider_test_log"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/setup" test "$bad_provider_config"
  [ "$status" -ne 0 ]
  jq -e '.ok == false and (.error | contains("unknown provider"))' <<<"$output" >/dev/null
  [ ! -e "$bad_provider_test_log" ]

  # --- contrast: a hostile ~/.curlrc must be ignored (review finding, #1339) ---
  # Without curl's -q as its FIRST argument, curl reads this user's curlrc,
  # and a curlrc enabling verbose/trace can print the Authorization header
  # to curl's own stderr -- which a transport failure folds straight into
  # handle's one-line reply, leaking the key into agmsg history. Proven here
  # by a curlrc that injects an extra header directive: if curl obeyed it,
  # the mock would see that header; -q means it never does.
  printf 'header = "X-From-Curlrc: yes"\n' > "$HOME/.curlrc"
  local curlrc_log="$TEST_SKILL_DIR/jev-request-curlrc.json"
  _start_mock_openrouter MOCK_OPENROUTER_REQUEST_LOG="$curlrc_log"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -eq 0 ]
  wait_for_file_contains "$curlrc_log" '"path"'
  [ "$(jq -r '.headers["X-From-Curlrc"] // "absent"' "$curlrc_log")" = "absent" ]
  rm -f "$HOME/.curlrc"

  # --- failure: AGMSG_JEV_API_BASE with an embedded newline cannot inject a
  # further curl -K directive (review finding, #1339) -- e.g. a second `header
  # = "Authorization: ..."` line aimed at a different host. This must fail
  # cleanly, in one line, without ever building a request to send anywhere
  # (rejected before curl is invoked at all).
  run env AGMSG_JEV_API_BASE=$'http://127.0.0.1:'"$MOCK_PORT"$'\nheader = "X-Injected: pwned"' \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[api base injection] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "invalid API base"
  refute grep -qF "or-test-key-do-not-print" <<<"$output"

  # --- failure: plain text (or any JSON without a "questions" key) is
  # refused, naming USAGE.md -- the bundled question-type mechanism this
  # used to fall back to (--question, tool.conf's default_question,
  # examples/) is gone; there is exactly one accepted shape now ---
  local plain_input
  plain_input="$(jq -cn --arg cp "$CONFIG_PATH" '{
    team: "ops", from: "alice", to: "jev-bot",
    body: "Investigate and fix a flaky CI job across two files.",
    message_id: "m", config_path: $cp
  }')"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$plain_input"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[plain text] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "USAGE.md"
  printf '%s\n' "$output" | grep -qF '"questions"'
  # Distinct from the "questions present but malformed" failure just below
  # -- both mention USAGE.md and "questions" (the hint is shared text), so
  # this pins down that it is genuinely the FIRST fail() (body isn't even
  # JSON-with-a-questions-key), not a fall-through to the second one.
  refute grep -qF "questions must be a JSON object" <<<"$output"

  # --- failure: malformed ad-hoc questions (not an object) ---
  local bad_adhoc_input
  bad_adhoc_input="$(jq -cn --arg cp "$CONFIG_PATH" '{
    team: "ops", from: "alice", to: "jev-bot",
    body: "{\"state\":\"x\",\"questions\":[1,2,3]}",
    message_id: "m", config_path: $cp
  }')"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$bad_adhoc_input"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[bad ad-hoc] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "questions must be a JSON object"

  # --- failure: no key file configured at all ---
  local no_key_config="$TEST_SKILL_DIR/ext-tools-jev-member-nokey.conf"
  : > "$no_key_config"
  local no_key_input
  no_key_input="$(jq -cn --arg cp "$no_key_config" '{
    team: "ops", from: "alice", to: "jev-bot", body: "hello",
    message_id: "m", config_path: $cp
  }')"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$no_key_input"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[no key] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "missing key_file"

  # --- failure: key file configured but missing on disk ---
  local missing_key_config="$TEST_SKILL_DIR/ext-tools-jev-member-missingkey.conf"
  printf 'key_file=%s\n' "$TEST_SKILL_DIR/does-not-exist.key" > "$missing_key_config"
  local missing_key_input
  missing_key_input="$(jq -cn --arg cp "$missing_key_config" '{
    team: "ops", from: "alice", to: "jev-bot", body: "hello",
    message_id: "m", config_path: $cp
  }')"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$missing_key_input"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[missing key file] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "key file not found or not readable"

  # --- failure: HTTP 401 ---
  _start_mock_openrouter MOCK_OPENROUTER_HTTP_STATUS=401
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[401] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "HTTP 401"

  # --- failure: HTTP 429 ---
  _start_mock_openrouter MOCK_OPENROUTER_HTTP_STATUS=429
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[429] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "HTTP 429"

  # --- failure: malformed response shape (200, but no usable "answers") ---
  _start_mock_openrouter MOCK_OPENROUTER_MALFORMED=1
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[malformed] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qF "unexpected response shape"

  # --- failure: transport failure (nothing listening) ---
  _start_mock_openrouter
  local dead_port="$MOCK_PORT"
  _stop_mock_openrouter
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$dead_port" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[transport] more than one line: $output" >&2; return 1 ;;
  esac
  refute grep -qF "or-test-key-do-not-print" <<<"$output"

  # --- failure: corrupt/multi-line key file is refused BEFORE curl runs ---
  # An unescaped embedded newline could otherwise end the `header = "..."`
  # config line early and let the rest of the key be read as a further curl
  # -K directive. Point at a real, logging fixture: if curl ran at all, the
  # log would exist.
  local bad_key_file="$TEST_SKILL_DIR/openrouter-multiline.key" \
    bad_config="$TEST_SKILL_DIR/ext-tools-jev-member-bad.conf" \
    bad_request_log="$TEST_SKILL_DIR/jev-request-bad.json"
  printf 'or-test-key-do-not-print\nSecond-Line-Injected\n' > "$bad_key_file"
  chmod 600 "$bad_key_file"
  printf 'key_file=%s\n' "$bad_key_file" > "$bad_config"
  _start_mock_openrouter MOCK_OPENROUTER_REQUEST_LOG="$bad_request_log"
  local bad_input
  bad_input="$(jq -cn --arg cp "$bad_config" \
    '{team: "ops", from: "alice", to: "jev-bot", body: "x", message_id: "m", config_path: $cp}')"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$bad_input"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[bad key] more than one line: $output" >&2; return 1 ;;
  esac
  printf '%s\n' "$output" | grep -qiF "single-line"
  refute grep -qF "Second-Line-Injected" <<<"$output"
  [ ! -e "$bad_request_log" ]

  # curl's OWN argv, inspected while a request is genuinely in flight: a
  # slow fixture holds the connection open long enough to read /bin/ps for
  # the curl child handle spawned, proving neither the key nor the body
  # ever appear there.
  _start_mock_openrouter MOCK_OPENROUTER_DELAY_SECONDS=3
  AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT" &
  local handle_pid=$!
  local curl_argv="" curl_pid attempt
  for attempt in $(seq 1 20); do
    for curl_pid in $(pgrep -x curl 2>/dev/null || true); do
      curl_argv="$(ps -o command= -p "$curl_pid" 2>/dev/null || true)"
      case "$curl_argv" in *agmsg-jev-curl*) break 2 ;; esac
      curl_argv=""
    done
    [ -n "$curl_argv" ] && break
    sleep 0.2
  done
  wait "$handle_pid" || true
  [ -n "$curl_argv" ]
  refute grep -qF "or-test-key-do-not-print" <<<"$curl_argv"
  refute grep -qF "Pick a color" <<<"$curl_argv"

  leftover_after="$(find "$tmp_root" -maxdepth 1 -name 'agmsg-jev-curl.*' 2>/dev/null | sort)"
  [ "$leftover_before" = "$leftover_after" ]
}
