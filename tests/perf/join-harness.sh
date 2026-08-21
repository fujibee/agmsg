#!/usr/bin/env bash
# Measure a history-proportional join (or first push) of a synthetic team, stage
# by stage, without touching any real install (#910).
#
#   tests/perf/join-harness.sh --sizes 50,1000            # join, two sizes, compared
#   tests/perf/join-harness.sh --scenario push --sizes 50,1000
#   tests/perf/join-harness.sh --messages 17300 --keep    # one size, keep the tree
#
# What runs is the SHIPPED PATH, unmodified: `remote.sh pull` (bootstrap pages
# through the storage driver), the engine's own cycle (`remote-sync.sh once`),
# and `remote-sync.sh reprocess` -- or for --scenario push, `remote.sh connect`
# and the engine's catch-up cycles until it drains. It runs inside a private
# copy of scripts/ with its own store, HOME and team registry, against
# tests/helpers/mock_remote_server.py serving a generated history, so nothing
# here reads or writes the operator's ~/.agents, db/ or teams/.
#
# Stage times come from the engine's own event log (AGMSG_SYNC_LOG_FILE, ms
# timestamps) and the bootstrap's progress lines; see report.py for the
# derivation and for the rule that a missing event fails the run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

SCENARIO=join
SIZES=""
MESSAGES=""
ROSTER=3
PAGE=1000   # the client's own bootstrap page size; not a knob here, recorded for the report
OUT=""
KEEP=0
TIMEOUT=0
PROJECT=17300
PRELOADED=0   # unlock only: plain messages served (and imported) before the sealed ones
BODY_BYTES=120

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'
options:
  --scenario join|push|unlock
                         join:   pull a team with history (default)
                         push:   connect a local team with history, drain the engine
                         unlock: pull an age-v1 team without its key (every message
                                 quarantined), then unlock with a handed bundle -- the
                                 reprocess of N quarantined rows is what gets measured
                                 (needs age and age-keygen on PATH)
  --sizes N,M,...        run each size, then compare (ratio table + conclusions)
  --messages N           one size (same as --sizes N)
  --roster R             member_joined events that lead the history (default 3)
  --body-bytes B         body size per synthetic message (default 120)
  --timeout SEC          push only: give up waiting for the engine to drain (default: wait)
  --preloaded M          unlock only: serve M plain messages BEFORE the sealed ones, so the
                         pull imports M into the store first and the unlock's reprocess then
                         runs its N candidates against a store that already holds M (default 0)
  --project N            size the comparison projects to (default 17300)
  --out DIR              where runs go (default: a fresh mktemp -d)
  --keep                 leave the run directories in place (default with --out)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIO="${2:?}"; shift 2 ;;
    --sizes) SIZES="${2:?}"; shift 2 ;;
    --messages) MESSAGES="${2:?}"; shift 2 ;;
    --roster) ROSTER="${2:?}"; shift 2 ;;
    --body-bytes) BODY_BYTES="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --preloaded) PRELOADED="${2:?}"; shift 2 ;;
    --project) PROJECT="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; KEEP=1; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "join-harness: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$SCENARIO" in join|push|unlock) ;; *) echo "join-harness: --scenario must be join, push or unlock" >&2; exit 2 ;; esac
if [ -n "$MESSAGES" ]; then SIZES="${SIZES:+$SIZES,}$MESSAGES"; fi
[ -n "$SIZES" ] || { echo "join-harness: give --sizes N,M or --messages N" >&2; exit 2; }

for tool in python3 node sqlite3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "join-harness: needs $tool on PATH" >&2; exit 2; }
done
if [ "$SCENARIO" = unlock ]; then
  for tool in age age-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { echo "join-harness: --scenario unlock needs $tool on PATH" >&2; exit 2; }
  done
fi

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-perf.XXXXXX")"
fi
mkdir -p "$OUT"
echo "join-harness: runs under $OUT"

# The mock server and any engine we started are ours to stop; nothing else is.
CHILD_PIDS=()
cleanup() {
  local pid
  for pid in "${CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  if [ "$KEEP" -ne 1 ]; then rm -rf "$OUT"; fi
}
trap cleanup EXIT INT TERM

now_iso() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]+"Z")'; }
epoch() { python3 -c 'import time;print(time.time())'; }

# A harness marker in the same log the engine writes to, so report.py can
# attribute every engine event to the phase that was running.
mark() {
  printf '{"at":"%s","event":"harness.phase","phase":"%s"}\n' "$(now_iso)" "$1" >> "$EVENTS"
  echo "join-harness: [$(date -u +%H:%M:%S)] phase $1"
}
note_event() {  # name, json-fields
  printf '{"at":"%s","event":"%s",%s}\n' "$(now_iso)" "$1" "$2" >> "$EVENTS"
}

# Stop the sync engine that `remote.sh pull` / `connect` started for the team,
# by the pidfile that command wrote inside OUR private tree. Same shape as
# tests/test_remote.bats cleanup_sync_engines: positive evidence of exit.
stop_engine() {
  local pidfile="$SKILL/run/remote-sync.$1.pid" pid i
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || { echo "join-harness: odd pid in $pidfile: '$pid'" >&2; return 1; }
  kill "$pid" 2>/dev/null || true
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  echo "join-harness: engine $pid did not exit after TERM; sending KILL" >&2
  kill -KILL "$pid" 2>/dev/null || true
}

# The engine is between cycles -- asleep, holding no driver and no lock -- once
# it has stamped a cycle success after `since`: recordCycleSuccess writes
# run/remote-sync.<team>.cycles.json at the end of every successful cycle, and
# nothing else writes it. Stopping it anywhere else would kill a driver mid-call.
wait_engine_asleep() {  # team, since-iso, [timeout-seconds]
  local stamp="$SKILL/run/remote-sync.$1.cycles.json" since="$2" limit="${3:-60}" i
  for i in $(seq 1 $((limit * 10))); do
    if [ -f "$stamp" ] && python3 -c '
import json, sys
try:
    last = json.load(open(sys.argv[1])).get("last_success_at", "")
except Exception:
    sys.exit(1)
sys.exit(0 if last > sys.argv[2] else 1)' "$stamp" "$since"; then
      return 0
    fi
    sleep 0.1
  done
  echo "join-harness: engine for $1 did not finish a cycle within ${limit}s of $since; stopping it anyway" >&2
  return 1
}

run_command() {  # label, command...  -- stdout/stderr captured, non-zero is fatal
  local label="$1"; shift
  local t0 t1 rc=0
  t0="$(epoch)"
  "$@" > "$WORK/$label.out" 2> "$WORK/$label.err" || rc=$?
  t1="$(epoch)"
  if [ "$rc" -ne 0 ]; then
    echo "join-harness: $label failed (exit $rc); stderr:" >&2
    tail -n 30 "$WORK/$label.err" >&2
    exit 1
  fi
  python3 -c 'import sys;print(f"join-harness:   {sys.argv[1]} took {float(sys.argv[3])-float(sys.argv[2]):.1f}s")' "$label" "$t0" "$t1"
}

start_mock() {  # history-file [pull-team-id] [cipher-profile]
  : > "$WORK/server.port"
  MOCK_PULL_FILE="$1" MOCK_PULL_TEAM_ID="${2:-}" MOCK_TEAM_CIPHER_PROFILE="${3:-none}" \
    python3 "$REPO/tests/helpers/mock_remote_server.py" 0 \
    </dev/null > "$WORK/server.port" 2>> "$WORK/server.log" 3>&- &
  MOCK_PID=$!
  CHILD_PIDS+=("$MOCK_PID")
  local i
  for i in $(seq 1 100); do
    if grep -q '^[0-9][0-9]*$' "$WORK/server.port" 2>/dev/null; then break; fi
    sleep 0.1
  done
  MOCK_PORT="$(cat "$WORK/server.port")"
  [[ "$MOCK_PORT" =~ ^[0-9]+$ ]] || { echo "join-harness: mock server did not start; see $WORK/server.log" >&2; exit 1; }
  ENDPOINT="http://127.0.0.1:$MOCK_PORT"
}

# The team's store, asked of the storage layer the way the product asks it,
# never assembled here. Read-only SELECTs against OUR private store follow.
db_path() {
  SKILL_DIR="$SKILL" bash -c '. "$SKILL_DIR/scripts/lib/storage.sh"; agmsg_storage_load; agmsg_db_path "$1"' _ "$1"
}

record_state() {  # team
  local team="$1" db messages quarantine members roster
  db="$(db_path "$team")"
  messages="$(sqlite3 "$db" "SELECT count(*) FROM events WHERE type='message_sent' AND team='$team';" 2>/dev/null || echo null)"
  quarantine="$(sqlite3 -json "$db" "SELECT status, count(*) AS n FROM sync_quarantine GROUP BY status ORDER BY status;" 2>/dev/null || echo '[]')"
  [ -n "$quarantine" ] || quarantine='[]'
  members="$(sqlite3 "$db" "SELECT count(*) FROM sync_read_members;" 2>/dev/null || echo null)"
  roster="$(jq '.agents | length' "$SKILL/teams/$team/config.json" 2>/dev/null || echo null)"
  jq -n --argjson messages "${messages:-null}" --argjson quarantine "$quarantine" \
        --argjson read_members "${members:-null}" --argjson roster "${roster:-null}" \
        '{messages_in_store: $messages, sync_quarantine: $quarantine,
          sync_read_members: $read_members, roster_agents: $roster}' > "$WORK/state.json"
}

# --- one run ------------------------------------------------------------------

run_one() {
  local size="$1"
  WORK="$OUT/$SCENARIO-$size${PRELOADED:+-pre$PRELOADED}"
  [ "$PRELOADED" -eq 0 ] && WORK="$OUT/$SCENARIO-$size"
  SKILL="$WORK/skill"
  EVENTS="$WORK/events.jsonl"
  # A previous run's directory is evidence, not clutter: refuse rather than
  # erase it. With no --out, $OUT is a fresh mktemp -d and this never fires.
  if [ -e "$WORK" ]; then
    echo "join-harness: $WORK already exists (an earlier run?); choose another --out or move it aside" >&2
    exit 2
  fi
  mkdir -p "$SKILL" "$WORK/home" "$WORK/project"
  cp -R "$REPO/scripts/." "$SKILL/scripts/"
  chmod +x "$SKILL/scripts/"*.sh "$SKILL/scripts/internal/"*.sh "$SKILL/scripts/drivers/storage/"*.sh 2>/dev/null || true

  # Everything the product resolves from its own location now resolves into
  # $SKILL; everything it resolves from the environment is pointed there too.
  export HOME="$WORK/home"
  export AGMSG_STORAGE_PATH="$SKILL/db"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_SYNC_LOG_FILE="$EVENTS"
  unset AGMSG_SYNC_CONNECTION_DIR AGMSG_SYNC_TRUST_DIR SKILL_DIR 2>/dev/null || true
  bash "$SKILL/scripts/internal/init-db.sh" >/dev/null
  : > "$EVENTS"

  echo "join-harness: == $SCENARIO, $size messages (+$ROSTER roster), page $PAGE -> $WORK"
  # unlock seals its history to a key that does not exist yet; it generates later.
  if [ "$SCENARIO" != unlock ]; then
    python3 "$HERE/gen-history.py" --messages "$size" --roster "$ROSTER" \
      --body-bytes "$BODY_BYTES" --out "$WORK/history.jsonl"
  fi

  case "$SCENARIO" in
    join) run_join "$size" ;;
    push) run_push "$size" ;;
    unlock) run_unlock "$size" ;;
  esac
  mark done
  python3 "$HERE/report.py" summarize --work "$WORK" --scenario "$SCENARIO" \
    --messages "$size" --roster "$ROSTER" --page "$PAGE" --preloaded "$PRELOADED" \
    --out "$WORK/summary.json" || RUN_STATUS=$?
}

run_join() {
  local team=pulled-team   # the name the mock's /v1/teams lookup answers for
  start_mock "$WORK/history.jsonl"

  # The join. stderr carries the bootstrap's own progress lines ("fetching
  # messages after N", "applying N messages"); timestamped on arrival they are
  # what separates a page's fetch from its apply. stdout is kept as-is.
  mark pull
  local rc=0 pull_started
  pull_started="$(now_iso)"
  set +e
  bash "$SKILL/scripts/remote.sh" pull --endpoint "$ENDPOINT" "$team" \
    2>&1 1> "$WORK/pull.out" | python3 "$HERE/report.py" ts > "$WORK/pull.stderr.ts"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "join-harness: remote.sh pull failed (exit $rc); stderr:" >&2
    tail -n 30 "$WORK/pull.stderr.ts" >&2
    exit 1
  fi
  sed 's/^/join-harness:   pull: /' "$WORK/pull.out"
  # pull starts the engine for the team. Let its first cycle land (it finds
  # nothing to push and nothing new to pull) so it is asleep, then stop it:
  # the cycles we time are the explicit ones below.
  wait_engine_asleep "$team" "$pull_started" 120 || true
  stop_engine "$team"

  mark once
  run_command once bash "$SKILL/scripts/remote-sync.sh" once --team "$team"
  mark reprocess
  run_command reprocess bash "$SKILL/scripts/remote-sync.sh" reprocess --team "$team"
  record_state "$team"
}

# Seed N local messages through the product's own INSERT shape: the SQL comes
# from the sqlite driver's writer (with placeholders), so the fixture cannot
# drift from what `storage_send` writes; only the per-row substitution is ours.
seed_local() {  # team, count
  local team="$1" count="$2" db template t0 t1 seconds
  db="$(db_path "$team")"
  template="$(SKILL_DIR="$SKILL" bash -c '
    . "$SKILL_DIR/scripts/lib/storage.sh"; agmsg_storage_load
    storage_init "$1" >/dev/null
    _sqlite_message_sent_sql "$1" __FROM__ __TO__ __BODY__ __ID__ __AT__' _ "$team")"
  t0="$(epoch)"
  python3 - "$count" "$template" "$BODY_BYTES" > "$WORK/seed.sql" <<'PY'
import sys, uuid, hashlib
from datetime import datetime, timedelta, timezone
count, template, body_bytes = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
epoch = datetime(2026, 1, 1, tzinfo=timezone.utc)
filler = "lorem ipsum dolor sit amet "
print("PRAGMA synchronous=OFF;")
for i in range(count):
    at = (epoch + timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%SZ")
    # UUIDv7-shaped, time-ordered, deterministic: ms since epoch then digest.
    ms = int((epoch + timedelta(seconds=i)).timestamp() * 1000)
    tail = hashlib.sha256(f"seed:{i}".encode()).hexdigest()
    raw = f"{ms:012x}7{tail[:3]}{'8'}{tail[3:6]}{tail[6:18]}"
    ident = str(uuid.UUID(raw))
    body = (f"synthetic local message {i+1} " + filler * (body_bytes // len(filler) + 1))[:body_bytes]
    sql = template
    for token, value in (("__FROM__", "alice" if i % 2 == 0 else "bob"),
                         ("__TO__", "bob" if i % 2 == 0 else "alice"),
                         ("__BODY__", body.replace("'", "''")),
                         ("__ID__", ident), ("__AT__", at)):
        sql = sql.replace(token, value)
    sys.stdout.write(sql)
PY
  sqlite3 -bail "$db" < "$WORK/seed.sql"
  t1="$(epoch)"
  seconds="$(python3 -c 'import sys;print(round(float(sys.argv[2])-float(sys.argv[1]),3))' "$t0" "$t1")"
  # Verified through the product's reader, not assumed from the INSERT count.
  local seen
  seen="$(SKILL_DIR="$SKILL" bash -c '. "$SKILL_DIR/scripts/lib/storage.sh"; agmsg_storage_load; storage_history "$1" --limit 1' _ "$team" | wc -l | tr -d ' ')"
  [ "$seen" -ge 1 ] || { echo "join-harness: seeded $count rows but storage_history reads nothing back" >&2; exit 1; }
  local rows
  rows="$(sqlite3 "$db" "SELECT count(*) FROM events WHERE type='message_sent' AND team='$team';")"
  [ "$rows" = "$count" ] || { echo "join-harness: seeded $count rows but the store holds $rows" >&2; exit 1; }
  note_event harness.seed "\"count\":$count,\"seconds\":$seconds"
  echo "join-harness:   seeded $count local messages in ${seconds}s"
}

run_push() {
  local team=perf size="$1"
  start_mock "$WORK/history.jsonl"   # served history is irrelevant here; the mock also takes pushes
  bash "$SKILL/scripts/join.sh" "$team" alice claude-code "$WORK/project" >/dev/null
  bash "$SKILL/scripts/join.sh" "$team" bob claude-code "$WORK/project" >/dev/null
  mark seed
  seed_local "$team" "$size"

  # connect registers the team and starts the engine; the engine's catch-up
  # cycles are the push: prepare -> POST -> reconcile, then the pull side
  # brings every pushed message straight back (the echo-back #908 observed).
  mark connect
  run_command connect bash "$SKILL/scripts/remote.sh" connect --endpoint "$ENDPOINT" "$team"
  mark engine
  local t0 elapsed=0 drained=0
  t0="$(epoch)"
  echo "join-harness:   waiting for the engine to drain (a push.prepared with count 0 after pushing)"
  while :; do
    set +e
    python3 - "$EVENTS" <<'PY'
import json, sys
# Only the window after the `engine` marker counts; drained means a cycle that
# prepared nothing after at least one cycle that prepared something.
in_engine, pushed = False, False
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line: continue
    e = json.loads(line)
    if e.get("event") == "harness.phase":
        in_engine = e.get("phase") == "engine"
        continue
    if not in_engine: continue
    if e.get("event") == "cycle.error": sys.exit(3)
    if e.get("event") == "push.prepared":
        if e.get("count", 0) > 0: pushed = True
        elif pushed: sys.exit(0)
sys.exit(1)
PY
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then drained=1; break; fi
    if [ "$rc" -eq 3 ]; then
      echo "join-harness: the engine reported cycle.error; see $EVENTS (the report will say so)" >&2
      break
    fi
    elapsed="$(python3 -c 'import sys,time;print(int(time.time()-float(sys.argv[1])))' "$t0")"
    if [ "$TIMEOUT" -gt 0 ] && [ "$elapsed" -ge "$TIMEOUT" ]; then
      note_event harness.timeout "\"after_seconds\":$elapsed"
      echo "join-harness: engine did not drain within ${TIMEOUT}s (that is a finding, not a harness fault)" >&2
      break
    fi
    if [ $((elapsed % 60)) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
      echo "join-harness:   [${elapsed}s] still pushing: $(grep -c '"event":"push.prepared"' "$EVENTS") cycles so far"
      sleep 1
    fi
    sleep 1
  done
  # The drained cycle still has its pull and read-state to finish; let it.
  wait_engine_asleep "$team" "$(now_iso)" 600 || true
  stop_engine "$team"
  [ "$drained" -eq 1 ] && echo "join-harness:   drained after ${elapsed}s"

  mark once
  run_command once bash "$SKILL/scripts/remote-sync.sh" once --team "$team"
  mark reprocess
  run_command reprocess bash "$SKILL/scripts/remote-sync.sh" reprocess --team "$team"
  record_state "$team"
}

# The path #910's 4,100 unreadable rows took, end to end (#916): a second
# private install ("machine A") holds the team's age key; the history is sealed
# to that key through the product's own helper; machine B pulls it with no key
# (every message quarantined, engine halted), then unlocks with the handed
# bundle -- and `unlock` runs the reprocess that re-evaluates every quarantined
# row. That reprocess, over N rows, is the stage nothing else here exercises.
run_unlock() {
  local team=perf size="$1"
  local skill_a="$WORK/skill-a" cfg_a key_id recipient team_id digest
  mkdir -p "$skill_a" "$WORK/home-a"
  cp -R "$REPO/scripts/." "$skill_a/scripts/"
  chmod +x "$skill_a/scripts/"*.sh "$skill_a/scripts/internal/"*.sh "$skill_a/scripts/drivers/storage/"*.sh 2>/dev/null || true
  cfg_a="$skill_a/teams/$team/config.json"
  # Machine A's commands run under A's own store, HOME and event log, in a
  # subshell so none of it leaks into machine B's environment (run_one's).
  a() {
    ( export HOME="$WORK/home-a" AGMSG_STORAGE_PATH="$skill_a/db" AGMSG_SYNC_LOG_FILE="$WORK/events-a.jsonl"
      unset SKILL_DIR AGMSG_SYNC_CONNECTION_DIR AGMSG_SYNC_TRUST_DIR 2>/dev/null || true
      "$@" )
  }
  a bash "$skill_a/scripts/internal/init-db.sh" >/dev/null
  a bash "$skill_a/scripts/join.sh" "$team" member-1 claude-code "$WORK/project" >/dev/null
  a bash "$skill_a/scripts/join.sh" "$team" member-2 claude-code "$WORK/project" >/dev/null
  start_mock ""
  # connect --e2ee mints the key; disconnect stops the engine it started. Both
  # are the product's own, and the key material is everything A is for.
  a bash "$skill_a/scripts/remote.sh" connect --endpoint "$ENDPOINT" --e2ee "$team" > "$WORK/connect-a.out" 2> "$WORK/connect-a.err" \
    || { echo "join-harness: machine A could not connect --e2ee; stderr:" >&2; tail -n 20 "$WORK/connect-a.err" >&2; exit 1; }
  a bash "$skill_a/scripts/key.sh" show "$team" --snapshot --out "$WORK/snapshot.json" >/dev/null 2>&1 \
    || { echo "join-harness: key.sh show --snapshot failed" >&2; exit 1; }
  a bash "$skill_a/scripts/key.sh" handoff "$team" --out "$WORK/bundle.json" >/dev/null 2>&1 \
    || { echo "join-harness: key.sh handoff failed" >&2; exit 1; }
  a bash "$skill_a/scripts/remote.sh" disconnect "$team" >/dev/null 2>&1 || true
  key_id="$(jq -r '.remote_key.current.key_id' "$cfg_a")"
  recipient="$(jq -r '.remote_key.current.recipient' "$cfg_a")"
  team_id="$(jq -r '.team_id' "$cfg_a")"
  digest="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$WORK/snapshot.json")"
  [ -n "$key_id" ] && [ "$key_id" != null ] && [ -n "$recipient" ] && [ "$recipient" != null ] \
    || { echo "join-harness: machine A has no current key after connect --e2ee" >&2; exit 1; }
  echo "join-harness:   machine A holds key $key_id for team $team_id"

  # The history, sealed to A's key through the product's own seal-batch.
  python3 "$HERE/gen-history.py" --messages "$size" --roster "$ROSTER" --body-bytes "$BODY_BYTES" \
    --cipher age-v1 --cipher-helper "$skill_a/scripts/internal/sync-cipher.mjs" --node "$(command -v node)" \
    --key-id "$key_id" --recipient "$recipient" --team-id "$team_id" --plain-before "$PRELOADED" \
    --out "$WORK/history.jsonl"
  # Served as A's team, declared age-v1: the pull side then has the team id and
  # the declaration a real second machine would see.
  kill "$MOCK_PID" 2>/dev/null || true
  start_mock "$WORK/history.jsonl" "$team_id" age-v1

  # Machine B (run_one's environment): pull without the key. Every message is
  # quarantined (unsupported_cipher: age-v1 is not configured) and the engine
  # is not started -- the state #910 reports.
  mark pull
  local rc=0 pull_started
  pull_started="$(now_iso)"
  set +e
  bash "$SKILL/scripts/remote.sh" pull --endpoint "$ENDPOINT" --team-id "$team_id" "$team" \
    2>&1 1> "$WORK/pull.out" | python3 "$HERE/report.py" ts > "$WORK/pull.stderr.ts"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "join-harness: remote.sh pull failed (exit $rc); stderr:" >&2
    tail -n 30 "$WORK/pull.stderr.ts" >&2
    exit 1
  fi
  sed 's/^/join-harness:   pull: /' "$WORK/pull.out"
  grep -q 'locked' "$WORK/pull.out" || { echo "join-harness: expected the pulled team to be locked (no key on machine B)" >&2; exit 1; }

  # The unlock: confirms the handed authority, imports the identity, runs the
  # reprocess over every quarantined row, then starts the engine. The reprocess
  # is the measurement; the engine is stopped once it has finished a cycle.
  mark unlock
  local unlock_started
  unlock_started="$(now_iso)"
  run_command unlock bash "$SKILL/scripts/remote.sh" unlock "$team" --bundle "$WORK/bundle.json" --confirm-digest "$digest"
  sed 's/^/join-harness:   unlock: /' "$WORK/unlock.out" | head -n 3
  wait_engine_asleep "$team" "$unlock_started" 600 || true
  stop_engine "$team"

  mark once
  run_command once bash "$SKILL/scripts/remote-sync.sh" once --team "$team"
  mark reprocess
  run_command reprocess bash "$SKILL/scripts/remote-sync.sh" reprocess --team "$team"
  record_state "$team"
}

# --- main ---------------------------------------------------------------------

RUN_STATUS=0
SUMMARIES=()
IFS=',' read -r -a SIZE_LIST <<< "$SIZES"
for size in "${SIZE_LIST[@]}"; do
  case "$size" in ''|*[!0-9]*) echo "join-harness: bad size '$size'" >&2; exit 2 ;; esac
  run_one "$size"
  SUMMARIES+=("$WORK/summary.json")
  # Stop this run's mock before the next run starts its own.
  kill "$MOCK_PID" 2>/dev/null || true
done
if [ "${#SUMMARIES[@]}" -gt 1 ]; then
  python3 "$HERE/report.py" compare --project "$PROJECT" "${SUMMARIES[@]}" || RUN_STATUS=$?
fi
if [ "$KEEP" -eq 1 ]; then
  echo "join-harness: kept under $OUT (summary.json per run; events.jsonl is the raw log)"
fi
exit "$RUN_STATUS"
