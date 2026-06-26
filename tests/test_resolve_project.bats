#!/usr/bin/env bats

# Tests for #92 project resolution: a slash command issued from a subdir or
# git worktree must resolve to the registered project the session lives in,
# not mint a phantom record for the subdir.
#
# Coverage:
#   - lib/resolve-project.sh: ancestor walk, marker precedence, opt-out,
#     pwd fallback, type isolation, marker GC, pid-recycling guard
#   - entry scripts (whoami/actas-claim/join) resolving end-to-end from a subdir

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"

  # A real project tree so dirname-based ancestor walking operates on real
  # paths: ROOT/sub/deep.
  export ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/sub/deep"

  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/resolve-project.sh"
}

teardown() {
  rm -rf "$ROOT"
  teardown_test_env
}

# Register (team, agent, project) without resolution, so test fixtures land at
# the exact path we ask for regardless of cwd.
reg() {
  AGMSG_RESOLVE_PROJECT=0 bash "$SKILL_DIR/scripts/join.sh" "$1" "$2" "${4:-claude-code}" "$3"
}

# --- ancestor walk ---

@test "resolve: subdir resolves to the registered ancestor project" {
  reg T alice "$ROOT"
  result="$(agmsg_resolve_project "$ROOT/sub/deep" claude-code)"
  [ "$result" = "$ROOT" ]
}

@test "resolve: registered path itself is returned unchanged" {
  reg T alice "$ROOT"
  result="$(agmsg_resolve_project "$ROOT" claude-code)"
  [ "$result" = "$ROOT" ]
}

# --- pwd fallback ---

@test "resolve: unrelated dir with no registered ancestor falls back to pwd" {
  reg T alice "$ROOT"
  other="$(mktemp -d)"
  result="$(agmsg_resolve_project "$other/x" claude-code)"
  [ "$result" = "$other/x" ]
  rm -rf "$other"
}

# --- type isolation ---

@test "resolve: ancestor of a different type does not match" {
  reg T alice "$ROOT" claude-code
  result="$(agmsg_resolve_project "$ROOT/sub" codex)"
  [ "$result" = "$ROOT/sub" ]   # no codex registration → unchanged
}

# --- opt-out ---

@test "resolve: AGMSG_RESOLVE_PROJECT=0 forces the raw pwd" {
  reg T alice "$ROOT"
  result="$(AGMSG_RESOLVE_PROJECT=0 agmsg_resolve_project "$ROOT/sub/deep" claude-code)"
  [ "$result" = "$ROOT/sub/deep" ]
}

# --- marker precedence (forced via function overrides) ---

@test "resolve: a valid marker wins over the ancestor walk" {
  reg T alice "$ROOT"
  local markroot="$(mktemp -d)"
  # Force a marker lookup that succeeds for a synthetic pid.
  agmsg_agent_pid() { printf '%s' 4242; }
  agmsg_pid_is_agent() { return 0; }
  agmsg_write_project_marker 4242 "$markroot"

  result="$(agmsg_resolve_project "$ROOT/sub/deep" claude-code)"
  [ "$result" = "$markroot" ]
  rm -rf "$markroot"
}

# --- marker GC ---

@test "marker-gc: removes markers for dead pids, keeps live ones" {
  agmsg_write_project_marker 999999 "/some/dead"   # pid 999999 ~ never alive
  agmsg_write_project_marker "$$" "/some/live"     # this bats process is alive
  [ -f "$(agmsg_project_marker_path 999999)" ]
  [ -f "$(agmsg_project_marker_path "$$")" ]

  agmsg_marker_gc_stale

  [ ! -f "$(agmsg_project_marker_path 999999)" ]
  [ -f "$(agmsg_project_marker_path "$$")" ]
}

# --- pid-recycling guard ---

@test "pid-is-agent: a live non-agent process is not trusted" {
  # $$ is bats/bash, not claude/codex — must not be accepted as an agent.
  run agmsg_pid_is_agent "$$" claude-code
  [ "$status" -ne 0 ]
}

@test "read-marker: untrusted pid is not honored even if the file exists" {
  agmsg_write_project_marker "$$" "/should/not/trust"   # $$ is not an agent
  run agmsg_read_project_marker "$$" claude-code
  [ "$status" -ne 0 ]
}

# --- end-to-end through entry scripts ---

@test "whoami: subdir invocation resolves to the registered identity" {
  reg T alice "$ROOT"
  run bash "$SKILL_DIR/scripts/whoami.sh" "$ROOT/sub/deep" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "project=$ROOT" ]]
}

@test "actas-claim: subdir invocation claims against the registered project" {
  reg T alice "$ROOT"
  echo "sid-me" > "$RUN_DIR/cc-instance.$$"   # make sid-me look alive

  run bash "$SKILL_DIR/scripts/actas-claim.sh" "$ROOT/sub/deep" claude-code alice "sid-me"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=ok" ]]
  [[ "$output" =~ "team=T" ]]
}

@test "join: agent-driven subdir join registers under the resolved project" {
  reg T alice "$ROOT"
  bash "$SKILL_DIR/scripts/join.sh" T bob claude-code "$ROOT/sub"   # resolution ON

  # bob lands on ROOT, not ROOT/sub.
  run bash "$SKILL_DIR/scripts/identities.sh" "$ROOT" claude-code
  [[ "$output" =~ "bob" ]]
  run bash "$SKILL_DIR/scripts/identities.sh" "$ROOT/sub" claude-code
  [[ ! "$output" =~ "bob" ]]
}

@test "join: explicit opt-out registers the exact path (spawn path)" {
  reg T alice "$ROOT"
  AGMSG_RESOLVE_PROJECT=0 bash "$SKILL_DIR/scripts/join.sh" T carol claude-code "$ROOT/sub"

  run bash "$SKILL_DIR/scripts/identities.sh" "$ROOT/sub" claude-code
  [[ "$output" =~ "carol" ]]
}

# --- watch.sh: actas/drop watcher must not die from a subdir (the High bug) ---

@test "watch: actas watcher from a subdir does not exit with no-registration" {
  reg T alice "$ROOT"
  # Launch the actas watcher (ACTIVE_NAME=alice) from a subdir; without
  # resolution it would see no registration and exit immediately.
  bash "$SKILL_DIR/scripts/watch.sh" sid-w "$ROOT/sub/deep" claude-code alice \
    >"$BATS_TEST_TMPDIR/w.out" 2>&1 &
  local wpid=$!
  sleep 1
  # A resolving watcher is still alive in its poll loop; an unresolved one has
  # already exited.
  local alive=0
  kill -0 "$wpid" 2>/dev/null && alive=1
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  [ "$alive" -eq 1 ]
  run cat "$BATS_TEST_TMPDIR/w.out"
  [[ ! "$output" =~ "no registration" ]]
}

# --- git common-dir: sibling worktree recovery, and no-misfire guard ---

setup_git_repo() {
  # Echo a realpath'd base dir so git's symlink-resolved paths match what we
  # register (mktemp on macOS lives under a /var -> /private symlink).
  local base; base="$(cd "$(mktemp -d)" && pwd -P)"
  printf '%s' "$base"
}

@test "resolve: sibling git worktree resolves to the registered main checkout" {
  skip_on_windows "git worktree path normalization under Git Bash (#182)"
  command -v git >/dev/null 2>&1 || skip "git not available"
  local base; base="$(setup_git_repo)"
  local repo="$base/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" worktree add -q "$base/repo-wt" >/dev/null 2>&1

  reg T alice "$repo"   # registration on the main checkout

  # repo-wt is a sibling of repo (not nested), so the ancestor walk misses and
  # git-common-dir must recover the main checkout.
  result="$(agmsg_resolve_project "$base/repo-wt" claude-code)"
  [ "$result" = "$repo" ]
  rm -rf "$base"
}

@test "resolve: nested worktree under a registered parent uses ancestor, not git-common-dir" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  local base; base="$(setup_git_repo)"
  mkdir -p "$base/parent/repo"
  git -C "$base/parent/repo" init -q
  git -C "$base/parent/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$base/parent/repo" worktree add -q "$base/parent/repo-wt" >/dev/null 2>&1

  reg T alice "$base/parent"   # registration on the umbrella parent dir

  # The git checkout ($base/parent/repo) is NOT registered, so git-common-dir
  # must decline and the ancestor walk must win with the parent.
  result="$(agmsg_resolve_project "$base/parent/repo-wt" claude-code)"
  [ "$result" = "$base/parent" ]
  rm -rf "$base"
}
