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
  [[ "$output" == *"All prerequisite checks passed."* ]]
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

# --- set-endpoint: move a live binding's address (#718) --------------------
#
# The binding's identity is (server_instance_id, remote_team_id,
# protocol_version); the endpoint is the address used to reach it. These tests
# pin the three properties the address move must have: same-identity moves
# succeed (history and all), a different server instance at the new address is
# refused with both ids named, and there is no path that writes an unverified
# address.

# NOT COVERED, measured rather than assumed (#730): "set-endpoint reports a
# failed engine restart instead of claiming one".
#
# The capture is in cmd_set_endpoint because the helper can now return non-zero
# and a bare call would abort the command under `set -e`. No test drives it,
# and not for want of trying:
#
#   read-only pidfile  -- cmd_set_endpoint calls _remote_sync_engine_stop itself
#                         (remote.sh, inside cmd_set_endpoint) before the
#                         restart, and that ends in `rm -f "$pidfile"`, which
#                         succeeds in a writable run dir. Observed: the file
#                         went -r--r--r-- -> -rw-r--r-- across the command and
#                         the restart claimed success.
#   directory at that   -- survives the rm, but `[ -f ]` is then false when
#   path                  was_running is captured a few lines earlier, so the
#                         restart branch is never entered at all.
#   unwritable run dir  -- the stop's own `rm -f` fails first and the command
#                         exits on that instead.
#
# Reaching it needs the run dir to become unwritable BETWEEN the stop and the
# start. What was measured is narrower than "impossible": these three injections
# do not reach it, and the code as it stands offers no seam between the stop and
# the start for a test to drive. A dedicated barrier or hook in that gap would
# stage it deterministically -- not proposed here, and said plainly so the limit
# reads as the current shape of the code rather than a law. Left uncovered and
# said so, rather than shipping a test that passes against the bare call -- the
# mutation reverting this call site reds nothing today.

@test "set-endpoint: moves a connected team with history to a new address of the same server (#718)" {
  # bob joins BEFORE connect so the server roster matches the local one: the
  # identity re-check compares rosters, and this test is about the address.
  run bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-a
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # History is exactly what makes the disconnect-then-pull workaround refuse
  # (#718's dead end), so the team here has some: the move must not care.
  run bash "$SCRIPTS/send.sh" testteam alice bob "history row"
  [ "$status" -eq 0 ]
  local anchored revision_before
  anchored="$(_binding_field testteam server_instance_id)"
  revision_before="$(_binding_field testteam binding_revision)"

  run bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam
  [ "$status" -eq 0 ]
  grep -Fq "moved: http://127.0.0.1:$MOCK_PORT -> http://localhost:$MOCK_PORT" <<<"$output"
  grep -Fq "Sync engine restarted" <<<"$output"
  [ "$(_binding_field testteam endpoint)" = "http://localhost:$MOCK_PORT" ]
  # The ADDRESS moved; the identity did not, and the write was versioned.
  [ "$(_binding_field testteam server_instance_id)" = "$anchored" ]
  [ "$(_binding_field testteam binding_revision)" -gt "$revision_before" ]

  # Same address again: a recorded no-op, not an error and not a rewrite.
  revision_before="$(_binding_field testteam binding_revision)"
  run bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam
  [ "$status" -eq 0 ]
  grep -Fq "nothing to change" <<<"$output"
  [ "$(_binding_field testteam binding_revision)" = "$revision_before" ]
}

@test "set-endpoint: an unclearable cycle record does not cost the running engine (#756)" {
  # A restart clears the previous engine's cycle record, and refuses if it
  # cannot: left behind, `status` would report a predecessor's success as the new
  # engine's. The refusal has to happen BEFORE the old engine is signalled --
  # otherwise a bookkeeping problem has stopped a working engine, which is worse
  # than the misattribution it avoids, because syncing stops.
  #
  # This lives here rather than beside the other #756 tests because it needs a
  # restart path that actually reaches the kill: `sync start` reports "already
  # running" and returns first (measured), so it never gets there. set-endpoint
  # does, and needs the mock server this file has.
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  local pidfile engine_pid stamp
  pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  engine_pid="$(cat "$pidfile")"
  kill -0 "$engine_pid"
  stamp="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  mkdir -p "$stamp"          # `rm -f` cannot take a directory: unclearable

  run bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam
  # The move is the operation; the record is bookkeeping. Written as a bare
  # `rm -f`, the cleanup became the stop function's exit status, so an unclearable
  # record made a successful stop report failure and set-endpoint refused to move
  # at all -- after the engine was already down. The stop kept its promise in
  # every one of those cases.
  refute grep -qF -- "the sync engine did not stop" <<<"$output"
  # And the failure does not leak as a bare rm(1) complaint with no subject.
  refute grep -qF -- "is a directory" <<<"$output"
  [ "$(_binding_field testteam endpoint)" = "http://localhost:$MOCK_PORT" ]
  # The restart is what refuses, which is the right place: a stale record can
  # only be misread by an engine that starts.
  grep -Fq "did not restart" <<<"$output"

  kill "$engine_pid" 2>/dev/null || true
}

@test "set-endpoint: refuses a different server instance at the new address, naming both ids (#718)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  local anchored
  anchored="$(_binding_field testteam server_instance_id)"
  [ -n "$anchored" ]

  # Same address family, different server: registrations survive the rotation,
  # so the recorded instance id is the only thing that can tell them apart.
  run curl -sS "$ENDPOINT/_test/rotate-server-id"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam
  [ "$status" -ne 0 ]
  # What differed is SAID, both sides of it -- not a bare "refused".
  grep -Fq "is now server instance 018f3f7e-2222-7000-8000-0000000000ff" <<<"$output"
  grep -Fq "bound to $anchored" <<<"$output"
  grep -Fq "Refusing to re-anchor" <<<"$output"
  # And nothing was written: the binding still names the verified address.
  [ "$(_binding_field testteam endpoint)" = "$ENDPOINT" ]
  [ "$(_binding_field testteam server_instance_id)" = "$anchored" ]
}

@test "set-endpoint: re-running from the partial state repairs the stored sync config (#739 P1-1)" {
  # The partial state a failure between the two writes leaves behind:
  # binding=new address, stored sync config=old address. The printed remedy is
  # to re-run set-endpoint, so the same-address path must repair the stored
  # config rather than return on the binding comparison alone.
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  local sid tid stored="$TEST_SKILL_DIR/db/remote-sync/testteam.json"
  sid="$(_binding_field testteam server_instance_id)"
  tid="$(_binding_field testteam remote_team_id)"
  mkdir -p "$TEST_SKILL_DIR/db/remote-sync"
  printf '%s\n' "{\"format_version\":1,\"local_team\":\"testteam\",\"server_url\":\"http://127.0.0.1:9\",\"server_instance_id\":\"$sid\",\"remote_team_id\":\"$tid\",\"protocol_version\":1,\"cipher_profile\":\"none\",\"local_security_history\":[{\"local_security_revision\":\"0\",\"effective_from_seq\":\"1\",\"minimum_security_mode\":\"plaintext-allowed\"}]}" > "$stored"

  # Same address as the binding: before the fix this exited "nothing to
  # change" without ever looking at the stored config.
  run bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  grep -Fq "aligned" <<<"$output"
  [ "$(sqlite_mem "SELECT json_extract(CAST(readfile('$(rf "$stored")') AS TEXT), '\$.server_url');")" = "$ENDPOINT" ]
}

@test "set-endpoint: a concurrent disconnect is not overwritten by the verified write (#739 P1-2)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  local barrier="$TEST_SKILL_DIR/se-barrier" se_rc=0
  AGMSG_TEST_SET_ENDPOINT_BARRIER="$barrier" \
    bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam \
    > "$TEST_SKILL_DIR/se.out" 2>&1 3>&- &
  local se_pid=$!
  # A wider ceiling than wait_for_file's 10s: under full-suite load the
  # background command's cold start (node endpoint validation, sqlite reads)
  # has been measured past 10s, and a barrier miss here fails the test for
  # timing, not behavior.
  for _ in $(seq 1 300); do [ -e "$barrier.reached" ] && break; sleep 0.1; done
  [ -e "$barrier.reached" ]
  # The race: the operator disconnects while set-endpoint is verifying. The
  # disconnect advances binding_revision, so the verified write must refuse
  # rather than land disconnected_at:null over the newer state.
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  : > "$barrier.release"
  wait "$se_pid" || se_rc=$?
  [ "$se_rc" -ne 0 ]
  grep -Fq "changed while this command was running" "$TEST_SKILL_DIR/se.out"
  # The disconnect survived, and the address did not move.
  [ "$(_binding_field testteam disconnected_at)" != "" ]
  [ "$(_binding_field testteam disconnected_at)" != "null" ]
  [ "$(_binding_field testteam endpoint)" = "$ENDPOINT" ]
}

@test "set-endpoint: a legacy binding without a revision still cannot overwrite a concurrent disconnect (#739)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # Make the binding legacy: bindings written before revisions existed carry
  # none, and an empty expected revision made both CAS functions skip their
  # comparison -- disabling the lifecycle guard for exactly these teams.
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json"
  sqlite_mem "SELECT json_remove(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.remote_binding.binding_revision');" > "$cfg.tmp"
  mv "$cfg.tmp" "$cfg"
  [ "$(_binding_field testteam binding_revision)" = "" ]

  local barrier="$TEST_SKILL_DIR/se-barrier3" se_rc=0
  AGMSG_TEST_SET_ENDPOINT_BARRIER="$barrier" \
    bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam \
    > "$TEST_SKILL_DIR/se3.out" 2>&1 3>&- &
  local se_pid=$!
  for _ in $(seq 1 300); do [ -e "$barrier.reached" ] && break; sleep 0.1; done
  [ -e "$barrier.reached" ]
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  : > "$barrier.release"
  wait "$se_pid" || se_rc=$?
  [ "$se_rc" -ne 0 ]
  grep -Fq "changed while this command was running" "$TEST_SKILL_DIR/se3.out"
  [ "$(_binding_field testteam disconnected_at)" != "" ]
  [ "$(_binding_field testteam disconnected_at)" != "null" ]
  [ "$(_binding_field testteam endpoint)" = "$ENDPOINT" ]
}

@test "set-endpoint: an engine started while it runs ends up running on the new address (#739 P1-2)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  # Put the engine into the stopped state first, so the concurrent start is
  # the only thing that makes it run.
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid" engine_pid
  engine_pid="$(cat "$pidfile")"
  kill "$engine_pid"
  wait_for_pid_exit "$engine_pid"
  local barrier="$TEST_SKILL_DIR/se-barrier2" se_rc=0
  AGMSG_TEST_SET_ENDPOINT_BARRIER="$barrier" \
    bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam \
    > "$TEST_SKILL_DIR/se2.out" 2>&1 3>&- &
  local se_pid=$!
  # Same wider ceiling as the disconnect-race test above.
  for _ in $(seq 1 300); do [ -e "$barrier.reached" ] && break; sleep 0.1; done
  [ -e "$barrier.reached" ]
  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  : > "$barrier.release"
  wait "$se_pid" || se_rc=$?
  [ "$se_rc" -eq 0 ]
  grep -Fq "Sync engine restarted" "$TEST_SKILL_DIR/se2.out"
  [ "$(_binding_field testteam endpoint)" = "http://localhost:$MOCK_PORT" ]
  # The operator's engine is not silently gone: one is alive at the end.
  engine_pid="$(cat "$pidfile")"
  kill -0 "$engine_pid"
}

@test "set-endpoint: refuses a disconnected team and names connect as the deliberate move (#718)" {
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/remote.sh" set-endpoint --endpoint "http://localhost:$MOCK_PORT" testteam
  [ "$status" -ne 0 ]
  grep -Fq "disconnected" <<<"$output"
  grep -Fq "connect with the new endpoint" <<<"$output"
  [ "$(_binding_field testteam endpoint)" = "$ENDPOINT" ]
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

@test "pull: a caller that owns the guidance keeps the state and loses the route" {
  skip_if_no_age
  # The team is locked either way, and saying so is not optional: drop it and
  # a finished pull reads as a usable team, which is the worse of the two
  # failures -- the messages are here and none of them can be read yet.
  #
  # What goes is the route. `remote.sh` is not on a caller's operator's PATH,
  # and "the secret handoff bundle you were given" describes material they
  # were never handed; theirs arrives through a different ceremony. Sending
  # them to look for a bundle sends them looking for something that does not
  # exist.
  MOCK_PULL_AGE=1
  MOCK_TEAM_CIPHER_PROFILE=age-v1
  restart_mock_server

  AGMSG_OPERATOR_GUIDANCE=caller run bash "$SCRIPTS/remote.sh" pull \
    --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" encrypted
  [ "$status" -eq 0 ]

  # The state survives.
  [[ "$output" == *"This team is encrypted"* ]]
  [[ "$output" == *"local but locked"* ]]

  # The route does not.
  [[ "$output" != *"handoff bundle you were given"* ]]
  [[ "$output" != *"--confirm-digest"* ]]
  [[ "$output" != *"scripts/remote.sh"*"unlock"* ]]
}

@test "pull: a truly unreachable server is reported as such (#726)" {
  # Direction 1 of the negative control: nothing listens on this port, so
  # resolve-team's child process fails before ever reaching a server. name
  # resolution runs because no --team-id is given.
  #
  # Asserting the wrapper's own line is not enough on its own: that line is
  # printed on ANY non-zero exit, including the old redirected one, so it
  # cannot tell "the fix works" apart from "the fix was reverted". The
  # child's own transport-specific message (what fetch() actually reports
  # for a refused connection, node's "fetch failed") is what only reaches
  # the operator because the redirect is gone -- that is the actual claim
  # this PR makes, so it is what has to be pinned.
  run bash "$SCRIPTS/remote.sh" pull --endpoint "http://127.0.0.1:1" newteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"fetch failed"* ]] &&
    [[ "$output" == *"could not look up 'newteam'"* ]]
}

@test "pull: a reachable server whose lookup answer fails validation names that reason, not \"unreachable\" (#726)" {
  # Direction 2: the mock server answers (HTTP 200, protocol_version wrong),
  # so this is not a transport failure -- it is the OTHER cause the old
  # message collapsed into the same sentence as "unreachable". The specific
  # reason has to surface, and the collapsed wording must not appear at all,
  # or this is indistinguishable from before the fix.
  MOCK_LOOKUP_BAD=protocol restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" newteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"team lookup answer is not a lookup result"* ]] &&
    [[ "$output" != *"unreachable"* ]]
}

@test "pull: an untrusted server's raw error text does not reach the terminal (#726/#728)" {
  # A third case, neither transport failure nor a malformed-but-200 body: the
  # server answers with a real HTTP error whose error.code is server-supplied
  # text with no format guarantee. Now that resolve-team's stderr is no
  # longer redirected away, that text is one un-sanitized field away from
  # reaching the operator's terminal raw -- the same class of risk
  # resolveTeam's own validation path already guards against for a 200
  # ("messages quote no server value"). The status and a safe reason still
  # have to get through; the injected marker must not.
  MOCK_LOOKUP_BAD=http_error restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" newteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 503"* ]] &&
    [[ "$output" != *"MARKER-INJECTED"* ]]
}

@test "pull: a malformed (non-JSON) answer does not leak its raw bytes either (#726/#728)" {
  # A fourth case, and a different mechanism from the one above: not a
  # well-formed body with a bad field, but a body that is not JSON at all.
  # Node's own JSON.parse SyntaxError can quote a fragment of the offending
  # input in its message, which would carry the same marker straight to the
  # terminal through a path the error.code sanitization above does not
  # touch -- the parse never gets that far.
  MOCK_LOOKUP_BAD=malformed_json restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" newteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 200"*"invalid JSON"* ]] &&
    [[ "$output" != *"MARKER-INJECTED"* ]]
}

@test "connect: the handoff-bundle line is printed by default" {
  # #668: this named the snapshot pair while `pull` on the other machine asked
  # for the bundle, so each side named the other's route. It names the bundle
  # now -- the same artifact pull asks for.
  skip_if_no_age
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -q 'secret handoff bundle' || return 1
  # And no longer sends the reader after the artifact the other side will not
  # accept. An absence, because both routes still exist in `unlock`: what
  # changed is which one is advertised, and an advertisement creeping back
  # would be invisible to a presence check.
  run bash -c 'printf "%s\n" "$1" | grep -q -- "--snapshot"' _ "$output"
  [ "$status" -ne 0 ] || return 1
}

@test "connect: the handoff line survives a team with a space and a quote" {
  # The route the operator actually takes, proven the way #667 proved the
  # others: parse the printed command with a shell and compare argv byte for
  # byte. A substring cannot tell correct quoting from a line that merely
  # contains the right words.
  skip_if_no_age
  local qteam="it's a team"
  bash "$SCRIPTS/join.sh" "$qteam" alice claude-code /tmp/project-quoted-team >/dev/null
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee "$qteam"
  [ "$status" -eq 0 ] || return 1
  line="$(printf '%s\n' "$output" | grep -F -- "key.sh' handoff " | head -1)"
  [ -n "$line" ] || return 1
  # Everything up to the first placeholder. `<new-name>` and `<file>` are for
  # the reader to replace; left in, a shell reads them as redirections and the
  # parse dies. What must survive a shell is the part that is already complete.
  eval "set -- ${line%%<*}"
  [ "$1" = bash ] || return 1
  [ -f "$2" ] || return 1
  [ "$3" = handoff ] || return 1
  [ "$4" = "$qteam" ] || return 1
  [ "$5" = --out ] || return 1
}

@test "connect: the handoff export it prints names a key.sh that exists" {
  # The line is the first step of getting a second machine in, and `key.sh` is
  # not on PATH (#667). Existence, not spelling: a path into the wrong install
  # would match any substring check and still not run.
  #
  # `[ ]` and `grep -q`, not `[[ ]]`: on bash 3.2 a failing `[[ ]]` in the
  # middle of a body does not trip errexit (#670).
  skip_if_no_age
  run bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'secret handoff bundle'
  path="$(printf '%s\n' "$output" | sed -n "s/.*bash '\([^']*key\.sh\)'.*/\1/p" | head -1)"
  [ -n "$path" ]
  [ -f "$path" ]
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
  # The route moved to the handoff bundle (#668); the gate still withholds it.
  # `grep -q` + status, not `[[ ]]`: a failing `[[ ]]` mid-body is not enforced
  # on bash 3.2 (#670), and these are the assertions that just moved.
  # Captured first: `run` overwrites $output, so the second check below would
  # otherwise grep the first grep's empty stdout and pass for that reason.
  out="$output"
  run bash -c 'printf "%s\n" "$1" | grep -q "secret handoff bundle"' _ "$out"
  [ "$status" -ne 0 ] || return 1
  run bash -c 'printf "%s\n" "$1" | grep -q "key.sh"' _ "$out"
  [ "$status" -ne 0 ] || return 1
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
  # The route moved from the snapshot pair to the handoff bundle (#668); the
  # path and quoting it gained in #667 stay. `grep -q`, not `[[ ]]`: a failing
  # `[[ ]]` mid-body is not enforced on bash 3.2 (#670).
  printf '%s\n' "$output" | grep -q -F -- "key.sh' handoff 'testteam' --out <file>"
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

_truncate_team_config() {  # $1 = team -> replaces its config.json with malformed JSON
  local cfg="$TEST_SKILL_DIR/teams/$1/config.json"
  [ -f "$cfg" ] || { echo "no config.json for $1 to truncate" >&2; return 1; }
  printf '{"remote_binding": {"connected_at": "2026-01-01T00:00' > "$cfg"
}

@test "status --json (aggregate): a team whose config could not be read gets an explicit line, not silence (#650)" {
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  bash "$SCRIPTS/join.sh" beta dave claude-code /tmp/project-beta
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" beta
  _truncate_team_config beta
  bash "$SCRIPTS/join.sh" gamma erin claude-code /tmp/project-gamma  # joined, never connected

  run bash "$SCRIPTS/remote.sh" status --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  local testteam_line beta_line
  testteam_line="$(echo "$output" | grep testteam)"
  beta_line="$(echo "$output" | grep beta)"
  [ -n "$testteam_line" ]
  [ -n "$beta_line" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$beta_line" | sed "s/'/''/g")', '\$.local_team');")" = "beta" ]
  [ "$(sqlite_mem "SELECT json_extract('$(echo "$beta_line" | sed "s/'/''/g")', '\$.state');")" = "unreadable" ]
  # gamma was joined but never connected -- ordinary, stays silent. Its
  # absence here is the OTHER half of #650: a line must not be manufactured
  # for a team that was genuinely never bound, only for one that failed to
  # read.
  [[ "$output" != *"gamma"* ]]
}

@test "status <team> --json: an unreadable config is distinguishable from a genuinely unconnected team (#650)" {
  bash "$SCRIPTS/join.sh" beta dave claude-code /tmp/project-beta
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" beta
  _truncate_team_config beta

  run bash "$SCRIPTS/remote.sh" status beta --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be read"* ]] && [[ "$output" != *"has never been connected"* ]]

  run bash "$SCRIPTS/remote.sh" status ghostteam --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been connected"* ]] && [[ "$output" != *"could not be read"* ]]
}

@test "status <team>: the text form distinguishes unreadable from unconnected too, with no leaked sqlite error (#650)" {
  bash "$SCRIPTS/join.sh" beta dave claude-code /tmp/project-beta
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" beta
  _truncate_team_config beta

  run bash "$SCRIPTS/remote.sh" status beta
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be read"* ]] && [[ "$output" != *"has never been connected"* ]]
  # The pre-fix leak: a raw sqlite parse error reached stdout/stderr before
  # the (wrong) "has never been connected" line. The malformed check now
  # short-circuits before any field read is attempted.
  [[ "$output" != *"Error: stepping"* ]]
}

@test "status (aggregate, text): an unreadable team is reported and suppresses the false-reassuring 'No teams are connected' (#650)" {
  bash "$SCRIPTS/join.sh" beta dave claude-code /tmp/project-beta
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" beta
  _truncate_team_config beta

  run bash "$SCRIPTS/remote.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"beta"* ]] && [[ "$output" == *"could not be read"* ]]
  [[ "$output" != *"No teams are connected."* ]]
}

@test "status <team> --json: a lock that cannot be acquired is reported as unreadable, not never-connected (#650)" {
  bash "$SCRIPTS/join.sh" beta dave claude-code /tmp/project-beta
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" beta
  local lock="$TEST_SKILL_DIR/teams/beta/.config.lock"
  mkdir "$lock"

  run env AGMSG_LOCK_TRIES=2 bash "$SCRIPTS/remote.sh" status beta --json
  rmdir "$lock"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be read"* ]] && [[ "$output" != *"has never been connected"* ]]
}

@test "status <team> [--json]: the human and --json forms classify every config shape identically (#650 review)" {
  # a review finding: _remote_config_malformed checked json_valid but not the
  # top-level TYPE, so [] / null / 42 / "text" -- valid JSON, not an object
  # -- passed it, then fell through to json_extract-returns-null same as a
  # genuinely empty binding: rc=1 "never connected". The --json path's
  # python isinstance(dict) check already rejected these (rc=2), so the
  # same file classified differently on the two paths.
  #
  # Fixing the bash side alone (tightening its check to match python's)
  # would leave two independent implementations of one question, the exact
  # shape that produced this gap in the first place -- the same structural
  # mistake as #722 (also fixed by collapsing to one implementation both
  # callers use). This test pins that AGREEMENT, not just each side's own
  # correctness: it fails if either side's classifier ever changes without
  # the other, even though _remote_config_shape_ok is now the single
  # implementation both call, in case a future edit reintroduces a
  # divergent path.
  bash "$SCRIPTS/join.sh" beta dave claude-code /tmp/project-beta
  bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" beta
  local cfg="$TEST_SKILL_DIR/teams/beta/config.json"
  local valid_cfg
  valid_cfg="$(cat "$cfg")"

  local shape content expect
  for shape in valid never_connected array null number string truncated; do
    case "$shape" in
      valid)           content="$valid_cfg"; expect=0 ;;
      never_connected) content='{}'; expect=1 ;;
      array)           content='[]'; expect=2 ;;
      null)            content='null'; expect=2 ;;
      number)          content='42'; expect=2 ;;
      string)          content='"text"'; expect=2 ;;
      truncated)       content='{"remote_binding": {"connected_at": "2026-01-01T00:00'; expect=2 ;;
    esac
    printf '%s' "$content" > "$cfg"

    run bash "$SCRIPTS/remote.sh" status beta
    local human_status="$status"
    run bash "$SCRIPTS/remote.sh" status beta --json
    local json_status="$status"

    [ "$human_status" -eq "$expect" ] \
      || { echo "shape=$shape: human form expected exit $expect, got $human_status" >&2; false; }
    [ "$json_status" -eq "$expect" ] \
      || { echo "shape=$shape: --json form expected exit $expect, got $json_status" >&2; false; }
  done
}











#
# Deterministic, single-threaded simulation of the race flagged in review (see
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

# --- delta review P1: doctor must also check node (sync data plane) ----
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
  [[ "$output" == *"All prerequisite checks passed."* ]]
}

PULL_TEAM_ID=018f3f7e-2222-7000-8000-000000000002

@test "remote pull: clones a team, keeping the id the server gave" {
  # This team is a PLAIN one: say so. The fixture's default declaration is
  # age-v1, and the engine now follows the declaration rather than the
  # envelope count -- a team declared sealed with no key on this machine is
  # locked, correctly, and that is a different test from this one.
  MOCK_TEAM_CIPHER_PROFILE=none
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  local cmd_name
  cmd_name="$(basename "$TEST_SKILL_DIR")"
  # This fixture's stream carries no roster events, so this machine cannot name
  # a single member -- and the advice that used to print here was "join with a
  # new agent name", which is precisely what cannot be done safely from an empty
  # roster: every name looks free, including the ones already answering
  # elsewhere (#743). The pull is still a success; what it may not do is call
  # the team ready.
  # `grep`/`refute`, not `[[ ]]`: a non-last `[[ ]]` cannot fail the test on
  # bash 3.2, so on macOS these would be decoration (#670).
  printf '%s\n' "$output" | grep -q -F -- "This team is local, but not yet usable for joining."
  printf '%s\n' "$output" | grep -q -F -- "No members are known here yet."
  refute grep -qF -- "This team is now local and ready for normal use." <<<"$output"
  refute grep -qF -- "then join with a new agent name" <<<"$output"
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

# The three callers changed by #730, each with a start refusal injected.
#
# The refusal itself is covered in tests/test_remote_engine_start_refusal.bats,
# but only through `sync start`. Without these, the four-path asymmetry that
# change is about -- unlock fails, pull and connect report and carry on -- is
# only prose in the commit message. Found in review.
#
# The injection is a read-only pidfile rather than an unwritable run dir: the
# rest of connect and pull write under run/ too, and taking the whole directory
# away would stop them for reasons that have nothing to do with the engine.
_deny_engine_pidfile() {
  # Two statements, not one. `local a="$1" b="…$a…"` builds b before a is
  # visible, so the pidfile came out as `remote-sync..pid` and the injection
  # silently missed -- the test then measured an ordinary pull and reported the
  # claim it was written to catch.
  local team="$1"
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.$team.pid"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' 2147483647 > "$pidfile"
  chmod a-w "$pidfile"
}

@test "remote pull: a start refusal is reported, and the pull still succeeds (#730)" {
  [ "$(id -u)" -ne 0 ] || skip "chmod does not restrict root"
  MOCK_TEAM_CIPHER_PROFILE=none
  restart_mock_server
  _deny_engine_pidfile cloned

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  chmod u+w "$TEST_SKILL_DIR/run/remote-sync.cloned.pid" 2>/dev/null || true
  # Pull's purpose is to bring the team here, and it did.
  [ "$status" -eq 0 ]
  grep -qF "Pulled" <<<"$output"
  # But it must not claim an engine it could not start.
  refute grep -qF "Sync engine start requested" <<<"$output"
  grep -qF "The sync engine did not start" <<<"$output"
  grep -qF "could not start the sync engine" <<<"$output"
}

@test "remote connect: a start refusal is reported, and the binding still stands (#730)" {
  [ "$(id -u)" -ne 0 ] || skip "chmod does not restrict root"
  MOCK_TEAM_CIPHER_PROFILE=none
  restart_mock_server
  bash "$SCRIPTS/join.sh" bound alice claude-code /tmp/project-bound >/dev/null
  _deny_engine_pidfile bound

  run bash "$SCRIPTS/remote.sh" connect bound --endpoint "$ENDPOINT"
  chmod u+w "$TEST_SKILL_DIR/run/remote-sync.bound.pid" 2>/dev/null || true
  # Connect's purpose is the binding, and it is written by this point.
  [ "$status" -eq 0 ]
  grep -qF "Connected:" <<<"$output"
  refute grep -qF "Sync engine start requested" <<<"$output"
  grep -qF "The sync engine did not start" <<<"$output"
  grep -qF "could not start the sync engine" <<<"$output"
}

@test "remote pull: starts a background sync engine that disconnect stops" {
  # This team is a PLAIN one: say so. The fixture's default declaration is
  # age-v1, and the engine now follows the declaration rather than the
  # envelope count -- a team declared sealed with no key on this machine is
  # locked, correctly, and that is a different test from this one.
  MOCK_TEAM_CIPHER_PROFILE=none
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" cloned
  [ "$status" -eq 0 ]
  # "Machine two ... pulls the team down, and continues" — continuing IS the
  # engine. A pulled team that only cloned would report a send as "Sent" and
  # stay local while status answered "connected"; pin the engine running and the
  # binding it continues against. This is what a green 56/0 slipped past.
  # "start requested", not "running": this path spawns the engine and records
  # its pid, and does not wait to see it come up (#730).
  [[ "$output" == *"Sync engine start requested"* ]]
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

@test "remote pull: refuses a team whose history is in the LEGACY table (#147)" {
  # The shape the old guard could not see. It counted the event log only, so a
  # store whose history lives in the legacy `messages` table read as empty --
  # and this is the one case the guard exists to refuse. Asking the driver
  # instead means whichever shape that driver keeps is the shape that answers.
  bash "$SCRIPTS/join.sh" legacyteam alice claude-code /tmp/project-legacy >/dev/null
  local db
  db="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_db_path legacyteam')"
  sqlite3 "$db" "INSERT INTO messages (team, from_agent, to_agent, body, created_at)
                 VALUES ('legacyteam','alice','alice','old news','2026-01-01T00:00:00Z');"

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" legacyteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has history"* ]]
}

@test "remote pull: a same-named different team is refused WITH a way out (#680)" {
  # The refusal was right and said nothing else. An operator learned that two
  # things disagreed -- not which, not that their own team was untouched, not
  # that there are two ways forward.
  #
  # A team joined locally mints its own id, so this is the everyday collision:
  # same name, different team, no history to trip the earlier guard.
  bash "$SCRIPTS/join.sh" clash alice claude-code /tmp/project-clash >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" clash
  [ "$status" -ne 0 ] || return 1

  # Both ids, labelled, so the operator can tell which is which.
  printf '%s\n' "$output" | grep -q 'local id:' || return 1
  printf '%s\n' "$output" | grep -q -F -- "$PULL_TEAM_ID" || return 1
  # And that nothing was half-done.
  printf '%s\n' "$output" | grep -q 'Nothing local was changed' || return 1
  # The ordering point, which is the one that is expensive to learn late.
  printf '%s\n' "$output" | grep -q 'does not tell the server' || return 1

  # The first route is RUN, with its placeholder replaced by a free local name.
  # Parsing argv only shows the line survives a shell; it does not show the
  # line goes anywhere. The previous version of this route re-ran the command
  # that had just failed -- it parsed perfectly and returned the same refusal
  # forever. A way out has to come out.
  line="$(printf '%s\n' "$output" | grep -F -- "remote.sh' pull " | head -1)"
  [ -n "$line" ] || return 1
  run bash -c "${line%%<*}rescued"
  [ "$status" -eq 0 ] || { echo "the printed way out did not run: $output" >&2; return 1; }
  [ -f "$TEST_SKILL_DIR/teams/rescued/config.json" ] || return 1
  # And the local team it refused to touch is still theirs, still its own id.
  [ -f "$TEST_SKILL_DIR/teams/clash/config.json" ] || return 1
  still="$(python3 -c "import json;print(json.load(open('$TEST_SKILL_DIR/teams/clash/config.json'))['team_id'])")"
  [ "$still" != "$PULL_TEAM_ID" ] || return 1
}

@test "remote pull: a CONNECTED local team is not told to rename itself (#680)" {
  # Only one of the two states can take the rename route, and which one is
  # knowable here -- so it is decided here rather than handed over as a caveat.
  # rename-team.sh is local only: it never reads or writes `remote_binding` and
  # never tells the server, so renaming a connected team leaves the binding
  # naming the team the server still knows by the old name.
  bash "$SCRIPTS/join.sh" clashconn alice claude-code /tmp/project-clash-connected >/dev/null
  python3 - "$TEST_SKILL_DIR/teams/clashconn/config.json" <<'PY_BIND'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['remote_binding'] = {'endpoint': 'https://elsewhere.example',
                       'server_instance_id': '018f3f7e-9999-7000-8000-000000000000',
                       'remote_team_id': d['team_id'],
                       'connected_at': '2026-07-30T00:00:00Z',
                       'disconnected_at': None}
open(p, 'w').write(json.dumps(d) + '\n')
PY_BIND
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" clashconn
  [ "$status" -ne 0 ] || return 1
  # Captured before anything else runs. `run` overwrites $output, so a second
  # `run` used to check an ABSENCE would be greping the previous grep's empty
  # stdout -- and passing for that reason.
  out="$output"

  # The route that still works is offered.
  printf '%s\n' "$out" | grep -q -F -- "remote.sh' pull " || return 1
  # The one that would break their binding is not.
  run bash -c 'printf "%s\n" "$1" | grep -q "rename-team.sh"' _ "$out"
  [ "$status" -ne 0 ] || { echo "a connected team was told to rename itself" >&2; return 1; }
  # And it says why, rather than just going quiet.
  printf '%s\n' "$out" | grep -q 'it is connected' || return 1
}

@test "remote pull: a DISCONNECTED local team is still offered the rename (#680)" {
  # "has ever connected" is not "is connected". A disconnected team keeps its
  # connected_at and gains a disconnected_at, and reading the first alone
  # withheld a route it is entitled to. Its name is free to move: the
  # binding it would leave behind is already dead.
  bash "$SCRIPTS/join.sh" clashoff alice claude-code /tmp/project-clash-disconnected >/dev/null
  python3 - "$TEST_SKILL_DIR/teams/clashoff/config.json" <<'PY_BIND'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['remote_binding'] = {'endpoint': 'https://elsewhere.example',
                       'server_instance_id': '018f3f7e-9999-7000-8000-000000000000',
                       'remote_team_id': d['team_id'],
                       'connected_at': '2026-07-30T00:00:00Z',
                       'disconnected_at': '2026-07-31T00:00:00Z'}
open(p, 'w').write(json.dumps(d) + '\n')
PY_BIND
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" clashoff
  [ "$status" -ne 0 ] || return 1
  out="$output"
  printf '%s\n' "$out" | grep -q -F -- "rename-team.sh' " || return 1
  printf '%s\n' "$out" | grep -q 'not connected' || return 1
  run bash -c 'printf "%s\n" "$1" | grep -q "it is connected"' _ "$out"
  [ "$status" -ne 0 ] || { echo "a disconnected team was called connected" >&2; return 1; }
}

@test "remote pull: the way out survives a team with a space and a quote (#680)" {
  # The printed `pull --team-id` line carries the team name back to a shell.
  local qteam="it's a clash"
  bash "$SCRIPTS/join.sh" "$qteam" alice claude-code /tmp/project-clash-quoted >/dev/null
  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" "$qteam"
  [ "$status" -ne 0 ] || return 1
  out="$output"
  # The pull route no longer carries the local name -- it deliberately ends in
  # a placeholder for a FREE one -- so what has to survive a shell there is the
  # endpoint and the id.
  line="$(printf '%s\n' "$out" | grep -F -- "remote.sh' pull " | head -1)"
  [ -n "$line" ] || return 1
  # Everything up to the first placeholder: `<a-free-local-name>` is for the
  # reader to replace, and a shell reads it as a redirection.
  eval "set -- ${line%%<*}"
  [ "$1" = bash ] || return 1
  [ -f "$2" ] || return 1
  [ "$5" = "$ENDPOINT" ] || return 1
  [ "$7" = "$PULL_TEAM_ID" ] || return 1

  # The rename route is where the awkward name has to come back intact.
  line="$(printf '%s\n' "$out" | grep -F -- "rename-team.sh' " | head -1)"
  [ -n "$line" ] || return 1
  eval "set -- ${line%%<*}"
  [ "$1" = bash ] || return 1
  [ -f "$2" ] || return 1
  [ "$3" = "$qteam" ] || return 1
}

@test "remote pull: a caller that owns the guidance gets the ids, not the routes" {
  # Same split as everywhere else: the facts are true however agmsg was
  # invoked; the routes are this install's.
  bash "$SCRIPTS/join.sh" clash2 alice claude-code /tmp/project-clash2 >/dev/null
  AGMSG_OPERATOR_GUIDANCE=caller run bash "$SCRIPTS/remote.sh" pull \
    --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" clash2
  [ "$status" -ne 0 ] || return 1
  printf '%s\n' "$output" | grep -q 'local id:' || return 1
  printf '%s\n' "$output" | grep -q 'Nothing local was changed' || return 1
  run bash -c 'printf "%s\n" "$1" | grep -q "Two ways forward"' _ "$output"
  [ "$status" -ne 0 ] || return 1
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

@test "remote pull: a stream that carried the roster keeps the ordinary advice (#743)" {
  # The positive control for the warning asserted in "clones a team". Without a
  # pull that DOES materialise a roster, a warning printed on every pull and one
  # printed on the right pulls look identical.
  #
  # Both knobs are needed and neither is incidental: MIXED supplies the roster
  # events, and the plain profile keeps this out of the locked branch, which
  # prints neither message. (Setting only MIXED lands in that branch -- which is
  # how this control was found to be measuring nothing.)
  MOCK_PULL_MIXED=1
  MOCK_TEAM_CIPHER_PROFILE=none
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" named
  [ "$status" -eq 0 ]
  local cfg
  cfg="$TEST_SKILL_DIR/teams/named/config.json"
  # The premise of the control, asserted rather than assumed: this machine can
  # name members. If the fixture ever stops carrying them, this fails here
  # instead of silently turning the rest into a test of the empty case.
  [ "$(sqlite_mem "SELECT COUNT(*) FROM json_each(
      json_extract(readfile('$(rf "$cfg")'), '\$.agents'));")" -eq 7 ]

  local cmd_name
  cmd_name="$(basename "$TEST_SKILL_DIR")"
  printf '%s\n' "$output" | grep -q -F -- "This team is now local and ready for normal use."
  printf '%s\n' "$output" | grep -q -F -- \
    "Open your agent and invoke its installed '$cmd_name' command, then join with a new agent name."
  refute grep -qF -- "No members are known here yet." <<<"$output"
  refute grep -qF -- "not yet usable for joining" <<<"$output"
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

@test "remote pull: a declared-sealed EMPTY team without the key does not start its engine (#147)" {
  # The hole the envelope count left. Zero sealed envelopes arrive, so a
  # count-based gate never asks about the key at all and starts the engine --
  # on a machine that cannot read a word of what this team is about to
  # receive. Whether a key is needed is the server's DECLARATION, not the
  # traffic so far.
  MOCK_PULL_AGE=0
  MOCK_TEAM_CIPHER_PROFILE=age-v1
  restart_mock_server

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" encrypted
  [ "$status" -eq 0 ]
  [[ "$output" != *"Sync engine running"* ]]
  [[ "$output" == *"does not hold the key"* ]]
  [[ "$output" == *"local but locked"* ]]
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.encrypted.pid" ]
}

@test "remote pull: a declared-sealed EMPTY team WITH the key starts its engine (#147)" {
  skip_if_no_age
  # The other side of the same gate: same declaration, same zero envelopes,
  # and the key present. Without this case a version that simply never starts
  # the engine for a sealed team would pass the test above.
  MOCK_PULL_AGE=0
  MOCK_TEAM_CIPHER_PROFILE=age-v1
  restart_mock_server

  # The state a caller leaves behind when it delivers key material first: the
  # team exists locally and empty, its config names an epoch, and the identity
  # for that epoch is on disk. Created through join.sh so the team has a real
  # (empty) store -- pull's "already has history" guard reads one, and a
  # hand-written config with no store makes it abort with nothing to show.
  bash "$SCRIPTS/join.sh" encrypted alice claude-code /tmp/project-keyed >/dev/null
  local key_id="epoch-preinstalled" identity recipient cfg updated
  identity="$TEST_SKILL_DIR/run/remote-credentials/encrypted/keys/$key_id.key"
  mkdir -p "$(dirname "$identity")"
  age-keygen -o "$identity" 2>/dev/null
  chmod 600 "$identity"
  recipient="$(age-keygen -y "$identity")"
  cfg="$TEST_SKILL_DIR/teams/encrypted/config.json"
  # The team_id has to be the server's: pull keeps an existing config but
  # refuses one whose id names a different team. A caller pre-seeding this has
  # already resolved the same id, so matching it is what really happens.
  updated="$(sqlite_mem "SELECT json_set(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.team_id', '$PULL_TEAM_ID', '\$.remote_key.current', json_object('key_id', '$key_id', 'recipient', '$recipient'));")"
  printf '%s' "$updated" > "$cfg"

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" encrypted
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sync engine start requested"* ]]
  [[ "$output" == *"holds the key for its current epoch"* ]]
  [[ "$output" != *"does not hold the key"* ]]
  [[ "$output" != *"local but locked"* ]]
}

@test "remote pull: an unreadable local history stops the pull, loudly (#147)" {
  # An unknown history is not an empty one. Rounding it down is how the
  # non-fast-forward guard stops guarding -- the single case it exists to
  # refuse would sail through it. And the old code did worse than round: the
  # failed count aborted the script under set -e with its reason discarded, so
  # the operator saw exit 1 and a blank screen.
  MOCK_TEAM_CIPHER_PROFILE=none
  restart_mock_server
  bash "$SCRIPTS/join.sh" broken alice claude-code /tmp/project-broken >/dev/null

  # A store that exists and cannot be read as one.
  local db
  db="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_db_path broken')"
  mkdir -p "$(dirname "$db")"
  printf 'not a database' > "$db"

  run bash "$SCRIPTS/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$PULL_TEAM_ID" broken
  [ "$status" -ne 0 ]
  # It says something at all -- the defect was silence.
  [ -n "$output" ]
  [[ "$output" == *"cannot read the local history of team 'broken'"* ]]
  # Names the backend, not a path: the guard asks the driver now, and the
  # driver owns where its store lives. A path would be this file guessing.
  [[ "$output" == *"store"* ]]
  [[ "$output" == *"rather than treat an unreadable history as an empty one"* ]]
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

@test "pull decision: the engine follows the key, not the ciphertext (#147)" {
  skip_if_no_age
  # The predicate on its own. The pull fixture cannot produce a team that is
  # both freshly pulled AND already keyed -- that state is created by a caller
  # delivering key material before the pull, which is exactly the case the old
  # test (ciphertext arrived -> halt) got wrong. So this drives the real
  # function against the three states that decide it.
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  {
    echo 'set -euo pipefail'
    echo 'SCRIPT_DIR="$1"; CONNECTION_ROOT="$2"; cfg="$3"'
    echo '. "$SCRIPT_DIR/lib/storage.sh"'
    sed -n '/^_remote_read_config_field() {/,/^}/p' "$SCRIPTS/remote.sh"
    sed -n '/^_remote_holds_current_key() {/,/^}/p' "$SCRIPTS/remote.sh"
    echo '_remote_holds_current_key keyed "$cfg"'
  } > "$probe"

  local cfg="$TEST_SKILL_DIR/teams/keyed/config.json"
  local key_id="epoch-here" identity recipient
  identity="$TEST_SKILL_DIR/run/remote-credentials/keyed/keys/$key_id.key"
  mkdir -p "$(dirname "$cfg")" "$(dirname "$identity")"
  age-keygen -o "$identity" 2>/dev/null
  recipient="$(age-keygen -y "$identity")"

  # Present and matching the recorded epoch: this machine can read.
  jq -nc --arg k "$key_id" --arg r "$recipient" \
    '{name:"keyed", remote_key:{current:{key_id:$k, recipient:$r}}}' > "$cfg"
  run bash "$probe" "$SCRIPTS" "$TEST_SKILL_DIR" "$cfg"
  [ "$status" -eq 0 ]

  # The file is still there, but it is not the key this epoch is sealed to.
  # Presence alone must not answer yes -- that is the difference between
  # "a key is here" and "the key is here".
  jq -nc --arg k "$key_id" \
    '{name:"keyed", remote_key:{current:{key_id:$k, recipient:"age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"}}}' > "$cfg"
  run bash "$probe" "$SCRIPTS" "$TEST_SKILL_DIR" "$cfg"
  [ "$status" -ne 0 ]

  # And with no identity file at all.
  rm -f "$identity"
  jq -nc --arg k "$key_id" --arg r "$recipient" \
    '{name:"keyed", remote_key:{current:{key_id:$k, recipient:$r}}}' > "$cfg"
  run bash "$probe" "$SCRIPTS" "$TEST_SKILL_DIR" "$cfg"
  [ "$status" -ne 0 ]
}

# unlock, with a start refusal injected (#730). advisor ruled this had to be
# pinned rather than described: unlock is the only caller that discards the
# helper's status with `|| true` and converts it, through
# REMOTE_SYNC_ENGINE_PID and the readiness loop, into its own failure. A
# regression that drops the `|| true` or unhooks the readiness handler passes
# every sync-start, pull and connect test in the tree.
#
# The injection is a DIRECTORY at the pidfile path, not a read-only file.
# unlock runs `_remote_sync_engine_stop` first, which ends in
# `rm -f "$pidfile"` -- that succeeds on a read-only file in a writable
# directory and clears the injection before the start it was meant to reach.
# A directory survives: `[ -f ]` is false so stop returns 0 without touching
# it, `rm -f` cannot remove it, and `: > "$pidfile"` fails. Measured.
#
# The fixture is this test's own rather than one lifted out of the two unlock
# tests above. They look alike and are not the same: different bundle and
# envelope paths, a different snapshot export, different ciphertext. Turning
# them into one parameterised helper is a change to two passing tests in a file
# that already flakes under load, and it is not what this PR is about.
@test "remote unlock: a start refusal fails the unlock, and says why (#730)" {
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

  digest="$(shasum -a 256 "$snapshot" | awk '{print $1}')"
  mkdir -p "$PEER_SKILL_DIR/run/remote-sync.encrypted.pid"

  run bash "$peer_scripts/remote.sh" unlock encrypted \
    --bundle "$bundle" --confirm-digest "$digest"
  rmdir "$PEER_SKILL_DIR/run/remote-sync.encrypted.pid" 2>/dev/null || true

  # unlock's purpose IS to start syncing the team, so unlike pull and connect it
  # fails rather than reporting.
  [ "$status" -ne 0 ]
  # The cause, from the refusal ...
  grep -qF "could not start the sync engine" <<<"$output"
  # ... and the outcome, from unlock's own handler. Both, not one: they are
  # different facts and collapsing them is what this change is about.
  grep -qF "did not become ready" <<<"$output"
  refute grep -qF "ready for normal use" <<<"$output"
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
  refute kill -0 "$first_pid" 2>/dev/null
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
  [[ "$output" == *"All prerequisite checks passed"* ]]
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

# --- SHA-256 availability (#861) -------------------------------------------

# All three arms present but failing. Shadowing rather than emptying PATH:
# connect needs most of the toolchain to reach the point under test, and a
# PATH stripped far enough to hide these would stop it much earlier for
# reasons that have nothing to do with #861.
broken_digest_path() {
  local dir tool
  dir="$(mktemp -d)"
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\nexit 1\n' > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
  printf '%s' "$dir"
}

@test "remote doctor: reports a SHA-256 tool, and its absence does not fail the run" {
  local broken; broken="$(broken_digest_path)"
  run env PATH="$broken:$PATH" bash "$SCRIPTS/remote.sh" doctor
  # Optional, exactly like age: a team on cipher "none" never computes one.
  [ "$status" -eq 0 ]
  # "usable", not "on PATH": this shim IS on PATH and fails when run, which is
  # the distinction the line was reworded to keep -- see hash.sh.
  grep -qF -- '[ ] usable SHA-256 tool' <<<"$output"
  # grep, not `[[ ]]`: a non-last `[[ ]]` cannot fail a test on bash 3.2 (#670).
  # The summary was narrowed to "prerequisite" when doctor gained the lock
  # report (#865): an unqualified "All checks passed." sitting above a stale
  # lock and a removal command reads as cancelling the diagnosis.
  grep -qF -- 'All prerequisite checks passed' <<<"$output"
}

@test "remote doctor: reports the SHA-256 tool as usable when one works" {
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- '[x] usable SHA-256 tool' <<<"$output"
}

# The bug this preflight exists for: the first SHA-256 in a `connect --e2ee`
# happens after the team is registered with the server, so the operator's news
# of a missing tool arrived as a half-finished connect.
@test "remote connect --e2ee: refuses BEFORE registering when no SHA-256 works" {
  local broken; broken="$(broken_digest_path)"
  run env PATH="$broken:$PATH" bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" --e2ee testteam
  [ "$status" -ne 0 ]
  grep -qF -- 'SHA-256' <<<"$output"
  # And the team is still unregistered. This is the half that makes it a
  # PREflight: asserting only the message would pass just as well if the
  # check ran after the POST.
  run python3 -c "import json;print(json.load(open('$SCRIPTS/../teams/testteam/config.json')).get('remote_binding'))"
  [ "$output" = "None" ]
}

# Plain sync never computes a SHA-256, so the same broken machine must still
# be able to connect. Without this the preflight could be moved ahead of the
# --e2ee test and nothing would notice.
@test "remote connect without --e2ee: a broken SHA-256 tool does not block it" {
  local broken; broken="$(broken_digest_path)"
  run env PATH="$broken:$PATH" bash "$SCRIPTS/remote.sh" connect --endpoint "$ENDPOINT" testteam
  [ "$status" -eq 0 ]
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
  [[ "$output" == *"could not look up 'pulled-team'"* ]]
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

# --- doctor names the wedged lock, and removes nothing (#865) ---------------
#
# A registry lock left by a killed process is never broken: acquire waits out
# its budget and says "timed out acquiring registry lock", which describes
# contention, and no message anywhere names the directory to remove. `doctor` is
# where that becomes findable.

doctor_lock_dead_pid() {  # a pid that is genuinely not running
  local p
  sleep 0 &
  p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

make_lock() {  # make_lock <team> [pid]
  mkdir -p "$TEST_SKILL_DIR/teams/$1"
  mkdir -p "$TEST_SKILL_DIR/teams/$1/.config.lock"
  if [ -n "${2:-}" ]; then
    printf 'token t\npid %s\ncommand join.sh\nhost h\n' "$2" \
      > "$TEST_SKILL_DIR/teams/$1/.config.lock.holder"
  fi
}

@test "remote doctor: a lock whose holder is gone is named, with the way out (#865)" {
  local gone; gone="$(doctor_lock_dead_pid)"
  # CONTROL: the pid really is not running, asserted before it is written into
  # the holder — a number that merely happened to be free would make this pass
  # for a reason that has nothing to do with the report.
  run bash -c ". \"$SCRIPTS/lib/instance-id.sh\"; _agmsg_pid_alive_local $gone"
  [ "$status" -ne 0 ]

  make_lock wedged "$gone"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- "wedged: stale — pid $gone is not running" <<<"$output"
  grep -qF -- "rm -r " <<<"$output"
  # REPORTS ONLY. The whole point of doing this before an automatic sweep is
  # that a wrong verdict must not cost anything.
  [ -d "$TEST_SKILL_DIR/teams/wedged/.config.lock" ]
}

@test "remote doctor: a lock whose holder is alive is not called stale (#865)" {
  sleep 30 &
  local live=$!
  # CONTROL: alive at the moment doctor runs, not merely spawned.
  run bash -c ". \"$SCRIPTS/lib/instance-id.sh\"; _agmsg_pid_alive_local $live"
  [ "$status" -eq 0 ]

  make_lock busy "$live"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- "busy: held — pid $live is running" <<<"$output"
  # And it must NOT offer to remove a lock somebody is using.
  refute grep -qF -- "if no agmsg command is running for this team" <<<"$output"
  kill "$live" 2>/dev/null || true
}

@test "remote doctor: a lock with no holder record says it cannot tell (#865)" {
  # Neither "held" nor "gone": written by a version that recorded nothing, or by
  # a process killed between creating the lock and writing its record. Guessing
  # here is what would cost a live lock.
  make_lock unknown
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- "unknown: cannot tell — no holder recorded" <<<"$output"
  grep -qF -- "rm -r " <<<"$output"
}

@test "remote doctor: says nothing about locks when there are none (#865)" {
  # The negative control for the three above: the section is absent on a healthy
  # install, so "Registry locks:" appearing at all is a finding.
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  refute grep -qF -- "Registry locks:" <<<"$output"
}

@test "remote doctor: a lock does not fail the run (#865)" {
  # A team being locked is not a failed prerequisite. If it set the exit code,
  # doctor would fail every time somebody is joining.
  local gone; gone="$(doctor_lock_dead_pid)"
  make_lock wedged "$gone"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- "All prerequisite checks passed." <<<"$output"
}

@test "remote doctor <team>: reports that team's lock and not another's (#865)" {
  local gone; gone="$(doctor_lock_dead_pid)"
  make_lock mine "$gone"
  make_lock theirs "$gone"
  run bash "$SCRIPTS/remote.sh" doctor mine
  [ "$status" -eq 0 ]
  grep -qF -- "mine: stale" <<<"$output"
  refute grep -qF -- "theirs: stale" <<<"$output"
}

@test "remote doctor: a pid that was never asked about is not called stale (#865)" {
  # THE VERDICT AND THE REMOVAL RIDE TOGETHER, so "false" from the liveness
  # helper is not enough on its own: it is also false for a value the helper
  # refused to put to the process table at all. `pid not-a-pid` and a number
  # past the POSIX ceiling were being reported as stale, with `rm -r` beside
  # them (raised in review).
  make_lock badpid
  printf 'token t\npid not-a-pid\ncommand join.sh\nhost h\n' \
    > "$TEST_SKILL_DIR/teams/badpid/.config.lock.holder"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- "badpid: cannot tell" <<<"$output"
  refute grep -qF -- "badpid: stale" <<<"$output"

  # CONTROL: the helper does answer false for it, so this case is measuring the
  # validation and not some other difference.
  run bash -c ". \"$SCRIPTS/lib/instance-id.sh\"; _agmsg_pid_alive_local not-a-pid"
  [ "$status" -ne 0 ]
}

@test "remote doctor: a pid past the POSIX ceiling is not called stale (#865)" {
  make_lock hugepid
  printf 'token t\npid 2147483648\ncommand join.sh\nhost h\n' \
    > "$TEST_SKILL_DIR/teams/hugepid/.config.lock.holder"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- "hugepid: cannot tell" <<<"$output"
  refute grep -qF -- "hugepid: stale" <<<"$output"
}

@test "remote doctor: a team whose name begins with a dot is swept too (#865)" {
  # `*` does not match a leading dot, and the team validator allows one — so the
  # sweep walked past `.hidden` entirely (raised in review). The validator
  # rejects empty, `.`, `..`, a leading `-`, `/`, `\` and control characters,
  # and nothing else.
  local gone; gone="$(doctor_lock_dead_pid)"
  make_lock .hidden "$gone"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- ".hidden: stale" <<<"$output"
}

@test "remote doctor: the summary does not cancel a lock finding (#865)" {
  # "All checks passed." above a stale lock and a removal command reads as
  # withdrawing them. The exit code deliberately stays 0 — a locked team is not
  # a failed prerequisite — so the wording is what has to carry the distinction.
  local gone; gone="$(doctor_lock_dead_pid)"
  make_lock wedged "$gone"
  run bash "$SCRIPTS/remote.sh" doctor
  [ "$status" -eq 0 ]
  grep -qF -- "All prerequisite checks passed." <<<"$output"
  refute grep -qE '^All checks passed\.$' <<<"$output"
}

@test "remote doctor <team>: a traversal argument is refused and reads nothing (#865)" {
  # The named-team lookup builds a path from the argument, and until this was
  # added nothing had ever validated it — `cmd_doctor` only ever put the value
  # in a header sentence. A sentinel outside the store proves the refusal is
  # about reach and not about the string.
  local outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside/.config.lock"
  printf 'token t\npid 1\ncommand join.sh\nhost h\n' > "$outside/.config.lock.holder"
  # CONTROL: the sentinel is real and would be reported if it were reached —
  # the same shape, under a team name, IS reported (the case above).
  [ -d "$outside/.config.lock" ]

  run bash "$SCRIPTS/remote.sh" doctor "../../$(basename "$BATS_TEST_TMPDIR")/outside"
  [ "$status" -ne 0 ]
  refute grep -qF -- "Registry locks:" <<<"$output"
  refute grep -qF -- "rm -r " <<<"$output"
  grep -qF -- "invalid team name" <<<"$output"
  # And it must not claim the prerequisites verdict for a question it refused.
  refute grep -qF -- "All prerequisite checks passed." <<<"$output"
}

@test "remote doctor <team>: a slash in the name is refused (#865)" {
  run bash "$SCRIPTS/remote.sh" doctor "a/b"
  [ "$status" -ne 0 ]
  grep -qF -- "invalid team name" <<<"$output"
}

@test "remote doctor <team>: an ordinary and a dot-leading name still resolve (#865)" {
  # The validator allows both, and the direct lookup has to keep working for
  # them — a refusal that took the legitimate names with it would be the
  # cheapest way to pass the two cases above.
  local gone; gone="$(doctor_lock_dead_pid)"
  make_lock plain "$gone"
  make_lock .dotted "$gone"
  run bash "$SCRIPTS/remote.sh" doctor plain
  [ "$status" -eq 0 ]
  grep -qF -- "plain: stale" <<<"$output"
  run bash "$SCRIPTS/remote.sh" doctor .dotted
  [ "$status" -eq 0 ]
  grep -qF -- ".dotted: stale" <<<"$output"
}
