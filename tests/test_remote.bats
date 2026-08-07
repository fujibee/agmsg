#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Reset here, not at the end of the case that changes it: bats runs every
  # test in this same shell, so a knob left set would quietly reconfigure the
  # server for each later test — and a case that fails early never gets to
  # put it back.
  MOCK_TEAM_CIPHER_PROFILE=age-v1
  MOCK_CONNECT_STATUS=""
  export MOCK_CONNECT_STATUS
  export PEER_SKILL_DIR=""
  # Some cases deliberately remove python3 from PATH to verify the control-plane
  # gate. Resolve the fixture interpreter in each test process before that
  # system under test changes its environment.
  MOCK_PYTHON3="$(command -v python3)"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  # Start the mock remote server on an OS-assigned port.
  MOCK_PULL_MIXED="${MOCK_PULL_MIXED:-}" \
  MOCK_PULL_AGE="${MOCK_PULL_AGE:-}" \
  MOCK_PULL_AGE_ENVELOPE_FILE="${MOCK_PULL_AGE_ENVELOPE_FILE:-}" \
  MOCK_PULL_TEAM_ID="${MOCK_PULL_TEAM_ID:-}" \
  MOCK_HEALTH_TEAM_ID="${MOCK_HEALTH_TEAM_ID:-}" \
  MOCK_CONNECT_NO_AGE="${MOCK_CONNECT_NO_AGE:-}" \
  MOCK_CONNECT_TEAM_NAME="${MOCK_CONNECT_TEAM_NAME:-}" \
  MOCK_CONNECT_STATUS="${MOCK_CONNECT_STATUS:-}" \
  MOCK_TEAM_CIPHER_PROFILE="${MOCK_TEAM_CIPHER_PROFILE-age-v1}" \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
  CAPABILITY_SECRET="agsy_do_not_print_this_token"
}

cleanup_sync_engines() {
  local root="$1" label="$2" cleanup_status=0 pidfile pid
  [ -d "$root" ] || return 0
  for pidfile in "$root"/run/remote-sync.*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if ! [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]]; then
      echo "invalid $label sync engine PID in $pidfile: $pid" >&2
      cleanup_status=1
      continue
    fi
    kill "$pid" 2>/dev/null || true
    if ! wait_for_pid_exit "$pid"; then
      echo "$label sync engine $pid did not exit after TERM; sending KILL" >&2
      kill -KILL "$pid" 2>/dev/null || true
      if ! wait_for_pid_exit "$pid"; then
        echo "$label sync engine $pid survived KILL; preserving $root" >&2
        cleanup_status=1
      fi
    fi
  done
  return "$cleanup_status"
}

teardown() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  wait "$MOCK_SERVER_PID" 2>/dev/null || true

  local cleanup_status=0
  if ! cleanup_sync_engines "$TEST_SKILL_DIR" "primary"; then
    cleanup_status=1
  fi
  if [ -n "${PEER_SKILL_DIR:-}" ] && [ -d "$PEER_SKILL_DIR" ]; then
    if cleanup_sync_engines "$PEER_SKILL_DIR" "peer"; then
      rm -rf "$PEER_SKILL_DIR"
    else
      cleanup_status=1
    fi
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    teardown_test_env
  fi
  return "$cleanup_status"
}

restart_mock_server() {
  kill "$MOCK_SERVER_PID" 2>/dev/null || true
  wait "$MOCK_SERVER_PID" 2>/dev/null || true
  : > "$TEST_SKILL_DIR/server.port"
  MOCK_PULL_MIXED="${MOCK_PULL_MIXED:-}" \
  MOCK_PULL_AGE="${MOCK_PULL_AGE:-}" \
  MOCK_PULL_AGE_ENVELOPE_FILE="${MOCK_PULL_AGE_ENVELOPE_FILE:-}" \
  MOCK_PULL_TEAM_ID="${MOCK_PULL_TEAM_ID:-}" \
  MOCK_HEALTH_TEAM_ID="${MOCK_HEALTH_TEAM_ID:-}" \
  MOCK_CONNECT_NO_AGE="${MOCK_CONNECT_NO_AGE:-}" \
  MOCK_CONNECT_TEAM_NAME="${MOCK_CONNECT_TEAM_NAME:-}" \
  MOCK_CONNECT_STATUS="${MOCK_CONNECT_STATUS:-}" \
  MOCK_TEAM_CIPHER_PROFILE="${MOCK_TEAM_CIPHER_PROFILE-age-v1}" \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
      </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_SERVER_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  MOCK_PORT="$(cat "$TEST_SKILL_DIR/server.port")"
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
}

skip_if_no_age() {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 ||
    skip "age/age-keygen not installed"
}

# --- doctor ------------------------------------------------------------

@test "remote doctor: passes when age is installed" {
  command -v age >/dev/null 2>&1 || skip "age not installed"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"age / age-keygen on PATH"* ]]
  [[ "$output" == *"All checks passed."* ]]
}

@test "remote doctor: is read-only (no token required, no state touched)" {
  run bash "$SCRIPTS/remote.sh" doctor testteam
  run grep -c "remote_binding" "$SCRIPTS/../teams/testteam/config.json"
  [ "$output" -eq 0 ]
}

# --- connect: endpoint/response validation (B6) --------------------------

@test "connect: refuses a non-HTTPS, non-loopback endpoint" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://example.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses an endpoint with no scheme at all" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "example.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must start with https://"* ]]
}

@test "connect: http://127.0.0.1 (loopback) is accepted without https" {
  # Loopback passes endpoint validation, then connect proceeds to register a
  # real local team. testteam was minted with a team_id in setup().
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
}

# --- #143: a connect that already registered must not dead-end -------------
#
# Registration commits on the server in one transaction, and the binding is
# written locally only after a 200. So the only thing a failed connect can
# leave behind is local, derived state -- and the way back in is to skip the
# step that is already done, never to undo it.

_binding_field() {  # $1 = team, $2 = json path under remote_binding
  local cfg="$TEST_SKILL_DIR/teams/$1/config.json" resolved escaped
  resolved="$(rf "$cfg")"
  # Double the quotes: a team name may contain one, and the path goes inside a
  # SQL string literal. The unescaped form ends the literal on such a team --
  # the same class of bug this test exists to catch, one layer up.
  escaped="$(printf '%s' "$resolved" | sed "s/'/''/g")"
  sqlite_mem "SELECT coalesce(json_extract(CAST(readfile('$escaped') AS TEXT), '\$.remote_binding.$2'), '');"
}

@test "connect: a POST that committed but lost its response recovers on retry (#143)" {
  # Arm the cut: the next /v1/connect registers the team and answers nothing.
  run curl -sS "$ENDPOINT/_test/drop-next-connect"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -ne 0 ]
  # Nothing recorded: the binding is only ever written after a 200. This is
  # exactly the state a lost response leaves -- registered there, unknown here.
  [ "$(_binding_field testteam server_instance_id)" = "" ]

  # Before #143 this retry was a 409 dead end with no way out but recreating
  # the team (and losing its local history).
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopting that registration"* ]]
  [ -n "$(_binding_field testteam server_instance_id)" ]
  [ "$(_binding_field testteam remote_team_name)" = "testteam" ]
}

@test "connect: refuses to re-anchor a binding to a different server instance (#143)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  local anchored
  anchored="$(_binding_field testteam server_instance_id)"
  [ -n "$anchored" ]

  # Same address, different server. The registration is still there and the
  # team_id, name and roster all still match -- the recorded instance id is
  # the only thing that can tell these apart, which is why requiring it to
  # merely EXIST is not the same as checking it.
  run curl -sS "$ENDPOINT/_test/rotate-server-id"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to re-anchor"* ]]
  # The binding still points at the server it was made against.
  [ "$(_binding_field testteam server_instance_id)" = "$anchored" ]

  # And the way out the refusal names has to WORK. disconnect drops the claim
  # on the old anchor; the connect after it must get through, not land back on
  # the same refusal. A refusal with no reachable next state is the defect this
  # whole change exists to remove.
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [[ "$output" != *"Refusing to re-anchor"* ]]
  [ "$(_binding_field testteam server_instance_id)" != "$anchored" ]
}

@test "connect: a repeat run cannot restate the registered cipher profile (#143)" {
  # Declaring age-v1 means minting a key, so this one needs age. The refusal
  # itself does not -- the quoting it prints is covered without age in
  # test_shquote.bats, at the function that owns it.
  skip_if_no_age
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -eq 0 ]
  [ "$(_binding_field testteam cipher_profile)" = "age-v1" ]

  # Plain re-run of an age-v1 registration. Recording 'none' here would be a
  # downgrade written by a retry, against a server that still says age-v1.
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"registered on"*"as 'age-v1'"* ]]
  [ "$(_binding_field testteam cipher_profile)" = "age-v1" ]

  # The refusal must name a change this CLI accepts, and then that change must
  # actually work. It names the flag rather than a whole command because the
  # endpoint can carry a capability and this line is read off a terminal --
  # so the test performs the named change instead of pasting a printed string.
  [[ "$output" != *"Re-run connect for"* ]]
  [[ "$output" == *"re-run the same connect for"* ]]
  [[ "$output" == *"with --e2ee added"* ]]
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -eq 0 ]
  [ "$(_binding_field testteam cipher_profile)" = "age-v1" ]
}

@test "connect: the printed recovery command is shell-safe for a hostile team name (#143)" {
  # This asserts the CALL SITE, not the helper. tests/test_shquote.bats pins
  # what agmsg_shq does; nothing there stops remote.sh from going back to a
  # bare '$team', and the case that would catch it needs age and so never runs
  # in CI. This one needs nothing installed: the server's declaration is set
  # directly, so the client is never asked to MAKE an age-v1 declaration.
  local team="it's a team"
  run bash "$SCRIPTS/join.sh" "$team" alice claude-code /tmp/project-quote
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$team"
  [ "$status" -eq 0 ]

  run curl -sS --get --data-urlencode "team_name=$team" --data-urlencode "profile=age-v1" \
    "$ENDPOINT/_test/declare-cipher"
  [ "$status" -eq 0 ]
  [[ "$output" == *"age-v1"* ]]

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$team"
  [ "$status" -ne 0 ]
  # Hold the refusal itself: $output is about to be the eval's result, and
  # asserting the endpoint's absence against THAT would be true of anything.
  local msg="$output" printed
  printed="$(printf '%s\n' "$msg" \
    | sed -n "s/.*re-run the same connect for \(.*\) with --e2ee added\..*/\1/p")"
  [ -n "$printed" ]

  # The real assertion: a shell parsing that fragment gets the team back as ONE
  # argument, byte for byte. With a bare '$team' the quote closes early and
  # this either fails to parse or splits into several arguments.
  run eval "set -- $printed; printf '%s|%s' \"\$#\" \"\$1\""
  [ "$status" -eq 0 ]
  [ "$output" = "1|$team" ]

  # And the endpoint is not reproduced in the refusal: it can carry a
  # capability, and this line is meant to be read off a terminal.
}

# --- #143: nothing this path prints may carry the capability ---------------
#
# A hosted endpoint is `https://host/t/<token>` and that token IS the
# permission. These assert on the BYTES OF A RUN, not on the source. An
# earlier version of this guard read remote.sh looking for output statements
# and was wrong three times running: it saw only a literal `$endpoint` on the
# same physical line as `echo`, then only `echo|printf` -- while `${endpoint}`,
# line continuations, `cat` with a here-doc, `tee` and a redirected block are
# all ordinary ways to write the same leak. Enumerating how a program can
# print something loses by one, every time. What the user sees does not depend
# on which primitive produced it, so that is what is checked.
#
# Every branch of _remote_adopt_registration that prints the endpoint is driven
# below. A new branch belongs here too.

# Fails if the capability appears in anything the command wrote. The expected
# substring is required as well: "the token is absent" is trivially true of no
# output, and would keep passing if the message were deleted or renamed.
assert_no_capability() {  # $1 = expected substring, rest = command
  local expect="$1"; shift
  run "$@"
  [[ "$output" == *"$expect"* ]] || {
    echo "expected to see: $expect"; echo "actual output: $output"; return 1; }
  [[ "$output" != *"$CAPABILITY_SECRET"* ]] || {
    echo "TOKEN LEAKED in: $output"; return 1; }
  [[ "$output" != *"/t/"* ]] || {
    echo "capability PATH leaked in: $output"; return 1; }
}

# NOT a command substitution: that runs in a subshell, so an assignment inside
# it is thrown away and the secret would be the empty string -- which every
# output contains, making the leak check pass on anything. CAPABILITY_SECRET is
# set in setup() instead.
_capability_endpoint() {
  printf '%s' "$ENDPOINT/t/$CAPABILITY_SECRET"
}

@test "redaction: adoption success does not print the capability (#143)" {
  local cap; cap="$(_capability_endpoint)"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
  assert_no_capability "adopting that registration" \
    bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
}

@test "redaction: an unreadable capabilities response does not print it (#143)" {
  local cap; cap="$(_capability_endpoint)"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
  curl -sS "$ENDPOINT/_test/fail-next?route=capabilities" >/dev/null
  assert_no_capability "capabilities could not be read" \
    bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
}

@test "redaction: an unreadable roster response does not print it (#143)" {
  local cap; cap="$(_capability_endpoint)"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
  curl -sS "$ENDPOINT/_test/fail-next?route=members" >/dev/null
  assert_no_capability "roster could not be read" \
    bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
}

@test "redaction: a server-instance mismatch does not print it (#143)" {
  local cap; cap="$(_capability_endpoint)"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
  curl -sS "$ENDPOINT/_test/rotate-server-id" >/dev/null
  assert_no_capability "Refusing to re-anchor" \
    bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
}

@test "redaction: a team-name mismatch does not print it (#143)" {
  local cap; cap="$(_capability_endpoint)"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
  curl -sS --get --data-urlencode "from=testteam" --data-urlencode "to=someone-elses" \
    "$ENDPOINT/_test/rename-team" >/dev/null
  assert_no_capability "not this team's" \
    bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
}

@test "redaction: a roster mismatch does not print it (#143)" {
  local cap; cap="$(_capability_endpoint)"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" updated
  updated="$(sqlite_mem "SELECT json_set(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents.intruder', json_object('member_id', '018f3f7e-9999-7000-8000-00000000cafe'));")"
  printf '%s' "$updated" > "$cfg"
  assert_no_capability "roster is not this team's" \
    bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
}

@test "redaction: a cipher-profile mismatch does not print it (#143)" {
  local cap; cap="$(_capability_endpoint)"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
  curl -sS --get --data-urlencode "team_name=testteam" --data-urlencode "profile=age-v1" \
    "$ENDPOINT/_test/declare-cipher" >/dev/null
  assert_no_capability "Refusing to record a profile" \
    bash "$SCRIPTS/remote.sh" connect --endpoint "$cap" testteam
}

@test "redaction: the helper drops path, query, fragment and userinfo (#143)" {
  # The one source-level claim kept: it is about the helper's own behaviour,
  # not about who remembers to call it.
  eval "$(sed -n '/^_remote_endpoint_display() {/,/^}/p' "$SCRIPTS/remote.sh")"
  [ "$(_remote_endpoint_display 'https://host/t/secret')" = "https://host" ]
  [ "$(_remote_endpoint_display 'https://user:tok@host/t/secret')" = "https://host" ]
  [ "$(_remote_endpoint_display 'https://host/t/secret?q=1#frag')" = "https://host" ]
  [ "$(_remote_endpoint_display 'http://127.0.0.1:8080')" = "http://127.0.0.1:8080" ]
  [ "$(_remote_endpoint_display 'https://host/a@b/c')" = "https://host" ]
}

@test "connect: refuses to adopt a registration whose roster is not this team's (#143)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]

  # Give the local team a member the server's registration does not have. The
  # team_id still matches, so only the roster check can tell these apart --
  # and adopting on a name match alone would be the bug.
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json"
  local updated
  updated="$(sqlite_mem "SELECT json_set(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents.intruder', json_object('member_id', '018f3f7e-9999-7000-8000-00000000dead'));")"
  printf '%s' "$updated" > "$cfg"

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"roster is not this team's"* ]]
  [[ "$output" == *"real conflict"* ]]
}

@test "connect: the capability path never reaches the terminal" {
  # A hosted endpoint is `https://host/t/<token>` and that token IS the
  # capability -- read it off a terminal, a screen share or a pasted log and you
  # can connect as this team. `connect` printed the whole URL twice, on every
  # run, for every user.
  #
  # The assertion is that the secret is ABSENT, so it has to also assert that
  # the line was printed at all: "no token in the output" is trivially true of
  # no output, and would keep passing if the message were deleted or renamed.
  local secret="agsy_do_not_print_this_token"
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT/t/$secret" testteam
  [[ "$output" == *"Connecting team 'testteam' to"* ]]
  [[ "$output" == *"127.0.0.1:$MOCK_PORT"* ]]
  [[ "$output" != *"$secret"* ]]
  [[ "$output" != *"/t/"* ]]
}

@test "connect: the capability path is absent from the FAILURE message too" {
  # The failure line matters more than the progress line: successful output
  # scrolls past, failing output gets pasted -- into a bug report, a chat, a
  # screenshot -- and is then stored, forwarded and searchable.
  #
  # The status is forced by the fixture rather than by pointing at a port
  # nobody is listening on. A free port is not state this test owns: anything
  # on the runner may be bound to it, and then the POST succeeds and the branch
  # under test never runs. The mock is started by this suite, so its answer is
  # ours to decide.
  #
  # Reaching the line is asserted too. "The token is not in the output" is also
  # true of output that never mentioned the endpoint at all.
  MOCK_CONNECT_STATUS=503
  export MOCK_CONNECT_STATUS
  restart_mock_server
  local secret="agsy_do_not_print_this_token"
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT/t/$secret" testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"connect failed"* ]]
  [[ "$output" == *"returned HTTP 503"* ]]
  [[ "$output" == *"127.0.0.1:$MOCK_PORT"* ]]
  [[ "$output" != *"$secret"* ]]
  [[ "$output" != *"/t/"* ]]
}

@test "the endpoint shown on the terminal keeps only scheme, host and port" {
  # Unit-level, because `connect` cannot reach the interesting inputs: the
  # validator refuses userinfo outright (see the loopback-bypass test below),
  # so that branch of the redactor is defence in depth and has to be exercised
  # here or not at all. Query and fragment are the same -- no endpoint carries
  # one today, which is exactly why one would slip through when it does.
  # shellcheck disable=SC1090
  eval "$(sed -n '/^_remote_endpoint_display()/,/^}/p' "$SCRIPTS/remote.sh")"
  [ "$(_remote_endpoint_display "http://127.0.0.1:8797/t/SECRET")" = "http://127.0.0.1:8797" ]
  [ "$(_remote_endpoint_display "https://u:pa55@example.com/t/SECRET")" = "https://example.com" ]
  [ "$(_remote_endpoint_display "https://example.com?token=SECRET")" = "https://example.com" ]
  [ "$(_remote_endpoint_display "https://example.com#SECRET")" = "https://example.com" ]
  # An `@` inside the path must not be read as the end of the userinfo.
  [ "$(_remote_endpoint_display "https://a@b@evil.example/t/SECRET")" = "https://evil.example" ]
  [ "$(_remote_endpoint_display "http://[::1]:8080/t/SECRET")" = "http://[::1]:8080" ]
  # Port survives -- it is how two local servers are told apart.
  [ "$(_remote_endpoint_display "https://host.example.com:443")" = "https://host.example.com:443" ]
}

@test "connect: the out-of-band handoff line is printed by default" {
  skip_if_no_age
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Export the public epoch snapshot"* ]]
  [[ "$output" == *"out of band"* ]]
}

@test "connect: a caller that owns the guidance does not get the out-of-band line" {
  skip_if_no_age
  # Carrying the key by hand is this install's answer to adding a machine. A
  # tool with a ceremony for that would have its operator talked out of it --
  # into doing by hand exactly what the ceremony exists to prevent.
  #
  # Paired with the test above deliberately: absence alone would pass for a
  # connect that printed nothing, and presence alone would pass for a
  # suppression that never fires.
  AGMSG_OPERATOR_GUIDANCE=caller run bash "$SCRIPTS/remote.sh" connect \
    --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -eq 0 ]
  # The result is still reported -- only the next step is withheld.
  [[ "$output" == *"Connected: team 'testteam'"* ]]
  [[ "$output" != *"Export the public epoch snapshot"* ]]
  [[ "$output" != *"out of band"* ]]
}

@test "connect: requires the response protocol header" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" missing-protocol-header-token myteam
  [ "$status" -ne 0 ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" wrong-protocol-header-token myteam
  [ "$status" -ne 0 ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
}

@test "connect: rejects capability limits that differ from the engine validator" {
  for token in max-blob-zero-token max-blob-over-token future-policy-boundary-token; do
    run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
    [ "$status" -ne 0 ]
    [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
  done
}

@test "connect: bounds response body and header capture before validation" {
  for token in large-body-token large-header-token; do
    run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$token" myteam
    [ "$status" -ne 0 ]
    [ ! -f "$SCRIPTS/../run/remote-credentials/myteam.json" ]
  done
}

@test "connect: refuses subdomain-suffix bypass of the loopback exception (127.0.0.1.evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://127.0.0.1.evil.invalid:${MOCK_PORT}" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses subdomain-suffix bypass of the loopback exception (localhost.evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://localhost.evil.invalid:${MOCK_PORT}" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be https://"* ]]
}

@test "connect: refuses the userinfo bypass of the loopback exception (localhost@evil.com)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "http://localhost@evil.invalid" good-token myteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"userinfo"* ]]
}

# --- connect -------------------------------------------------------------

@test "connect: registers a client-owned team (happy path, Done-when 1)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # Same name on both sides — the ordinary case — so the line says it once.
  [[ "$output" == *"Connected: team 'testteam' (plain)."* ]]
  [[ "$output" != *"org"* ]]
  # A binding is recorded on the team config, and it carries no credential:
  # the register model writes none and none is fetched back.
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$SCRIPTS/../teams/testteam/config.json') AS TEXT), '\$.remote_binding.connected_at');")" != "" ]
  [ ! -f "$SCRIPTS/../run/remote-credentials/testteam.json" ]
}

@test "connect: when the server's name differs, it is quoted AS the server's — never as an org" {
  # Every other connect case here asks for a team whose remote name comes back
  # identical, so the two names cannot be told apart in the output. That is how
  # this line spent its life calling the server's TEAM name an "org": while the
  # strings match, a wrong label reads as a redundant one. Only a differing
  # pair can see it, so this test makes them differ.
  MOCK_CONNECT_TEAM_NAME="renamed-upstream"
  export MOCK_CONNECT_TEAM_NAME
  teardown
  setup

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # The local name leads; the server's is offered as the server's.
  [[ "$output" == *"Connected: team 'testteam' (on the server: 'renamed-upstream') (plain)."* ]]
  # And nothing in this output claims to be an org: the connect response
  # carries server_instance_id / team_id / team_name / min_available_seq, and
  # no org at all, so there is nothing here that could honestly be labelled one.
  [[ "$output" != *"org"* ]]
}

@test "connect --e2ee generates a key and establishes age-v1 before engine start" {
  skip_if_no_age

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connected: team 'testteam' (age-v1 encrypted)."* ]]
  [[ "$output" == *"Back this up now"* ]]
  [[ "$output" == *"key.sh show testteam --snapshot --out <file>"* ]]
  sync_config="$TEST_SKILL_DIR/db/remote-sync/testteam.json"
  [ -f "$sync_config" ]
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$sync_config")') AS TEXT), '\$.cipher_profile');")" = "age-v1" ]
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$sync_config")') AS TEXT), '\$.local_security_history[0].minimum_security_mode');")" = "e2ee-required" ]
  [ -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"encryption: age-v1, key present"* ]]
}

@test "connect defaults to plain even when the team already has a key" {
  skip_if_no_age
  bash "$SCRIPTS/key.sh" generate testteam

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"plain sync was selected"* ]]
  [[ "$output" == *"pass --e2ee"* ]]
  [ ! -f "$TEST_SKILL_DIR/db/remote-sync/testteam.json" ]
  [ -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"encryption: none (local key is not used by this binding)"* ]]
}

@test "connect: a keyed team fails closed when the remote disallows age-v1" {
  skip_if_no_age
  MOCK_CONNECT_NO_AGE=1
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not allow age-v1"* ]]
  [[ "$output" == *"refusing to fall back to plaintext"* ]]
  [ ! -f "$TEST_SKILL_DIR/db/remote-sync/testteam.json" ]
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}

@test "connect: moves the team into its own per-team store (Done-when 2)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # A connected team's rows are migrated out of the shared store into a
  # per-team one; connect exits non-zero if that migration fails.
  run find "$TEST_SKILL_DIR" -path '*teams/testteam/messages.db'
  [ -n "$output" ]
}

@test "connect: starts a background sync engine that disconnect stops (Done-when 4)" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  local pidfile="$SCRIPTS/../run/remote-sync.testteam.pid"
  wait_for_file "$pidfile"
  bash "$SCRIPTS/remote.sh" disconnect testteam
  wait_for_missing "$pidfile"
}

@test "connect: mints team_id and member_ids for a team that predates local ids" {
  # A legacy team: agents but no team_id, members with no member_id. Give it an
  # initialized store so the connect-time migration has something to move.
  mkdir -p "$TEST_SKILL_DIR/teams/legacyteam"
  printf '{"name":"legacyteam","agents":{"alice":{"type":"claude-code"},"bob":{"type":"codex"}},"created_at":"2026-01-01T00:00:00Z"}\n' \
    > "$TEST_SKILL_DIR/teams/legacyteam/config.json"
  bash -c '. "$1/scripts/lib/storage.sh"; agmsg_storage_load; storage_init "$2" >/dev/null' \
    x "$SCRIPTS/.." legacyteam
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" legacyteam
  [ "$status" -eq 0 ]
  local cfg="$TEST_SKILL_DIR/teams/legacyteam/config.json"
  # The whole roster is now id-holding (all-or-none): a team_id and a member_id
  # for every member, minted at connect.
  [[ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.team_id');")" =~ ^[0-9a-f]{8}- ]]
  [ -n "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents.alice.member_id');")" ]
  [ -n "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents.bob.member_id');")" ]
}

@test "connect: a second connect does not re-register, it resumes (Done-when 5, #143)" {
  # This test used to assert the opposite -- that a repeat connect FAILED with
  # "already registered". That assertion was the dead end #143 reports: the
  # same team, with the same roster, could never finish a connect whose later
  # steps had failed. The server's rule is unchanged and still right (a team_id
  # registers once, refused like a non-fast-forward push); what changed is that
  # the client no longer sends a registration it can see is already done.
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  local first_revision
  first_revision="$(_binding_field testteam binding_revision)"

  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopting that registration"* ]]
  # No POST was attempted: the announcement that precedes it is absent, and a
  # POST here would have been refused 409.
  [[ "$output" != *"Connecting team"* ]]
  [[ "$output" != *"already registered on this remote"* ]]
  [ "$(_binding_field testteam binding_revision)" -gt "$first_revision" ]
}

# --- status --------------------------------------------------------------

@test "status: reports 'never connected' for an unknown team" {
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"never been connected"* ]]
}

@test "status: with no <team> lists every locally-known connected team" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  bash "$SCRIPTS/join.sh" secondteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" secondteam >/dev/null
  run bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"testteam"* ]]
  [[ "$output" == *"secondteam"* ]]
}

# --- connect: pending/resume (B5) -----------------------------------------

# --- disconnect ------------------------------------------------------------

@test "disconnect: stops the engine and clears local state" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disconnected 'testteam'. Local sync state cleared"* ]]
  [[ "$output" != *"Revoking credential"* ]]
  [[ "$output" != *"revoke it from the console"* ]]
  # The binding is marked disconnected locally. No server round-trip is needed
  # because the current connect model does not create a server credential.
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$SCRIPTS/../teams/testteam/config.json') AS TEXT), '\$.remote_binding.disconnected_at');")" != "" ]
}

@test "disconnect: a pulled no-auth team does not report a failed credential revoke" {
  local pull_team_id="018f3f7e-2222-7000-8000-000000000002"
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" \
    --team-id "$pull_team_id" cloned
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/remote.sh" disconnect cloned
  [ "$status" -eq 0 ]
  [[ "$output" == *"Disconnected 'cloned'. Local sync state cleared"* ]]
  [[ "$output" != *"Revoking credential"* ]]
  [[ "$output" != *"revoke it from the console"* ]]
}

@test "disconnect: refuses when the binding was replaced after it chose one" {
  # The generation guard, on a binding with no credential -- which is every
  # binding now. disconnect decides what to unbind from one snapshot, then stops
  # the engine, then writes. A reconnect landing in that gap installs a NEWER
  # binding, and marking THAT disconnected would tear down a connection this
  # call never touched.
  #
  # Ordered by a synchronisation primitive, not by a delay. The stand-in engine
  # traps TERM and reports it: receiving TERM proves disconnect has already
  # taken its snapshot and is inside the engine stop, which is exactly the gap.
  # The replacement lands there, and only then is the engine let go.
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  local cfg="$SCRIPTS/../teams/testteam/config.json"
  local pidfile="$SCRIPTS/../run/remote-sync.testteam.pid"
  local termed="$TEST_SKILL_DIR/engine-termed"
  local release="$TEST_SKILL_DIR/engine-release"

  # Replace the real engine with one that stops when we say so. Its argv has to
  # end the way the status check expects, or the stop declines to reap it.
  local real_pid; real_pid="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$real_pid" ] && kill "$real_pid" 2>/dev/null
  TERMED="$termed" RELEASE="$release" bash -c '
    trap "touch \"$TERMED\"" TERM
    while [ ! -f "$RELEASE" ]; do sleep 0.02; done
  ' "$SCRIPTS/internal/remote-sync.mjs" run --team testteam &
  local fake=$!
  echo "$fake" > "$pidfile"

  bash "$SCRIPTS/remote.sh" disconnect testteam > "$TEST_SKILL_DIR/dc.out" 2>&1 &
  local dc=$!

  # Wait for the seam itself, not for a duration.
  local i
  for i in $(seq 1 300); do
    [ -f "$termed" ] && break
    sleep 0.02
  done
  [ -f "$termed" ] || { echo "disconnect never reached the engine stop"; false; }

  # A concurrent reconnect: same team, newer generation.
  python3 - "$cfg" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
binding = document["remote_binding"]
binding["binding_revision"] = int(binding.get("binding_revision") or 0) + 1
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(document, handle)
    handle.write("\n")
PY

  touch "$release"
  local dc_status=0
  wait "$dc" || dc_status=$?
  wait "$fake" 2>/dev/null || true
  local out; out="$(cat "$TEST_SKILL_DIR/dc.out")"
  echo "disconnect exited $dc_status; output: $out"

  [ "$dc_status" -ne 0 ] || { echo "disconnect succeeded against a replaced binding"; false; }
  [[ "$out" == *"binding changed to something else during disconnect"* ]]
  # ...and the newer binding is still active.
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$cfg') AS TEXT), '\$.remote_binding.disconnected_at');")" = "" ]
}

@test "disconnect: no replacement can land while the engine it chose is being stopped" {
  # The half the generation check cannot cover. connect writes its binding under
  # the team lock and starts the engine after releasing it, so a reconnect
  # landing between disconnect's snapshot and an unlocked stop would have ITS
  # engine killed by a call that then refuses to write. The stop therefore
  # happens inside the same hold as the snapshot.
  #
  # Observed by exclusion rather than by racing: while disconnect is inside the
  # stop, a separate process asks for the same lock with a short retry budget
  # and must be refused. Nothing here depends on who wins a lock -- being shut
  # out IS the invariant.
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  local pidfile="$SCRIPTS/../run/remote-sync.testteam.pid"
  local termed="$TEST_SKILL_DIR/engine-termed"
  local release="$TEST_SKILL_DIR/engine-release"

  local real_pid; real_pid="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$real_pid" ] && kill "$real_pid" 2>/dev/null
  # argv has to end the way _remote_sync_engine_status expects, or the stop
  # declines to reap it and the seam is never reached.
  TERMED="$termed" RELEASE="$release" bash -c '
    trap "touch \"$TERMED\"" TERM
    while [ ! -f "$RELEASE" ]; do sleep 0.02; done
  ' "$SCRIPTS/internal/remote-sync.mjs" run --team testteam &
  local engine=$!
  echo "$engine" > "$pidfile"

  bash "$SCRIPTS/remote.sh" disconnect testteam > "$TEST_SKILL_DIR/dc.out" 2>&1 &
  local dc=$!

  local i
  for i in $(seq 1 300); do [ -f "$termed" ] && break; sleep 0.02; done
  [ -f "$termed" ] || { echo "disconnect never reached the engine stop"; false; }

  # A would-be replacement writer, while the stop is in progress.
  run env AGMSG_LOCK_TRIES=5 SCRIPTS="$SCRIPTS" bash -c '
    . "$SCRIPTS/lib/registry-lock.sh"
    agmsg_lock_acquire "$SCRIPTS/../teams/testteam"
  '
  [ "$status" -ne 0 ] || {
    echo "the lock was available during the engine stop: a reconnect could have landed"
    false
  }
  [[ "$output" == *"timed out acquiring registry lock"* ]]

  touch "$release"
  local dc_status=0
  wait "$dc" || dc_status=$?
  wait "$engine" 2>/dev/null || true
  # Nothing was contending, so the disconnect itself completes normally.
  [ "$dc_status" -eq 0 ] || { echo "disconnect failed: $(cat "$TEST_SKILL_DIR/dc.out")"; false; }
}

@test "disconnect: fails for a team that isn't connected" {
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not connected"* ]]
}

# --- status --json (ADR 0007 addendum) --------------------------------------

@test "status --json: reports the strict schema for an active connection" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.local_team');")" = "testteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.endpoint');")" = "$ENDPOINT" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.state');")" = "active" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.engine_state');")" = "running" ]
  [ "$(sqlite_mem "SELECT json_type('$(echo "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = "integer" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.server_instance_id');")" != "" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.remote_team_id');")" != "" ]
  # The register binding carries no credential; the field is still emitted for
  # a stable schema, but as null (removed with the credential/E2EE cleanup).
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.credential_id');")" = "" ]
}

@test "status --json: reports state=disconnected after disconnect" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  bash "$SCRIPTS/remote.sh" disconnect testteam
  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.state');")" = "disconnected" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.engine_state');")" = "stopped" ]
  [ "$(sqlite_mem "SELECT json_type('$(echo "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = "null" ]
}

@test "status --json: errors for a team that has never been connected" {
  run bash "$SCRIPTS/remote.sh" status ghostteam --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"has never been connected"* ]]
}

@test "status --json: with no <team>, empty output when nothing is connected" {
  run bash "$SCRIPTS/remote.sh" status --json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "status --json: with no <team>, emits one JSONL line per connected team" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  bash "$SCRIPTS/join.sh" otherteam bob claude-code /tmp/project-b
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" otherteam
  run bash "$SCRIPTS/remote.sh" status --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  local testteam_line otherteam_line
  testteam_line="$(echo "$output" | grep testteam | grep -v otherteam)"
  otherteam_line="$(echo "$output" | grep otherteam)"
  [ -n "$testteam_line" ]
  [ -n "$otherteam_line" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$testteam_line" | sed "s/'/''/g")', '\$.local_team');")" = "testteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$otherteam_line" | sed "s/'/''/g")', '\$.local_team');")" = "otherteam" ]
}

@test "status: a team name containing a single quote doesn't break status or status --json (#87-class / .param set fix)" {
  local team="o'brien-team"
  bash "$SCRIPTS/join.sh" "$team" carol claude-code /tmp/project-c
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" "$team"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  run bash "$SCRIPTS/remote.sh" status "$team"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  [[ "$output" == *"connected"* ]]
  run bash "$SCRIPTS/remote.sh" status "$team" --json
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ".parameter" ]]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$output" | sed "s/'/''/g")', '\$.local_team');")" = "$team" ]
}











#
# Deterministic, single-threaded simulation of the race co1 flagged (see
# feat/remote-connect-onboarding's PR #479): rather than actually racing two
# live processes, pre-insert a row in the runtime `locks` table matching
# exactly what `_remote_pending_lock_acquire` would have written, then
# assert the OTHER operation either blocks (live owner) or reclaims (dead
# owner) as appropriate. AGMSG_PENDING_LOCK_TRIES keeps the timeout fast.

_insert_pending_lock_row() {
  local key="$1" owner_pid="$2" db="$SCRIPTS/../db/messages.db"
  sqlite3 "$db" "
CREATE TABLE IF NOT EXISTS locks (
  resource TEXT PRIMARY KEY,
  owner_pid INTEGER NOT NULL,
  acquired_at TEXT NOT NULL
);
INSERT OR REPLACE INTO locks(resource, owner_pid, acquired_at)
VALUES ('remote-pending.$key', $owner_pid, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
"
}




# --- dispatch --------------------------------------------------------------

@test "remote.sh: unknown subcommand prints usage and exits non-zero" {
  run bash "$SCRIPTS/remote.sh" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"pull"* ]]
}

# --- python3 preflight (dependency tiering: remote = +python3) -------------

@test "remote status: fails fast with an install message when python3 is absent, never hangs" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
  [[ "$output" == *"brew install python3"* ]]
}

@test "remote connect: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" connect testteam https://example.invalid tok
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}

@test "remote disconnect: fails fast with an install message when python3 is absent" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}


@test "remote doctor: still runs without python3, and reports it as a failed check (not a crash)" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] python3 on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote doctor: reports python3 as present when it is available" {
  run bash "$SCRIPTS/remote.sh" doctor
  [[ "$output" == *"[x] python3 on PATH"* ]]
}

# --- co1 delta review P1: doctor must also check node (sync data plane) ----
# Node is a SEPARATE, independent dependency from python3 (remote sync data
# plane vs. remote control plane) -- doctor claiming "All checks passed"
# with age+python3 present but node missing would contradict reality, since
# remote-sync.sh cannot run without node.

@test "remote doctor: reports node as a failed check (not silently ignored) when unusable, and does not claim overall success" {
  run env AGMSG_NODE=/definitely/does/not/exist/node bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] node on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote doctor: reports node as present when it resolves to a usable binary" {
  run bash "$SCRIPTS/remote.sh" doctor
  [[ "$output" == *"[x] node on PATH"* ]]
}

@test "remote doctor: passes with the full toolchain installed" {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
    || skip "all doctor prerequisites are not installed"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed."* ]]
}

PULL_TEAM_ID=018f3f7e-2222-7000-8000-000000000002

@test "remote pull: clones a team, keeping the id the server gave" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  local cmd_name
  cmd_name="$(basename "$TEST_SKILL_DIR")"
  [[ "$output" == *"This team is now local and ready for normal use."* ]]
  [[ "$output" == *"Open your agent and invoke its installed '$cmd_name' command, then join with a new agent name."* ]]
  # And NOT the locked branch's guidance. Asserting only that the right line is
  # present would pass for an output carrying both, which is what a reader
  # cannot reconcile -- the shape reported in #147.
  [[ "$output" != *"local but locked"* ]]
  [[ "$output" != *"unlock"* ]]
  local cfg
  cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  [ -f "$cfg" ]
  # Not minted here: the id is the one the server answered with.
  [ "$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.team_id');")" = "$PULL_TEAM_ID" ]
  [ "$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.drivers.partition');")" = "per-team" ]
  [ -f "$TEST_SKILL_DIR/db/teams/cloned/messages.db" ]
  # Pull arrives into an empty local team, so it can select the isolated partition
  # before bootstrap. Imported remote rows must never leak into the shared
  # store that local-only teams and external readers still use.
  if sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
      "SELECT name FROM sqlite_master WHERE type='table' AND name='events';" |
      grep -qx events; then
    [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
      "SELECT COUNT(*) FROM events WHERE team='cloned';")" -eq 0 ]
  fi
}

@test "remote pull: starts a background sync engine that disconnect stops" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  # "Machine two ... pulls the team down, and continues" — continuing IS the
  # engine. A pulled team that only cloned would report a send as "Sent" and
  # stay local while status answered "connected"; pin the engine running and the
  # binding it continues against. This is what a green 56/0 slipped past.
  [[ "$output" == *"Sync engine running."* ]]
  local pidfile="$SCRIPTS/../run/remote-sync.cloned.pid"
  wait_for_file "$pidfile"
  local cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.remote_binding.endpoint');")" = "$ENDPOINT" ]
  bash "$SCRIPTS/remote.sh" disconnect cloned
  wait_for_missing "$pidfile"
}

@test "remote pull: does not take a roster from the server" {
  # The server holds no membership -- it travels inside the envelope, so under
  # e2ee the server cannot read it. A roster invented here would be a guess
  # presented as fact; it is derived by replaying the team journal instead.
  #
  # The mock deliberately still answers with a members array, so this fails if
  # the client starts trusting one again rather than merely because none was
  # offered.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  local cfg agents
  cfg="$TEST_SKILL_DIR/teams/cloned/config.json"
  agents="$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.agents');")"
  [ "$agents" = "{}" ]
}

@test "remote pull: refuses a team that already has history" {
  bash "$SCRIPTS/join.sh" occupied alice claude-code /tmp/project-b >/dev/null
  bash "$SCRIPTS/send.sh" occupied alice alice "already mine" >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" occupied
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has history"* ]]
}

@test "remote pull: requires an endpoint, a team id and a local name" {
  run bash "$SCRIPTS/remote.sh" pull --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" cloned
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID"
  [ "$status" -ne 0 ]
}

@test "remote pull: the cloned team can be read with the ordinary commands" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  # The point of the whole step: the history is here, not just the team.
  [[ "$output" == *"2 message(s)"* ]]
  run bash "$SCRIPTS/history.sh" cloned alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"history one"* ]]
  [[ "$output" == *"history two"* ]]
}

@test "remote pull: applies seven roster events alongside seventy-three messages" {
  MOCK_PULL_MIXED=1
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" mixed
  [ "$status" -eq 0 ]
  [[ "$output" == *"80 message(s)"* ]]

  local cfg journal
  cfg="$TEST_SKILL_DIR/teams/mixed/config.json"
  journal="$TEST_SKILL_DIR/teams/mixed/roster.jsonl"
  [ "$(sqlite_mem "SELECT COUNT(*) FROM json_each(
      json_extract(readfile('$(rf "$cfg")'), '\$.agents'));")" -eq 7 ]
  [ "$(jq -s '[.[] | select(.type=="member_joined")] | length' "$journal")" -eq 7 ]
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  [ "$(storage_history mixed | jq -s 'length')" -eq 73 ]
}

@test "remote pull: an encrypted team with NO messages is still recorded as encrypted" {
  # The case the old inference got wrong. It set the profile from the number of
  # age-v1 envelopes this pull carried, so a team that had sent nothing yet was
  # recorded 'none' — and `unlock` then refused a team that really was sealed.
  # Here the server declares age-v1 and the pull carries zero envelopes.
  MOCK_PULL_AGE=0
  MOCK_TEAM_CIPHER_PROFILE=age-v1
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" encrypted
  [ "$status" -eq 0 ]

  local cfg
  cfg="$TEST_SKILL_DIR/teams/encrypted/config.json"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.remote_binding.cipher_profile');")" = "age-v1" ]
}

@test "remote pull: no declaration is recorded as unknown, and unlock names the fix" {
  # A team connected before the declaration was carried. The server answers
  # null. Writing 'none' here is what made the binding unfixable, so it is
  # written as unknown instead, and the refusal says who can settle it.
  MOCK_TEAM_CIPHER_PROFILE=""
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" undeclared
  [ "$status" -eq 0 ]

  local cfg
  cfg="$TEST_SKILL_DIR/teams/undeclared/config.json"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.remote_binding.cipher_profile');")" = "unknown" ]

  # Well-formed on purpose: an incomplete invocation would be refused by an
  # argument check ahead of this one, and the test would pass without ever
  # reaching the refusal it names.
  run bash "$SCRIPTS/remote.sh" unlock --bundle /dev/null \
    --confirm-digest 0000000000000000000000000000000000000000000000000000000000000000 undeclared
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not known to the server"* ]]
  # Stopping is right; stopping without a next move is not — and the move named
  # has to be one that works. A repeat connect deliberately writes nothing for a
  # team that already exists, so naming it would be advice that cannot succeed.
  # What settles the declaration is the owning machine sending a message.
  [[ "$output" == *"send.sh"* ]]
  [[ "$output" != *"remote.sh connect"* ]]
  [[ "$output" != *"not an encrypted pulled team awaiting unlock"* ]]
}

@test "remote pull: an observed age envelope prevents plaintext push" {
  MOCK_PULL_AGE=1
  MOCK_TEAM_CIPHER_PROFILE=age-v1
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" encrypted
  [ "$status" -eq 0 ]
  [[ "$output" == *"This team is encrypted"* ]]
  # The remedy, in a form that can be typed: an absolute path (remote.sh is
  # not on PATH) and both flags unlock actually requires.
  [[ "$output" == *"$SCRIPTS/remote.sh"*"unlock"*"--bundle"*"--confirm-digest"* ]]
  [[ "$output" != *"Run remote.sh unlock"* ]]

  local cfg before after
  cfg="$TEST_SKILL_DIR/teams/encrypted/config.json"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.remote_binding.cipher_profile');")" = "age-v1" ]
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.encrypted.pid" ]

  before="$(curl -sS "$ENDPOINT/v1/teams/$PULL_TEAM_ID" | jq -r '.current_seq')"
  bash "$SCRIPTS/send.sh" encrypted member-1 member-1 "stays local" >/dev/null
  run bash "$SCRIPTS/remote-sync.sh" once --team encrypted
  [ "$status" -ne 0 ]
  [[ "$output" == *"selected age-v1"* ]]
  after="$(curl -sS "$ENDPOINT/v1/teams/$PULL_TEAM_ID" | jq -r '.current_seq')"
  [ "$after" = "$before" ]
}

@test "remote unlock: confirms handed authority, reprocesses, and resumes age-v1 sync" {
  skip_if_no_age

  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam >/dev/null
  local source_cfg snapshot bundle key_id recipient identity team_id envelope digest
  source_cfg="$TEST_SKILL_DIR/teams/testteam/config.json"
  snapshot="$TEST_SKILL_DIR/handed-snapshot.json"
  bundle="$TEST_SKILL_DIR/handed-bundle.json"
  envelope="$TEST_SKILL_DIR/handed-envelope.json"
  bash "$SCRIPTS/key.sh" show testteam --snapshot --out "$snapshot" 2>/dev/null
  bash "$SCRIPTS/key.sh" handoff testteam --out "$bundle" >/dev/null 2>&1
  key_id="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.remote_key.current.key_id');")"
  recipient="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.remote_key.current.recipient');")"
  team_id="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.team_id');")"
  identity="$TEST_SKILL_DIR/run/remote-credentials/testteam/keys/$key_id.key"
  jq -nc \
    --arg key_id "$key_id" \
    --arg recipient "$recipient" \
    --arg team_id "$team_id" \
    '{
      type:"sync_seal", envelope_v:1, cipher:"age-v1",
      key_id:$key_id, recipients:[$recipient], max_blob_bytes:1048576,
      wire_id:"20000000-0000-4000-8000-000000000001",
      team_id:$team_id, protocol_version:1,
      projection:{
        body:"handed ciphertext", created_at:"2026-01-02T00:00:00.000000Z",
        from_agent:"member-1", to_agent:"member-1"
      }
    }' | node "$SCRIPTS/internal/sync-cipher.mjs" seal > "$envelope"
  bash "$SCRIPTS/remote.sh" disconnect testteam >/dev/null 2>&1 || true

  MOCK_PULL_AGE=1
  MOCK_PULL_AGE_ENVELOPE_FILE="$envelope"
  MOCK_PULL_TEAM_ID="$team_id"
  restart_mock_server

  # Machine B gets an independent install root. Reusing Machine A's root would
  # reuse its retained checkpoint and would not test a first trust import.
  PEER_SKILL_DIR="$(mktemp -d)"
  export PEER_SKILL_DIR
  mkdir -p "$PEER_SKILL_DIR"/{scripts,db,teams}
  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$PEER_SKILL_DIR/scripts/"
  chmod +x "$PEER_SKILL_DIR/scripts/"*.sh
  chmod +x "$PEER_SKILL_DIR/scripts/"*.js 2>/dev/null || true
  chmod +x "$PEER_SKILL_DIR/scripts/drivers/types/codex/"*.sh 2>/dev/null || true
  bash "$PEER_SKILL_DIR/scripts/internal/init-db.sh"
  local peer_scripts="$PEER_SKILL_DIR/scripts"

  run bash "$peer_scripts/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$team_id" encrypted
  [ "$status" -eq 0 ]
  [[ "$output" == *"local but locked"* ]]
  # The remedy has to be typable. `remote.sh` is not on PATH, and --bundle
  # without --confirm-digest is refused by unlock itself, so a line naming
  # either alone sends the operator into a wall.
  [[ "$output" == *"$peer_scripts/remote.sh"* ]]
  [[ "$output" == *"unlock"*"--bundle"*"--confirm-digest"* ]]
  [[ "$output" != *"Run remote.sh unlock"* ]]
  # And NOT the plaintext branch's guidance -- the same output must not also
  # say the team is ready.
  [[ "$output" != *"ready for normal use"* ]]

  digest="$(shasum -a 256 "$snapshot" | awk '{print $1}')"
  run bash "$peer_scripts/remote.sh" unlock encrypted \
    --snapshot "$snapshot" --identity "$identity" \
    --confirm-digest "0000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
  [ "$(sqlite_mem "SELECT json_type(json_extract(CAST(readfile('$(rf "$PEER_SKILL_DIR/teams/encrypted/config.json")') AS TEXT), '\$.remote_key'));")" = "" ]

  local wrong_identity="$TEST_SKILL_DIR/wrong-identity.key"
  age-keygen -o "$wrong_identity" >/dev/null 2>&1
  run bash "$peer_scripts/remote.sh" unlock encrypted \
    --snapshot "$snapshot" --identity "$wrong_identity" --confirm-digest "$digest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the authority-confirmed snapshot"* ]]
  [ "$(sqlite_mem "SELECT json_type(json_extract(CAST(readfile('$(rf "$PEER_SKILL_DIR/teams/encrypted/config.json")') AS TEXT), '\$.remote_key'));")" = "" ]
  [ ! -e "$PEER_SKILL_DIR/run/remote-credentials/encrypted" ]
  [ ! -e "$PEER_SKILL_DIR/db/remote-sync/encrypted.json" ]
  [ ! -d "$PEER_SKILL_DIR/run/remote-trust" ]

  run bash "$peer_scripts/remote.sh" unlock encrypted \
    --bundle "$bundle" --confirm-digest "$digest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported 1 envelope(s); engine running (pid "* ]]
  local pidfile first_pid second_pid
  pidfile="$PEER_SKILL_DIR/run/remote-sync.encrypted.pid"
  wait_for_file "$pidfile"
  first_pid="$(cat "$pidfile")"
  [ -d "$PEER_SKILL_DIR/run/remote-trust" ]
  run bash "$peer_scripts/remote.sh" unlock encrypted \
    --bundle "$bundle" --confirm-digest "$digest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported 0 envelope(s); engine running (pid "* ]]
  second_pid="$(cat "$pidfile")"
  [ "$second_pid" != "$first_pid" ]
  ! kill -0 "$first_pid" 2>/dev/null
  kill -0 "$second_pid" 2>/dev/null

  run bash "$peer_scripts/history.sh" encrypted member-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"handed ciphertext"* ]]

  local before after pushed_cipher
  kill "$second_pid" 2>/dev/null || true
  wait_for_pid_exit "$second_pid"
  rm -f "$pidfile"
  before="$(curl -sS "$ENDPOINT/v1/teams/$team_id" | jq -r '.current_seq')"
  bash "$peer_scripts/send.sh" encrypted member-1 member-1 "encrypted outbound" >/dev/null
  bash "$peer_scripts/remote-sync.sh" once --team encrypted >/dev/null 2>&1 || true
  after="$(curl -sS "$ENDPOINT/v1/teams/$team_id" | jq -r '.current_seq')"
  [ "$after" -gt "$before" ]
  pushed_cipher="$(curl -sS "$ENDPOINT/_test/pushed" |
    jq -r '.messages[-1].envelope.cipher')"
  [ "$pushed_cipher" = "age-v1" ]
}

@test "remote unlock --authenticated-bundle-stdin: takes exact bytes, refuses everything else" {
  skip_if_no_age

  # Same handed-authority setup as the --bundle test above, kept separate rather
  # than factored out: a shared fixture would let a change made for one mode
  # quietly redefine what the other one is asserting.
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam >/dev/null
  local source_cfg bundle key_id recipient team_id envelope
  source_cfg="$TEST_SKILL_DIR/teams/testteam/config.json"
  bundle="$TEST_SKILL_DIR/auth-bundle.json"
  envelope="$TEST_SKILL_DIR/auth-envelope.json"
  # Export the snapshot first: the handoff bundle carries the *confirmed* chain,
  # and the epoch is only confirmed once a snapshot has been exported. Skipping
  # this hands over a bundle that cannot open what the envelope was sealed to.
  bash "$SCRIPTS/key.sh" show testteam --snapshot --out "$TEST_SKILL_DIR/auth-snapshot.json" 2>/dev/null
  bash "$SCRIPTS/key.sh" handoff testteam --out "$bundle" >/dev/null 2>&1
  key_id="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.remote_key.current.key_id');")"
  recipient="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.remote_key.current.recipient');")"
  team_id="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.team_id');")"
  # wire_id must be exactly this: tests/helpers/mock_remote_server.py:83 serves a
  # row with that id, and an envelope carrying any other one is pulled but never
  # matched — which surfaces as "envelopes remain blocked after reprocessing",
  # i.e. as an unlock failure rather than as a fixture mismatch.
  jq -nc \
    --arg key_id "$key_id" \
    --arg recipient "$recipient" \
    --arg team_id "$team_id" \
    '{
      type:"sync_seal", envelope_v:1, cipher:"age-v1",
      key_id:$key_id, recipients:[$recipient], max_blob_bytes:1048576,
      wire_id:"20000000-0000-4000-8000-000000000001",
      team_id:$team_id, protocol_version:1,
      projection:{
        body:"authenticated ciphertext", created_at:"2026-01-02T00:00:00.000000Z",
        from_agent:"member-1", to_agent:"member-1"
      }
    }' | node "$SCRIPTS/internal/sync-cipher.mjs" seal > "$envelope"
  bash "$SCRIPTS/remote.sh" disconnect testteam >/dev/null 2>&1 || true

  MOCK_PULL_AGE=1
  MOCK_PULL_AGE_ENVELOPE_FILE="$envelope"
  MOCK_PULL_TEAM_ID="$team_id"
  restart_mock_server

  PEER_SKILL_DIR="$(mktemp -d)"
  export PEER_SKILL_DIR
  mkdir -p "$PEER_SKILL_DIR"/{scripts,db,teams}
  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$PEER_SKILL_DIR/scripts/"
  chmod +x "$PEER_SKILL_DIR/scripts/"*.sh
  chmod +x "$PEER_SKILL_DIR/scripts/"*.js 2>/dev/null || true
  chmod +x "$PEER_SKILL_DIR/scripts/drivers/types/codex/"*.sh 2>/dev/null || true
  bash "$PEER_SKILL_DIR/scripts/internal/init-db.sh"
  local peer_scripts="$PEER_SKILL_DIR/scripts"

  run bash "$peer_scripts/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$team_id" encrypted
  [ "$status" -eq 0 ]

  # Combining the new mode with any other input mode is an error, not a
  # precedence rule: two authorities disagreeing about which bytes were
  # authenticated must not resolve silently in either direction.
  local digest; digest="$(shasum -a 256 "$bundle" | awk '{print $1}')"
  run bash -c "bash '$peer_scripts/remote.sh' unlock encrypted --authenticated-bundle-stdin --confirm-digest '$digest' < '$bundle'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be combined"* ]]
  run bash -c "bash '$peer_scripts/remote.sh' unlock encrypted --authenticated-bundle-stdin --bundle '$bundle' < '$bundle'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be combined"* ]]

  # Empty stdin must fail closed rather than fall through to some other mode.
  run bash -c "bash '$peer_scripts/remote.sh' unlock encrypted --authenticated-bundle-stdin < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no bundle bytes on stdin"* ]]

  # Truncated and trailing-garbage input must fail too: "we did not authenticate
  # this" has to lose, and a partial read that merely looked like a bundle is
  # exactly what a fail-open would accept.
  head -c 64 "$bundle" > "$TEST_SKILL_DIR/partial.json"
  run bash -c "bash '$peer_scripts/remote.sh' unlock encrypted --authenticated-bundle-stdin < '$TEST_SKILL_DIR/partial.json'"
  [ "$status" -ne 0 ]
  cat "$bundle" > "$TEST_SKILL_DIR/trailing.json"
  printf 'garbage\n' >> "$TEST_SKILL_DIR/trailing.json"
  run bash -c "bash '$peer_scripts/remote.sh' unlock encrypted --authenticated-bundle-stdin < '$TEST_SKILL_DIR/trailing.json'"
  [ "$status" -ne 0 ]

  # None of the failures above may have imported trust or key material.
  [ "$(sqlite_mem "SELECT json_type(json_extract(CAST(readfile('$(rf "$PEER_SKILL_DIR/teams/encrypted/config.json")') AS TEXT), '\$.remote_key'));")" = "" ]
  [ ! -e "$PEER_SKILL_DIR/run/remote-credentials/encrypted" ]

  # The success path, fed through a PIPE rather than a redirect. A pipe has no
  # pathname, so this also proves the bytes are taken from the stream and not
  # re-opened by name — which is the entire reason this mode is stdin-only.
  run bash -c "cat '$bundle' | bash '$peer_scripts/remote.sh' unlock encrypted --authenticated-bundle-stdin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported 1 envelope(s); engine running (pid "* ]]
  # It must NOT have asked for, or accepted, a digest along the way.
  [[ "$output" != *"separate live channel"* ]]
  wait_for_file "$PEER_SKILL_DIR/run/remote-sync.encrypted.pid"
  [ -d "$PEER_SKILL_DIR/run/remote-trust" ]

  run bash "$peer_scripts/history.sh" encrypted member-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"authenticated ciphertext"* ]]

  # The decrypted bundle must not survive as a plaintext file: taking it on stdin
  # is pointless if we then leave a copy behind.
  run bash -c "ls -d \${TMPDIR:-/tmp}/agmsg-handoff.* 2>/dev/null | wc -l"
  [ "$(echo "$output" | tr -d '[:space:]')" = "0" ]

  local pid; pid="$(cat "$PEER_SKILL_DIR/run/remote-sync.encrypted.pid")"
  kill "$pid" 2>/dev/null || true
  wait_for_pid_exit "$pid"
}

@test "remote unlock --authenticated-bundle-stdin: the captured bundle is 0600 whatever the umask" {
  # The capture holds a team's key history in the clear until the trap fires, so
  # its mode must not depend on how the caller's shell happened to be configured.
  # Observed at the real boundary: remote.sh hands the path to remote-sync.sh, so
  # a stand-in there reports the mode of the actual file remote.sh created. A
  # structural "is there a chmod" grep would pass on code that chmods the wrong
  # path, or too late.
  local peer; peer="$(mktemp -d)"
  mkdir -p "$peer"/{scripts,db,teams}
  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$peer/scripts/"
  chmod +x "$peer/scripts/"*.sh
  bash "$peer/scripts/internal/init-db.sh"

  # A team the unlock will accept as an encrypted pulled team, so it reaches the
  # capture. Nothing beyond the capture needs to succeed.
  bash "$peer/scripts/join.sh" locked alice claude-code "$peer" >/dev/null 2>&1
  local cfg="$peer/teams/locked/config.json"
  python3 - "$cfg" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["remote_binding"] = {"cipher_profile": "age-v1", "connected_at": "2026-01-01T00:00:00Z"}
json.dump(cfg, open(p, "w"))
PY

  local seen="$peer/observed-mode"
  cat > "$peer/scripts/remote-sync.sh" <<PY
#!/usr/bin/env bash
# Stand-in: report the mode of the file remote.sh captured, then stop the unlock.
for a in "\$@"; do
  if [ "\$prev" = "--bundle" ]; then
    if stat -f '%Lp' "\$a" >/dev/null 2>&1; then stat -f '%Lp' "\$a" > "$seen"
    else stat -c '%a' "\$a" > "$seen"; fi
  fi
  prev="\$a"
done
exit 1
PY
  chmod +x "$peer/scripts/remote-sync.sh"

  # A deliberately permissive umask: without the fix the capture inherits it.
  run bash -c "umask 000; printf 'BUNDLE BYTES' | bash '$peer/scripts/remote.sh' unlock locked --authenticated-bundle-stdin"
  [ "$status" -ne 0 ]          # the stand-in refuses; only the capture matters here
  [ -f "$seen" ]               # and it must actually have been reached
  [ "$(cat "$seen")" = "600" ]
  rm -rf "$peer"
}

@test "remote unlock: a health response naming another team stops the configure" {
  skip_if_no_age

  # `configure` is the only caller of health(), and `cmd_unlock` is the only
  # caller of configure — so this is the path where reading the answer back can
  # be observed at all. Before this check, remote_team_id was whatever was passed
  # in and was never compared against the server, so a disagreement stayed
  # invisible until the first push failed, far from the step that caused it.
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam >/dev/null
  local source_cfg bundle key_id recipient team_id envelope snapshot digest
  source_cfg="$TEST_SKILL_DIR/teams/testteam/config.json"
  bundle="$TEST_SKILL_DIR/hm-bundle.json"
  snapshot="$TEST_SKILL_DIR/hm-snapshot.json"
  envelope="$TEST_SKILL_DIR/hm-envelope.json"
  bash "$SCRIPTS/key.sh" show testteam --snapshot --out "$snapshot" 2>/dev/null
  bash "$SCRIPTS/key.sh" handoff testteam --out "$bundle" >/dev/null 2>&1
  key_id="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.remote_key.current.key_id');")"
  recipient="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.remote_key.current.recipient');")"
  team_id="$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$source_cfg")') AS TEXT), '\$.team_id');")"
  jq -nc --arg key_id "$key_id" --arg recipient "$recipient" --arg team_id "$team_id" \
    '{ type:"sync_seal", envelope_v:1, cipher:"age-v1",
       key_id:$key_id, recipients:[$recipient], max_blob_bytes:1048576,
       wire_id:"20000000-0000-4000-8000-000000000001",
       team_id:$team_id, protocol_version:1,
       projection:{ body:"hm ciphertext", created_at:"2026-01-02T00:00:00.000000Z",
         from_agent:"member-1", to_agent:"member-1" } }' |
    node "$SCRIPTS/internal/sync-cipher.mjs" seal > "$envelope"
  bash "$SCRIPTS/remote.sh" disconnect testteam >/dev/null 2>&1 || true

  MOCK_PULL_AGE=1
  MOCK_PULL_AGE_ENVELOPE_FILE="$envelope"
  MOCK_PULL_TEAM_ID="$team_id"
  # The server answers /v1/health with a DIFFERENT team than the one this
  # machine is bound to.
  MOCK_HEALTH_TEAM_ID="018f3f7e-9999-7999-8999-999999999999"
  restart_mock_server

  PEER_SKILL_DIR="$(mktemp -d)"
  export PEER_SKILL_DIR
  mkdir -p "$PEER_SKILL_DIR"/{scripts,db,teams}
  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$PEER_SKILL_DIR/scripts/"
  chmod +x "$PEER_SKILL_DIR/scripts/"*.sh
  bash "$PEER_SKILL_DIR/scripts/internal/init-db.sh"
  local peer_scripts="$PEER_SKILL_DIR/scripts"

  run bash "$peer_scripts/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$team_id" encrypted
  [ "$status" -eq 0 ]

  digest="$(shasum -a 256 "$snapshot" | awk '{print $1}')"
  run bash "$peer_scripts/remote.sh" unlock encrypted --bundle "$bundle" --confirm-digest "$digest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"health team does not match"* ]]

  # Fail closed: no sync state and no engine for a binding the server disowns.
  [ ! -e "$PEER_SKILL_DIR/db/remote-sync/encrypted.json" ]
  [ ! -e "$PEER_SKILL_DIR/run/remote-sync.encrypted.pid" ]

  # The same unlock succeeds once the server agrees, so the failure above is the
  # mismatch and not something else in this setup. Switched in place rather than
  # by restarting: a restart moves the port, and the peer would then fail to
  # reach the endpoint it recorded at pull time — a green-looking pass for the
  # wrong reason, or a red one.
  curl -sS "$ENDPOINT/_test/health-team=" >/dev/null
  run bash "$peer_scripts/remote.sh" unlock encrypted --bundle "$bundle" --confirm-digest "$digest"
  [ "$status" -eq 0 ]
  local pid; pid="$(cat "$PEER_SKILL_DIR/run/remote-sync.encrypted.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait_for_pid_exit "$pid"; }
}

@test "remote unlock: --bundle still requires a matching --confirm-digest" {
  # The ordinary gate is unchanged by the new mode. Asserted on its own so that a
  # regression here cannot hide inside the larger handed-authority test.
  run bash "$SCRIPTS/remote.sh" unlock testteam --bundle /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --confirm-digest"* ]]
}

@test "remote doctor: age is optional — its absence does not fail the run" {
  # cipher "none" is the base and e2ee is available rather than required, so a
  # new user running doctor must not be told they are missing something they
  # were never obliged to have.
  local no_age; no_age="$(path_without_age)"
  run env PATH="$no_age" bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
  [[ "$output" == *"optional"* ]]
  [[ "$output" != *"is required for end-to-end encryption"* ]]
}

@test "remote doctor: python3 stays required while age is optional" {
  # The three are not interchangeable: without python3 the remote control plane
  # does not run at all, so it keeps failing the check.
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ ] python3 on PATH"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "remote pull: a name is enough — no UUID is carried by hand" {
  # The team_id requirement existed to stand in for authentication, and this
  # server has none to stand in for. The second machine should never need a
  # UUID typed across from the first.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" pulled-team
  [ "$status" -eq 0 ]
  local cfg
  cfg="$TEST_SKILL_DIR/teams/pulled-team/config.json"
  [ -f "$cfg" ]
  # And the id still ends up recorded, resolved rather than typed.
  [ "$(sqlite_mem "SELECT json_extract(readfile('$(rf "$cfg")'), '\$.team_id');")" = "$PULL_TEAM_ID" ]
}

@test "remote pull: an unknown name fails without inventing a team" {
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" nosuchteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"no team named"* ]]
  [ ! -d "$TEST_SKILL_DIR/teams/nosuchteam" ]
}

@test "remote pull: two teams sharing a name list the candidates and stop" {
  # Not bad data — a question only the operator can answer. The listing has to
  # carry what tells them apart, and must not pull one of them on a guess.
  MOCK_DUPLICATE_NAME=pulled-team restart_mock_server
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" pulled-team
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 teams are named"* ]]
  [[ "$output" == *"$PULL_TEAM_ID"* ]]
  [[ "$output" == *"018f3f7e-2222-7000-8000-0000000000ff"* ]]
  # What distinguishes them, and only from outside the envelope.
  [[ "$output" == *"registered 2026-07-29"* ]]
  [[ "$output" == *"registered 2026-07-12"* ]]
  [[ "$output" == *"messages"* ]]
  [[ "$output" == *"--team-id"* ]]
  # Nothing was pulled on a guess.
  [ ! -d "$TEST_SKILL_DIR/teams/pulled-team" ]
}

@test "remote pull: --team-id still resolves a shared name" {
  MOCK_DUPLICATE_NAME=pulled-team restart_mock_server
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" pulled-team
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/pulled-team/config.json" ]
}

# A lookup answer decides this machine's team identity and gets printed for an
# operator to read, so each of these asserts three things: the command failed,
# no local team was built from the answer, and the poisoned value never reached
# the terminal. The message is pinned too -- a bare non-zero status would also
# be produced by the very fail-open this guards against.
assert_lookup_rejected() {
  local mode="$1"
  MOCK_LOOKUP_BAD="$mode" restart_mock_server
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" pulled-team
  [ "$status" -ne 0 ]
  [[ "$output" == *"its answer was rejected"* ]]
  [[ "$output" != *"MARKER-INJECTED"* ]]
  [ ! -d "$TEST_SKILL_DIR/teams/pulled-team" ]
}

@test "remote pull: a candidate failing field validation is refused, not shown" {
  # team_id/timestamp/sequence are the fields that would reach a terminal or a
  # config; name_mismatch is a server answering about a different team.
  assert_lookup_rejected team_id
  assert_lookup_rejected timestamp
  assert_lookup_rejected sequence
  assert_lookup_rejected name_mismatch
}

@test "remote pull: an otherwise valid candidate with an extra field is refused" {
  # The strongest of these cases: everything the client uses is well formed, so
  # without the key-set check the pull would succeed and the unasked-for field
  # would have travelled with it.
  assert_lookup_rejected extra_field
}

@test "remote pull: a poisoned second candidate is refused before listing" {
  # The duplicate-name path prints candidates, which is exactly where an
  # unvalidated value would be rendered.
  assert_lookup_rejected multiple
}

@test "remote pull: more candidates than the bound are refused, not listed" {
  # Forty candidates. Without the client-side bound this lists all of them.
  assert_lookup_rejected flood
}

@test "remote pull: a wrong protocol, server id, or root name is refused" {
  assert_lookup_rejected protocol
  assert_lookup_rejected server_id
  assert_lookup_rejected root_name
}

@test "remote pull: the unlock line it prints can actually be run (#147)" {
  # Typed, not read. A remedy line is only worth printing if a shell can run
  # it: this takes the line out of the output, fills the placeholders, and
  # requires the failure to be about the BUNDLE -- never "command not found"
  # (remote.sh is not on PATH) and never a usage error (--bundle alone is
  # refused, so a line naming only --bundle is a dead end with extra steps).
  MOCK_PULL_AGE=1
  MOCK_TEAM_CIPHER_PROFILE=age-v1
  restart_mock_server
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" encrypted
  [ "$status" -eq 0 ]

  local printed
  printed="$(printf '%s\n' "$output" | grep -F 'remote.sh' | grep -F 'unlock' | head -1 | sed 's/^ *//')"
  [ -n "$printed" ]

  local runnable="${printed//<file>/\/nonexistent\/bundle.json}"
  runnable="${runnable//<sha256>/0000000000000000000000000000000000000000000000000000000000000000}"
  run eval "$runnable"
  [ "$status" -ne 0 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" != *"No such file or directory"*"remote.sh"* ]]
  [[ "$output" != *"Usage: remote.sh unlock"* ]]
}
