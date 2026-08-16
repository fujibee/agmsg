#!/usr/bin/env bats

# Unit tests for codex session resume wiring (#339):
#   scripts/drivers/types/codex/_transcript-exists.sh
#   scripts/drivers/types/codex/codex-record-session.sh
# Codex resumes via `codex resume <SESSION_ID>` (subcommand) and, unlike
# claude-code, records its role->session at actas time (it never runs actas-claim).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export CODEX_SESSIONS="$HOME/.codex/sessions"
}

teardown() { teardown_test_env; }

# Write a codex rollout file with a session_meta first line carrying id + cwd.
make_rollout() {
  local uuid="$1" cwd="$2" day="${3:-2026/07/05}" ts="${4:-2026-07-05T10-00-00}"
  local dir="$CODEX_SESSIONS/$day"
  mkdir -p "$dir"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$uuid" "$cwd" \
    > "$dir/rollout-$ts-$uuid.jsonl"
}

# --- _transcript-exists.sh ---

@test "codex transcript_exists: true when a rollout with the uuid exists" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "abc-uuid" "/proj"
  agmsg_transcript_exists "abc-uuid" "/proj"
}

@test "codex transcript_exists: false when no rollout carries the uuid" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "other-uuid" "/proj"
  ! agmsg_transcript_exists "abc-uuid" "/proj"
}

@test "codex transcript_exists: finds the rollout regardless of the date dir" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "deep-uuid" "/proj" "2026/06/01" "2026-06-01T09-09-09"
  agmsg_transcript_exists "deep-uuid" "/anything"   # project is not part of the lookup
}

@test "codex transcript_exists: empty uuid / unset HOME are not found" {
  # shellcheck disable=SC1090
  source "$TYPES/codex/_transcript-exists.sh"
  make_rollout "abc-uuid" "/proj"
  refute agmsg_transcript_exists "" "/proj"
  HOME="" run agmsg_transcript_exists "abc-uuid" "/proj"
  [ "$status" -ne 0 ]
}

# --- codex-record-session.sh ---

# Read back the recorded uuid for (team, agent).
recorded_uuid() {
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_uuid "$1" "$2"
}

@test "codex record: prefers CODEX_THREAD_ID (unambiguous env path)" {
  local proj; proj="$(mktemp -d)"
  CODEX_THREAD_ID="env-thread-1" \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "env-thread-1" ]
  # type is recorded as codex.
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  [ "$(agmsg_role_session_get team alice type)" = "codex" ]
}

@test "codex record: falls back to the unique matching-cwd rollout when env is unset" {
  local proj; proj="$(mktemp -d)"
  make_rollout "fallback-uuid" "$proj"
  ( unset CODEX_THREAD_ID; bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ "$(recorded_uuid team alice)" = "fallback-uuid" ]
}

@test "codex record: records NOTHING when two recent rollouts share the cwd (ambiguous)" {
  local proj; proj="$(mktemp -d)"
  make_rollout "uuid-A" "$proj" "2026/07/05" "2026-07-05T10-00-00"
  make_rollout "uuid-B" "$proj" "2026/07/05" "2026-07-05T11-00-00"
  ( unset CODEX_THREAD_ID; bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: records nothing when no rollout matches the cwd" {
  local proj; proj="$(mktemp -d)"
  make_rollout "elsewhere-uuid" "/some/other/cwd"
  ( unset CODEX_THREAD_ID; bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: zero matches are silent (grep -c prints 0 AND exits 1)" {
  local proj; proj="$(mktemp -d)"
  make_rollout "elsewhere-uuid" "/some/other/cwd"
  run env -u CODEX_THREAD_ID bash "$TYPES/codex/codex-record-session.sh" team alice "$proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # a two-line count would print "[: integer expected" here
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: missing args are a no-op" {
  run bash "$TYPES/codex/codex-record-session.sh" team "" /proj
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

# Read back the recorded project for (team, agent).
recorded_project() {
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_get "$1" "$2" project
}

@test "codex record: project arg is optional -- defaults to \$PWD, canonical form" {
  local proj want; proj="$(mktemp -d)"
  want="$(cd "$proj" && pwd -P)"
  ( cd "$proj" && CODEX_THREAD_ID="pwd-thread-1" \
      bash "$TYPES/codex/codex-record-session.sh" team alice )
  [ "$(recorded_uuid team alice)" = "pwd-thread-1" ]
  [ "$(recorded_project team alice)" = "$want" ]
}

@test "codex record: no project arg + no env still finds the rollout via \$PWD" {
  local proj; proj="$(mktemp -d)"
  make_rollout "pwd-fallback-uuid" "$proj"
  ( unset CODEX_THREAD_ID; cd "$proj" && \
      bash "$TYPES/codex/codex-record-session.sh" team alice )
  [ "$(recorded_uuid team alice)" = "pwd-fallback-uuid" ]
}

# The lone `\` a PowerShell-parsed \"$PWD\" collapses to (see the script
# header). On MSYS it IS a real directory that canonicalizes to a drive root;
# on POSIX it fails the -d check. Either way: no record.
@test "codex record: backslash project (PowerShell quoting damage) records nothing" {
  CODEX_THREAD_ID="poison-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice '\'
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: filesystem-root project records nothing" {
  CODEX_THREAD_ID="root-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice /
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: drive-root project records nothing" {
  # /c exists on MSYS (caught by the root check); on POSIX it usually doesn't
  # (caught by -d). Both paths must end in "no record".
  CODEX_THREAD_ID="drive-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice /c
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: nonexistent project records nothing" {
  CODEX_THREAD_ID="ghost-thread" \
    run bash "$TYPES/codex/codex-record-session.sh" team alice /no/such/dir
  [ "$status" -eq 0 ]
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: symlinked project is recorded in canonical (physical) form" {
  local real link want; real="$(mktemp -d)"
  link="$HOME/proj-link"
  ln -s "$real" "$link" 2>/dev/null || skip "symlinks unavailable"
  [ -L "$link" ] || skip "ln -s fell back to copy (MSYS default)"
  want="$(cd "$real" && pwd -P)"
  CODEX_THREAD_ID="sym-thread" \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$link"
  [ "$(recorded_uuid team alice)" = "sym-thread" ]
  [ "$(recorded_project team alice)" = "$want" ]
}

# --- codex-record-session.sh: seat from the app-server's loaded set (#579) ---
#
# The rollout scan cannot answer "which thread is THIS session" on a project that
# has been worked in before -- every past session in that cwd matches, so the
# count is never one and the seat is never written. These cover the replacement:
# ask the app-server what it has loaded, subtract the threads a role already sits
# in, and take the remainder only when it is unique.

# A stand-in for node that ignores the bridge path and its flags and prints the
# ids the test staged. agmsg_resolve_node honours AGMSG_NODE, so this is the seam
# the production call already goes through -- no test-only branch in the script.
fake_node_printing() {
  local out="$TEST_SKILL_DIR/fake-node"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat %q\n' "$1"
  } > "$out"
  chmod +x "$out"
  printf '%s' "$out"
}

record_with_loaded() {   # <ids-file> <team> <agent> <project>
  ( unset CODEX_THREAD_ID
    AGMSG_NODE="$(fake_node_printing "$1")" \
    AGMSG_CODEX_BRIDGE_APP_SERVER="ws://127.0.0.1:1" \
      bash "$TYPES/codex/codex-record-session.sh" "$2" "$3" "$4" )
}

@test "codex record: seats the loaded thread that no role has claimed yet" {
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-seated\nthr-unclaimed\n' > "$ids"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team bob thr-seated "$proj" codex
  record_with_loaded "$ids" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "thr-unclaimed" ]
}

@test "codex record: a long history in the cwd no longer blocks the seat" {
  # The exact shape of #579: many past sessions in this project. Under the rollout
  # scan this is the ambiguous case that records nothing forever; the loaded set
  # is unaffected by how much history the project has.
  local proj ids i; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  for i in 1 2 3 4 5; do
    make_rollout "hist-uuid-$i" "$proj" "2026/07/05" "2026-07-05T1$i-00-00"
  done
  printf 'thr-live\n' > "$ids"
  record_with_loaded "$ids" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "thr-live" ]
}

@test "codex record: two unclaimed loaded threads record nothing (stays fail-closed)" {
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-one\nthr-two\n' > "$ids"
  record_with_loaded "$ids" team alice "$proj"
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: every loaded thread already claimed records nothing" {
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-a\nthr-b\n' > "$ids"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team bob thr-a "$proj" codex
  agmsg_role_session_record team carol thr-b "$proj" codex
  record_with_loaded "$ids" team alice "$proj"
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: a claimed thread of another TYPE is not subtracted" {
  # claude-code records session ids in the same directory. Subtracting those
  # would silently shrink the codex candidate set and could make an ambiguous
  # pair look unique -- the one way this subtraction could seat a wrong thread.
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-x\nthr-y\n' > "$ids"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team bob thr-x "$proj" claude-code
  record_with_loaded "$ids" team alice "$proj"
  [ -z "$(recorded_uuid team alice)" ]
}

# A stand-in for node that FAILS, i.e. the app-server could not be reached at all.
# Distinct from a probe that answers with an empty or ambiguous list: only this
# case may fall through to the rollout scan.
fake_node_failing() {
  local out="$TEST_SKILL_DIR/fake-node-fail"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$out"
  chmod +x "$out"
  printf '%s' "$out"
}

@test "codex record: an ambiguous probe is NOT overruled by a unique rollout" {
  # The rollout scan is the weaker source. Once the app-server has said it cannot
  # tell this session apart, a rollout that happens to be unique must not seat a
  # thread on top of that answer.
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-one\nthr-two\n' > "$ids"
  make_rollout "rollout-unique-uuid" "$proj"
  record_with_loaded "$ids" team alice "$proj"
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: an empty probe is NOT overruled by a unique rollout" {
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  : > "$ids"
  make_rollout "rollout-unique-uuid" "$proj"
  record_with_loaded "$ids" team alice "$proj"
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: an unreachable app-server DOES fall back to the rollout scan" {
  local proj; proj="$(mktemp -d)"
  make_rollout "rollout-unique-uuid" "$proj"
  ( unset CODEX_THREAD_ID
    AGMSG_NODE="$(fake_node_failing)" \
    AGMSG_CODEX_BRIDGE_APP_SERVER="ws://127.0.0.1:1" \
      bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ "$(recorded_uuid team alice)" = "rollout-unique-uuid" ]
}

@test "codex record: a role that already has a seat is never re-seated by inference" {
  # The subtraction removes this role's own thread along with everyone else's, so
  # a seated role running the inference again would find its own gone and adopt
  # whatever was left -- replacing a correct seat with a stranger's thread.
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thread-A\nthread-B\n' > "$ids"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team alice thread-A "$proj" codex
  record_with_loaded "$ids" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "thread-A" ]
}

@test "codex record: an unseated role still gets the remainder while a seated one keeps its own" {
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thread-A\nthread-B\n' > "$ids"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team alice thread-A "$proj" codex
  record_with_loaded "$ids" team bob "$proj"
  [ "$(recorded_uuid team bob)" = "thread-B" ]
  [ "$(recorded_uuid team alice)" = "thread-A" ]
}

@test "codex record: CODEX_THREAD_ID still re-seats a seated role (bridge write-back)" {
  # The guard above is for INFERENCE only. The bridge rewrites the seat after
  # arming with a thread the app-server confirmed, which must still land.
  local proj; proj="$(mktemp -d)"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team alice guessed-thread "$proj" codex
  CODEX_THREAD_ID="confirmed-thread" \
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "confirmed-thread" ]
}

@test "codex record: the rollout scan does not re-seat a seated role either" {
  # The guard belongs to the whole inference, not to the app-server branch. With
  # no app-server the rollout scan is the inference, and a unique rollout must not
  # replace a seat that is already there.
  local proj; proj="$(mktemp -d)"
  make_rollout "rollout-unique-uuid" "$proj"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team alice thread-A "$proj" codex
  ( unset CODEX_THREAD_ID AGMSG_CODEX_BRIDGE_APP_SERVER
    bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ "$(recorded_uuid team alice)" = "thread-A" ]
}

# --- seating without the app-server environment variable (#583 follow-up) ---
#
# The variable does not arrive on the path #579 is about. Under codex 0.146
# `--remote` this script runs inside the app-server process, and codex-monitor.sh
# cannot export into that context: the URL does not exist until the server's
# banner has been parsed, which is after the server is running. The port file
# carries the same string, so seating has to work from it alone.

record_with_loaded_via_port_file() {   # <ids-file> <team> <agent> <project>
  local hash
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/hash.sh"
  hash="$(printf '%s' "$4" | agmsg_sha1)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '1' > "$TEST_SKILL_DIR/run/codex-app-server.$hash.port"
  ( unset CODEX_THREAD_ID AGMSG_CODEX_BRIDGE_APP_SERVER
    AGMSG_NODE="$(fake_node_printing "$1")" \
      bash "$TYPES/codex/codex-record-session.sh" "$2" "$3" "$4" )
}

@test "codex record: seats from the port file when the app-server variable never arrives" {
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-seated\nthr-unclaimed\n' > "$ids"
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team bob thr-seated "$proj" codex
  record_with_loaded_via_port_file "$ids" team alice "$proj"
  [ "$(recorded_uuid team alice)" = "thr-unclaimed" ]
}

@test "codex record: no port file and no variable records nothing, it does not guess" {
  # Fail closed. Without a way to ask, the answer is "could not ask" -- never
  # "asked and found nothing" -- so no weaker signal may seat a thread here.
  local proj ids; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-unclaimed\n' > "$ids"
  ( unset CODEX_THREAD_ID AGMSG_CODEX_BRIDGE_APP_SERVER
    AGMSG_NODE="$(fake_node_printing "$ids")" \
      bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: a half-written port file is not turned into a URL" {
  local proj ids hash; proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-unclaimed\n' > "$ids"
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/hash.sh"
  hash="$(printf '%s' "$proj" | agmsg_sha1)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'not-a-port' > "$TEST_SKILL_DIR/run/codex-app-server.$hash.port"
  ( unset CODEX_THREAD_ID AGMSG_CODEX_BRIDGE_APP_SERVER
    AGMSG_NODE="$(fake_node_printing "$ids")" \
      bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ -z "$(recorded_uuid team alice)" ]
}

@test "codex record: a digits-only value outside the port range is not turned into a URL" {
  # Digits alone do not make a port. A prefix of a real port is also all digits,
  # which is why the writer publishes atomically — this bounds what anything
  # else could leave behind.
  local proj ids hash bad
  proj="$(mktemp -d)"; ids="$TEST_SKILL_DIR/loaded.txt"
  printf 'thr-unclaimed\n' > "$ids"
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/hash.sh"
  hash="$(printf '%s' "$proj" | agmsg_sha1)"
  mkdir -p "$TEST_SKILL_DIR/run"
  for bad in 0 65536 999999 00042; do
    printf '%s' "$bad" > "$TEST_SKILL_DIR/run/codex-app-server.$hash.port"
    ( unset CODEX_THREAD_ID AGMSG_CODEX_BRIDGE_APP_SERVER
      AGMSG_NODE="$(fake_node_printing "$ids")" \
        bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
    [ -z "$(recorded_uuid team alice)" ] || { echo "seated from port '$bad'"; false; }
  done
  # …and the boundary values that ARE ports still work.
  printf '65535' > "$TEST_SKILL_DIR/run/codex-app-server.$hash.port"
  ( unset CODEX_THREAD_ID AGMSG_CODEX_BRIDGE_APP_SERVER
    AGMSG_NODE="$(fake_node_printing "$ids")" \
      bash "$TYPES/codex/codex-record-session.sh" team alice "$proj" )
  [ "$(recorded_uuid team alice)" = "thr-unclaimed" ]
}
