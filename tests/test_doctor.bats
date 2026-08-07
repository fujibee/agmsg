#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export PROJ="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
  rm -rf "$PROJ"
}

# --- usage-error contract (exit 2), separate from the "found a problem"
#     contract (exit 1) above -- these used to collapse into bash's own
#     ${1:?...} exit 1 on a missing argument, which is indistinguishable
#     from a warning to anything scripting against the exit code. ----------

@test "doctor: no arguments is a usage error (exit 2), not bash's own exit 1" {
  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: doctor.sh"* ]]
}

@test "doctor: a missing type argument is a usage error (exit 2)" {
  run bash "$SCRIPTS/doctor.sh" "$PROJ"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: doctor.sh"* ]]
}

@test "doctor: bare --help exits 0 and prints usage, even with no other arguments" {
  # ${1:?...} alone would consume "--help" as PROJECT, then die on the
  # missing TYPE with status 1 and never reach a help branch.
  run bash "$SCRIPTS/doctor.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: doctor.sh"* ]]
}

@test "doctor: an unknown option is a usage error (exit 2)" {
  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code --nonsense
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "doctor: an unknown agent type is a usage error (exit 2), not a silent clean report" {
  run bash "$SCRIPTS/doctor.sh" "$PROJ" not-a-real-type
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown agent type"* ]]
  # Must not fall through to delivery.sh/identities.sh and report clean.
  [[ "$output" != *"no warnings."* ]]
}

@test "doctor: exits 0 and reports no warnings when nothing is registered as locked" {
  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"no warnings."* ]]
  [[ "$output" == *"team/alice"* ]]
  [[ "$output" == *"lock=none"* ]]
}

@test "doctor: exits non-zero and names a stale lock (composite owner, dead pid, no cc-instance)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale lock: team/alice"* ]]
  [[ "$output" == *"cc-instance=absent"* ]]
}

@test "doctor: a live lock with a confirming cc-instance record and a running watcher is not a warning" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  # watch.sh's pidfile is keyed on the same token actas-claim.sh records as
  # the lock owner -- see doctor.sh's comment on TYPE_HAS_ROLE_RUNTIME.
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/watch.$owner.pid"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  # Plain output shows the owner token in FULL -- shortening only applies
  # under --redacted (see doctor.sh's comment on _redact_owner: #605 was
  # resolved by matching this exact value against a bridge log line).
  [[ "$output" == *"lock=owner(alive)=$owner cc-instance=present watcher=running"* ]]
  [[ "$output" == *"no warnings."* ]]
}

@test "doctor: an alive lock with no watcher pidfile is a warning (claims exclusivity, not receiving)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  # No watch.<owner>.pid: the lock is legitimately live, but nothing is
  # watching for it -- exclusivity claimed, nothing receiving. #605's report
  # was exactly this shape.

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"lock=owner(alive)=$owner cc-instance=present watcher=none"* ]]
  [[ "$output" == *"actas lock held but no watcher: team/alice"* ]]
}

@test "doctor: a stale lock with no watcher does not double-warn about the missing watcher" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale lock: team/alice"* ]]
  [[ "$output" != *"actas lock held but no watcher"* ]]
}

@test "doctor: codex's per-role bridge line already covers this, so no separate watcher= field is added" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "livetoken.$$" > "$TEST_SKILL_DIR/run/actas.team__bob.session"

  run bash "$SCRIPTS/doctor.sh" "$PROJ" codex
  [[ "$output" != *"watcher="* ]]
}

@test "doctor: --redacted hides the project path, team/agent names, and most of the owner token" {
  local home_proj="$HOME/redact-me"
  mkdir -p "$home_proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$home_proj" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" "$home_proj" claude-code --redacted
  [ "$status" -eq 1 ]
  [[ "$output" == *"project: ~/redact-me"* ]]
  [[ "$output" != *"team/alice"* ]]
  [[ "$output" == *"team1/agent1"* ]]
  [[ "$output" == *"...999999"* ]]
  [[ "$output" != *"deadtoken.999999"* ]]
}

@test "doctor: --redacted also masks a project path outside \$HOME (a shared worktree, /Volumes, etc.), including in the embedded block" {
  # $PROJ (from setup(), a plain mktemp -d) is already outside the sandboxed
  # $HOME test_helper.bash sets up -- no extra fixture needed to get a
  # non-HOME path here, which is exactly the case that leaked before: only
  # the $HOME-relative path was masked, so a project anywhere else (a shared
  # worktree, /Volumes/..., /Users/Shared/...) passed through raw, in both
  # doctor's own "project:" line and the embedded delivery.sh block (whose
  # "settings hooks file:" line names the project directly).
  case "$PROJ" in
    "$HOME"*) skip "fixture \$PROJ landed under \$HOME this run; this test needs it outside" ;;
  esac

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code --redacted
  [[ "$output" == *"project: <project>"* ]]
  [[ "$output" != *"$PROJ"* ]]
}

@test "doctor: owner is shown in full by default, and --redacted splits a composite token on its last dot (not a fixed tail length)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  # A pid genuinely dead by construction (spawn, wait, then use its now-freed
  # pid) rather than a hardcoded small number: a fixed guess like "42" can
  # collide with a real process on a container CI runner, where low pids are
  # far more likely to be in active use than on a real developer machine --
  # the same class of flake #595's marker-gc investigation found in a
  # hardcoded pid 4242. Whatever pid the OS actually hands back also isn't
  # guaranteed to be 6 digits, which is what this test needs: a fixed-tail
  # shortener would cut into the sid (e.g. "...02.42") on a short one, while
  # splitting on the last "." always lands exactly on the pid regardless of
  # its length.
  ( exit 0 ) & local deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  local owner="459d8198-3fcf-4c9e-a4ff-5f8fbd18c802.$deadpid"

  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [[ "$output" == *"lock=owner(STALE)=$owner"* ]]

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code --redacted
  [[ "$output" == *"lock=owner(STALE)=...$deadpid "* ]]
  [[ "$output" != *"$owner"* ]]
}

@test "doctor: warns when more than one registration exists under turn-mode delivery" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"registrations for this (project, type) under turn-mode delivery"* ]]
}

@test "doctor: multiple registrations under monitor mode is not a warning" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *"under turn-mode delivery"* ]]
}

# --- the delivery-status block is QUOTED from delivery.sh, not formatted by
#     doctor.sh itself -- --redacted has to run it through the same
#     substitutions or its only promise ("safe to paste") is broken. codex's
#     per-role bridge line is real-world proof: it names team/agent directly. -
@test "doctor: --redacted also redacts the embedded delivery-status block, not just its own formatting" {
  local home_proj="$HOME/embedded-leak-check"
  mkdir -p "$home_proj"
  bash "$SCRIPTS/join.sh" agmsg advisor codex "$home_proj" >/dev/null
  # A live codex bridge for agmsg/advisor, minimal enough for
  # _delivery.sh's agmsg_delivery_runtime_status to report it "alive": a
  # pidfile naming a real (this test's own) pid, and a matching metafile.
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.agmsg.advisor.pid"
  {
    echo "pid=$$"
    echo "project=$home_proj"
    echo "type=codex"
  } > "$TEST_SKILL_DIR/run/codex-bridge.agmsg.advisor.meta"

  run bash "$SCRIPTS/doctor.sh" "$home_proj" codex --redacted
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team1/agent1 alive"* ]]
  [[ "$output" != *"agmsg/advisor"* ]]
  [[ "$output" != *"$HOME"* ]]
}
