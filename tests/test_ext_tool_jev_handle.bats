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

@test "jev handle: sends the right request, replies one line per question with 2+, and turns every failure into one line" {
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
  # Two questions (model, effort) -- each carries its OWN p/confidence from
  # the mock fixture's fixed answers, addressable by name, not one number
  # multiplied across both (review finding, #1367 follow-up: multiplying
  # rounds to 0.00 once there are enough questions, silently defeating
  # USAGE.md's own "don't act below 0.5-0.7 confidence" guidance). The
  # mock's response never actually depends on what questions were asked,
  # only the REQUEST assertions below prove those were sent correctly.
  # cost is the call's own usage.cost, rounded to 6 places.
  #
  # ONE LINE PER QUESTION with 2+ questions (this is the one case a
  # successful reply is not a single line -- exactly one question, and
  # every failure, still are; see the case checks elsewhere in this test).
  # The call's own aggregate cost is appended to the LAST line, since it
  # describes the whole call, not any single question.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "jev: model=sonnet (p=0.80, confidence=0.90)" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "effort=high (p=0.80, confidence=0.70) (cost \$0.000019)" ]

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
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "jev: model=sonnet (p=0.80, confidence=0.90)" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "effort=high (p=0.80, confidence=0.70) (tokens 441 in / 85 out)" ]
  refute grep -qF 'cost' <<<"$output"
  wait_for_file_contains "$typesafe_log" '"path"'
  [ "$(jq -r '.path' "$typesafe_log")" = "/v1/systemone" ]
  [ "$(jq -r '.body.model' "$typesafe_log")" = "jev-latest" ]

  # --- contrast: one malformed row among several does not fail the whole
  # call -- the fixture drops "effort"'s own choice, so its answer cannot
  # be rendered, but "model"'s real answer still has to come back. Failing
  # the entire batch over one bad row would throw away every other
  # question's genuine answer along with it. ---
  _start_mock_openrouter MOCK_OPENROUTER_BAD_ROW=1
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "jev: model=sonnet (p=0.80, confidence=0.90)" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "effort=error (malformed answer) (cost \$0.000019)" ]

  # --- contrast: one row whose answer VALUE is not an object at all (a
  # bare string, "oops") -- stricter than the missing-field case above,
  # since every field access on it, not just .choice, is a jq type error.
  # Unguarded, this fails the whole jq CALL and, under set -e, silently
  # ends the script with nothing on either stream -- "good"'s genuine
  # answer never comes back and no diagnosis is printed either (review
  # round 4). Same contract as the missing-field case: the other
  # question's real answer still has to come back, and this row renders
  # as its own error line. ---
  _start_mock_openrouter MOCK_OPENROUTER_BAD_ROW_STRING=1
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "jev: model=sonnet (p=0.80, confidence=0.90)" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "effort=error (malformed answer) (cost \$0.000019)" ]

  # --- contrast: a choice that is the literal STRING "null" is a genuine
  # answer, not a missing one -- `jq -r` turns a real JSON null and the
  # two-character string "null" into the identical output text, so a
  # downstream check comparing that text could not tell them apart (review
  # round 2: this exact confusion once made a valid answer render as
  # malformed). Exactly one question, so this also exercises the "row_count
  # == 1" reply path, which nothing else in this test reaches -- the
  # fixture's answer set is otherwise always two. ---
  _start_mock_openrouter MOCK_OPENROUTER_SINGLE_ANSWER=1 MOCK_OPENROUTER_CHOICE=null
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -eq 0 ]
  [ "$output" = 'jev: null (choice p=0.80, confidence=0.90, cost $0.000019)' ]

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

  # --- contrast: a choice name is whatever the CALLER put in `questions`
  # and is echoed straight back by the API -- handle never validates its
  # content -- so each answer's OWN line must stay exactly one line, and
  # its other values must stay correct, NO MATTER what that name contains.
  # (With 2 questions the reply itself is legitimately 2 lines now -- see
  # above -- so the property to hold here is "one line PER answer, never
  # more", not "the whole reply is one line".) One adversarial name mixing
  # every control character rounds 2-4 each found a fresh way to break,
  # rather than one test per character (review finding, #1364, rounds
  # 2-4): U+001F (could shift p/confidence/cost/tokens if response parsing
  # used it as an internal delimiter -- round 2), a newline and a CR
  # (could turn one answer's line into several -- round 3), ESC and TAB
  # (round 2 on the batch reply: _jev_one_line only escaped CR/LF, so any
  # OTHER C0 control character still reached the printed line raw -- the
  # actual property to hold; see _jev_one_line in _lib.sh, the single
  # choke point both this line and fail()'s route through).
  local weird_choice=$'sonnet\x1ffake-injected-field\nwith a newline\rand a CR\x1bESC\tTAB'
  _start_mock_openrouter MOCK_OPENROUTER_CHOICE="$weird_choice"
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -eq 0 ]
  # Exactly 2 lines (one per question) -- if the embedded newline/CR ever
  # leaked through unescaped, this would be 3+.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  # No raw C0 control byte (or DEL) anywhere in the output -- checked
  # directly, not by rebuilding the expected string, since that is the
  # actual property round 2 found missing.
  case "$output" in
    *$'\x1f'*|*$'\x1b'*|*$'\t'*) echo "[weird choice] a raw control byte reached the output: $output" >&2; return 1 ;;
  esac
  # $output holds the ESCAPED form (_jev_one_line turns a real newline/CR
  # into the two-character \n / \r, and every OTHER C0 control character --
  # and DEL -- into a single space, not a raw byte) -- build the same
  # escaped text here to check against, rather than the raw $weird_choice.
  local escaped_choice="${weird_choice//$'\r'/\\r}"
  escaped_choice="${escaped_choice//$'\n'/\\n}"
  escaped_choice="$(printf '%s' "$escaped_choice" | tr '\000-\037\177' ' ')"
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "jev: model=${escaped_choice} (p=0.80, confidence=0.90)" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "effort=high (p=0.80, confidence=0.70) (cost \$0.000019)" ]

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

  # --- failure: HTTP 400, request too large for one call -- named on its
  # own rather than falling into the generic "unexpected HTTP 400" line,
  # so the caller knows to split the batch instead of retrying as-is. This
  # is OpenRouter's REAL body shape (the default provider, and the
  # fixture's default 400 payload): detail.error_type wrapped as a STRING
  # inside error.message, not at the top level -- an earlier version of
  # this check only looked at the top level and missed every one of these
  # in production (a live Banking77 call at 100 questions fell through to
  # the generic line below instead; confirmed against the real API,
  # 2026-09-24, a 400 carries no charge). ---
  _start_mock_openrouter MOCK_OPENROUTER_HTTP_STATUS=400
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[400] more than one line: $output" >&2; return 1 ;;
  esac
  [ "$output" = "jev: request too large for one call (max_tokens_exceeded) -- split the questions into smaller batches" ]

  # --- contrast: the OTHER shape that reaches the same message -- a
  # DIRECT call's flat, top-level detail.error_type (TypeSafe's own native
  # API returns it exactly like this, never wrapped) -- still recognized ---
  _start_mock_openrouter MOCK_OPENROUTER_HTTP_STATUS=400 MOCK_OPENROUTER_400_FLAT_SHAPE=1
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[400 flat shape] more than one line: $output" >&2; return 1 ;;
  esac
  [ "$output" = "jev: request too large for one call (max_tokens_exceeded) -- split the questions into smaller batches" ]

  # --- contrast: a 400 whose detail.error_type is something else, and
  # only mentions "max_tokens_exceeded" in unrelated free text, must NOT
  # get the specific line above -- a substring match anywhere in the body
  # would misdiagnose this as the wrong failure (review round 2) ---
  _start_mock_openrouter MOCK_OPENROUTER_HTTP_STATUS=400 MOCK_OPENROUTER_400_CODE_MISMATCH=1
  run env AGMSG_JEV_API_BASE="http://127.0.0.1:$MOCK_PORT" \
    "$SCRIPTS/drivers/ext-tools/jev/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *$'\n'*) echo "[400 code mismatch] more than one line: $output" >&2; return 1 ;;
  esac
  [ "$output" = "jev: unexpected HTTP 400" ]

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
