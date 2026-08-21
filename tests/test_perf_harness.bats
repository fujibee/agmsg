#!/usr/bin/env bats

load test_helper

# tests/perf: the join/push measurement harness (#910) and the mock paging it
# leans on. Two things are pinned here:
#
#   1. tests/helpers/mock_remote_server.py pages the way the reference server
#      does, so what the harness measures is what production would serve.
#   2. report.py treats a missing event as a failure, never as a zero -- a
#      harness that reads silence as speed would report a broken stage as the
#      fastest one.
#
# The end-to-end smoke runs the real harness at a tiny size: it is the same
# path as a 17,300-message run, only short.

setup() {
  setup_test_env
  MOCK_PYTHON3="$(command -v python3)"
  PERF="$BATS_TEST_DIRNAME/perf"
  MOCK_PID=""
}

teardown() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  teardown_test_env
}

start_mock_with_history() {  # count  (1 roster event + count-1 messages = count lines)
  "$MOCK_PYTHON3" "$PERF/gen-history.py" --messages "$(( $1 - 1 ))" --roster 1 \
    --out "$TEST_SKILL_DIR/history.jsonl" >/dev/null
  MOCK_PULL_FILE="$TEST_SKILL_DIR/history.jsonl" MOCK_TEAM_CIPHER_PROFILE=none \
    "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  MOCK_PID=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  ENDPOINT="http://127.0.0.1:$(cat "$TEST_SKILL_DIR/server.port")"
  PULL_TEAM_ID="018f3f7e-2222-7000-8000-000000000002"
}

page() {  # route-with-query  -> JSON body
  curl -sS -H "Agmsg-Team-ID: $PULL_TEAM_ID" -H "Agmsg-Protocol-Version: 1" "$ENDPOINT$1"
}

@test "mock paging: limit defaults to 100, LIMIT+1 drives has_more, next_after is the last seq" {
  start_mock_with_history 250
  local body
  # Default limit (no limit= in the query) is 100, as in server/src/protocol.ts.
  body="$(page "/v1/teams/$PULL_TEAM_ID/messages?after=0")"
  [ "$(jq -r '.messages | length' <<<"$body")" -eq 100 ]
  [ "$(jq -r '.has_more' <<<"$body")" = "true" ]
  [ "$(jq -r '.next_after' <<<"$body")" = "100" ]
  [ "$(jq -r '.messages[0].server_seq' <<<"$body")" = "1" ]
  # The last page: fewer than limit rows left, so has_more is false.
  body="$(page "/v1/teams/$PULL_TEAM_ID/messages?after=100&limit=1000")"
  [ "$(jq -r '.messages | length' <<<"$body")" -eq 150 ]
  [ "$(jq -r '.has_more' <<<"$body")" = "false" ]
  [ "$(jq -r '.next_after' <<<"$body")" = "250" ]
  # Exactly `limit` rows left: the probe row past the page does not exist, so
  # has_more is false even though the page is full.
  body="$(page "/v1/teams/$PULL_TEAM_ID/messages?after=150&limit=100")"
  [ "$(jq -r '.messages | length' <<<"$body")" -eq 100 ]
  [ "$(jq -r '.has_more' <<<"$body")" = "false" ]
  # An empty page answers the supplied cursor back.
  body="$(page "/v1/teams/$PULL_TEAM_ID/messages?after=250")"
  [ "$(jq -r '.messages | length' <<<"$body")" -eq 0 ]
  [ "$(jq -r '.next_after' <<<"$body")" = "250" ]
  [ "$(jq -r '.has_more' <<<"$body")" = "false" ]
}

@test "mock paging: the authenticated route pages the same way, and a bad limit is 400" {
  start_mock_with_history 250
  local body code
  body="$(page "/v1/messages?after=200&limit=30")"
  [ "$(jq -r '.messages | length' <<<"$body")" -eq 30 ]
  [ "$(jq -r '.messages[0].server_seq' <<<"$body")" = "201" ]
  [ "$(jq -r '.next_after' <<<"$body")" = "230" ]
  [ "$(jq -r '.has_more' <<<"$body")" = "true" ]
  for bad in 0 1001 abc 007; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Agmsg-Team-ID: $PULL_TEAM_ID" \
      "$ENDPOINT/v1/messages?after=0&limit=$bad")"
    [ "$code" = "400" ]
  done
}

@test "report: a phase that lost an expected event fails and names it" {
  local work="$TEST_SKILL_DIR/work"
  mkdir -p "$work"
  # A join whose bootstrap never reported a page: apply must not read as 0s.
  cat > "$work/events.jsonl" <<'EOF'
{"at":"2026-08-21T00:00:00.000Z","event":"harness.phase","phase":"pull"}
{"at":"2026-08-21T00:00:00.100Z","event":"pull.bootstrap.snapshot","team_id":"x"}
{"at":"2026-08-21T00:00:05.000Z","event":"harness.phase","phase":"once"}
{"at":"2026-08-21T00:00:05.100Z","event":"capabilities"}
{"at":"2026-08-21T00:00:05.200Z","event":"push.prepared","count":0}
{"at":"2026-08-21T00:00:05.300Z","event":"pull.received","messages":[]}
{"at":"2026-08-21T00:00:05.400Z","event":"pull.applied"}
{"at":"2026-08-21T00:00:06.000Z","event":"harness.phase","phase":"reprocess"}
{"at":"2026-08-21T00:00:06.500Z","event":"reprocess.complete","count":0}
{"at":"2026-08-21T00:00:07.000Z","event":"harness.phase","phase":"done"}
EOF
  run python3 "$PERF/report.py" summarize --work "$work" --scenario join \
    --messages 5 --roster 1 --page 1000 --out "$work/summary.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'MISSING EVENTS'
  printf '%s\n' "$output" | grep -q 'pull: pull.bootstrap.applied'
  [ "$(jq -r '.ok' "$work/summary.json")" = "false" ]
  # And the stage that had no event is not a measured zero.
  [ "$(jq -r '.stages["bootstrap.apply"].calls' "$work/summary.json")" -eq 0 ]
}

@test "report: an engine cycle with no pull page fails even when another cycle had one" {
  local work="$TEST_SKILL_DIR/work"
  mkdir -p "$work"
  # Cycle 1 is complete; cycle 2 prepared nothing AND reported no pull page.
  # The phase-level expected set is satisfied by cycle 1 alone, so only a
  # per-cycle check catches cycle 2 -- every cycle pulls at least one page.
  cat > "$work/events.jsonl" <<'EOF'
{"at":"2026-08-21T00:00:00.000Z","event":"harness.phase","phase":"seed"}
{"at":"2026-08-21T00:00:00.100Z","event":"harness.seed","count":2,"seconds":0.01}
{"at":"2026-08-21T00:00:01.000Z","event":"harness.phase","phase":"connect"}
{"at":"2026-08-21T00:00:02.000Z","event":"harness.phase","phase":"engine"}
{"at":"2026-08-21T00:00:02.100Z","event":"capabilities"}
{"at":"2026-08-21T00:00:02.200Z","event":"push.prepared","count":2}
{"at":"2026-08-21T00:00:02.250Z","event":"push.posted","count":2}
{"at":"2026-08-21T00:00:02.300Z","event":"push.ack","acks":[{"id":"a","server_seq":"1","disposition":"stored"},{"id":"b","server_seq":"2","disposition":"stored"}]}
{"at":"2026-08-21T00:00:02.301Z","event":"push.reconciled"}
{"at":"2026-08-21T00:00:02.400Z","event":"pull.received","messages":[{"id":"a","server_seq":"1"},{"id":"b","server_seq":"2"}]}
{"at":"2026-08-21T00:00:02.900Z","event":"pull.applied"}
{"at":"2026-08-21T00:00:08.000Z","event":"capabilities"}
{"at":"2026-08-21T00:00:08.100Z","event":"push.prepared","count":0}
{"at":"2026-08-21T00:00:09.000Z","event":"harness.phase","phase":"once"}
{"at":"2026-08-21T00:00:09.100Z","event":"capabilities"}
{"at":"2026-08-21T00:00:09.200Z","event":"push.prepared","count":0}
{"at":"2026-08-21T00:00:09.300Z","event":"pull.received","messages":[]}
{"at":"2026-08-21T00:00:09.400Z","event":"pull.applied"}
{"at":"2026-08-21T00:00:10.000Z","event":"harness.phase","phase":"reprocess"}
{"at":"2026-08-21T00:00:10.500Z","event":"reprocess.complete","count":0}
{"at":"2026-08-21T00:00:11.000Z","event":"harness.phase","phase":"done"}
EOF
  run python3 "$PERF/report.py" summarize --work "$work" --scenario push \
    --messages 2 --roster 1 --page 1000 --out "$work/summary.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'engine cycle 2: pull.received'
  # And the first cycle's push is split at the POST boundary the engine reports:
  # post = push.prepared -> push.posted, reconcile = push.posted -> push.ack.
  [ "$(jq -r '.stages["engine.post"].calls' "$work/summary.json")" -eq 1 ]
  [ "$(jq -r '.stages["engine.post"].seconds' "$work/summary.json")" = "0.05" ]
  [ "$(jq -r '.stages["engine.reconcile"].seconds' "$work/summary.json")" = "0.05" ]
}

@test "report: an ack without the POST-completion event is unreported, not a zero-length POST" {
  local work="$TEST_SKILL_DIR/work"
  mkdir -p "$work"
  cat > "$work/events.jsonl" <<'EOF'
{"at":"2026-08-21T00:00:00.000Z","event":"harness.phase","phase":"seed"}
{"at":"2026-08-21T00:00:00.100Z","event":"harness.seed","count":1,"seconds":0.01}
{"at":"2026-08-21T00:00:01.000Z","event":"harness.phase","phase":"connect"}
{"at":"2026-08-21T00:00:02.000Z","event":"harness.phase","phase":"engine"}
{"at":"2026-08-21T00:00:02.100Z","event":"capabilities"}
{"at":"2026-08-21T00:00:02.200Z","event":"push.prepared","count":1}
{"at":"2026-08-21T00:00:02.300Z","event":"push.ack","acks":[{"id":"a","server_seq":"1","disposition":"stored"}]}
{"at":"2026-08-21T00:00:02.301Z","event":"push.reconciled"}
{"at":"2026-08-21T00:00:02.400Z","event":"pull.received","messages":[{"id":"a","server_seq":"1"}]}
{"at":"2026-08-21T00:00:02.900Z","event":"pull.applied"}
{"at":"2026-08-21T00:00:08.000Z","event":"capabilities"}
{"at":"2026-08-21T00:00:08.100Z","event":"push.prepared","count":0}
{"at":"2026-08-21T00:00:08.200Z","event":"pull.received","messages":[]}
{"at":"2026-08-21T00:00:08.300Z","event":"pull.applied"}
{"at":"2026-08-21T00:00:09.000Z","event":"harness.phase","phase":"once"}
{"at":"2026-08-21T00:00:09.100Z","event":"capabilities"}
{"at":"2026-08-21T00:00:09.200Z","event":"push.prepared","count":0}
{"at":"2026-08-21T00:00:09.300Z","event":"pull.received","messages":[]}
{"at":"2026-08-21T00:00:09.400Z","event":"pull.applied"}
{"at":"2026-08-21T00:00:10.000Z","event":"harness.phase","phase":"reprocess"}
{"at":"2026-08-21T00:00:10.500Z","event":"reprocess.complete","count":0}
{"at":"2026-08-21T00:00:11.000Z","event":"harness.phase","phase":"done"}
EOF
  run python3 "$PERF/report.py" summarize --work "$work" --scenario push \
    --messages 1 --roster 1 --page 1000 --out "$work/summary.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'engine cycle 1: push.posted'
  [ "$(jq -r '.stages["engine.post"].calls' "$work/summary.json")" -eq 0 ]
}

@test "harness: join of a small history measures every stage on the shipped path" {
  local out="$TEST_SKILL_DIR/perf-out" summary
  run bash "$PERF/join-harness.sh" --messages 4 --roster 2 --out "$out"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'verdict: OK'
  summary="$out/join-4/summary.json"
  [ -f "$summary" ]
  [ "$(jq -r '.ok' "$summary")" = "true" ]
  [ "$(jq -r '.missing | length' "$summary")" -eq 0 ]
  [ "$(jq -r '.bootstrap.messages' "$summary")" -eq 6 ]
  [ "$(jq -r '.stages["bootstrap.apply"].items' "$summary")" -eq 6 ]
  [ "$(jq -r '.stages["bootstrap.apply"].calls' "$summary")" -ge 1 ]
  # The messages are in the private store and nowhere else.
  [ "$(jq -r '.state.messages_in_store' "$summary")" -eq 4 ]
  [ "$(jq -r '.state.roster_agents' "$summary")" -eq 2 ]
  # Not-exercised stages say so instead of reporting a time.
  [ "$(jq -r '.stages["reprocess.total"].exercised' "$summary")" = "false" ]
  [ "$(jq -r '.stages["once.post"].exercised' "$summary")" = "false" ]
  [ "$(jq -r '.stages["once.reconcile"].exercised' "$summary")" = "false" ]
  # Nothing was written into this test's own skill dir by the run: the harness
  # copied scripts/ under $out and pointed every path there.
  [ ! -d "$TEST_SKILL_DIR/teams/pulled-team" ]
  [ ! -f "$TEST_SKILL_DIR/run/remote-sync.pulled-team.pid" ]
}
