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
  # Real gc_stale callers load _agmsg_pid_alive via actas-lock.sh; mirror that so
  # the GC exercises the real liveness path, not its missing-helper guard.
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/instance-id.sh"
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

# --- #357: over-reach of the ancestor walk (poison registrations) ---

# Inject a registration directly into a team's config, bypassing join.sh's guard
# -- this simulates a poison registration left by an older version (join now
# refuses $HOME / root, but old data persists).
poison_reg() {  # <team> <agent> <project> [type]
  local team="$1" agent="$2" proj="$3" type="${4:-claude-code}"
  mkdir -p "$SKILL_DIR/teams/$team"
  cat > "$SKILL_DIR/teams/$team/config.json" <<JSON
{"name":"$team","agents":{"$agent":{"registrations":[{"type":"$type","project":"$proj"}]}}}
JSON
}

@test "resolve: a \$HOME registration never captures resolution (#357 shallow-exclusion)" {
  local home_norm; home_norm="$(agmsg_normalize_project_path "$HOME")"
  mkdir -p "$HOME/agmsg-agents/aglive"
  poison_reg test cc "$home_norm" claude-code       # poison: $HOME registered

  # Sanity: the poison IS in the (all-teams) registry, so this really exercises
  # the exclusion rather than a missing registration.
  agmsg_registered_projects claude-code | grep -Fxq -- "$home_norm"

  # A session deep under $HOME must NOT resolve up to $HOME.
  result="$(agmsg_resolve_project "$HOME/agmsg-agents/aglive" claude-code)"
  [ "$result" = "$(agmsg_normalize_project_path "$HOME/agmsg-agents/aglive")" ]
}

@test "resolve: a / registration never captures resolution (#357)" {
  poison_reg test cc "/" claude-code
  other="$(mktemp -d)"
  result="$(agmsg_resolve_project "$other/x" claude-code)"
  [ "$result" = "$other/x" ]            # falls back to pwd, not "/"
  rm -rf "$other"
}

@test "resolve: a \$HOME/ (trailing slash) registration is still excluded (#357 normalized compare)" {
  local home_norm; home_norm="$(agmsg_normalize_project_path "$HOME")"
  mkdir -p "$HOME/agmsg-agents/aglive"
  poison_reg test cc "$home_norm/" claude-code       # stored WITH a trailing slash

  # The walk generates a trailing-slash candidate too, so this really matches the
  # poison -- the exclusion must still fire because it compares normalized paths.
  result="$(agmsg_resolve_project "$HOME/agmsg-agents/aglive" claude-code)"
  [ "$result" = "$(agmsg_normalize_project_path "$HOME/agmsg-agents/aglive")" ]
}

@test "resolve: a // (doubled-slash root) registration is still excluded (#357)" {
  poison_reg test cc "//" claude-code
  other="$(mktemp -d)"
  result="$(agmsg_resolve_project "$other/x" claude-code)"
  [ "$result" = "$other/x" ]            # // normalizes to / -> excluded
  rm -rf "$other"
}


@test "resolve: team scoping ignores another team's registration (#357)" {
  local home_norm; home_norm="$(agmsg_normalize_project_path "$HOME")"
  mkdir -p "$HOME/agmsg-agents/aglive"
  poison_reg test cc "$home_norm" claude-code       # poison lives in team 'test'

  # Scoped to 'aglive' (no registration there) → the 'test' poison is invisible.
  result="$(agmsg_resolve_project "$HOME/agmsg-agents/aglive" claude-code aglive)"
  [ "$result" = "$(agmsg_normalize_project_path "$HOME/agmsg-agents/aglive")" ]
}

@test "registered_projects: a team scope returns only that team's projects (#357)" {
  reg aglive lead "$ROOT" claude-code
  poison_reg other cc "/some/other/proj" claude-code

  run agmsg_registered_projects claude-code aglive
  [[ "$output" == *"$ROOT"* ]]
  [[ "$output" != *"/some/other/proj"* ]]

  # No team → legacy all-teams scan still sees both (back-compat).
  run agmsg_registered_projects claude-code
  [[ "$output" == *"$ROOT"* ]]
  [[ "$output" == *"/some/other/proj"* ]]
}

@test "join: ALLOWS registering a project at \$HOME (deliberate use case) (#357)" {
  # Starting a project at $HOME is legitimate (both claude and codex run there);
  # #357 protects on the resolution side, not by refusing the registration.
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SKILL_DIR/scripts/join.sh" T alice claude-code "$HOME"
  [ "$status" -eq 0 ]
}

@test "resolve: an exact \$HOME registration still resolves \$HOME for a session AT \$HOME (#357)" {
  # The exclusion stops the ancestor walk from LANDING on $HOME for sessions
  # beneath it, but a session whose pwd IS $HOME still resolves to $HOME -- via
  # the pwd fallback, so "someone who started there works".
  local home_norm; home_norm="$(agmsg_normalize_project_path "$HOME")"
  poison_reg test cc "$home_norm" claude-code
  result="$(agmsg_resolve_project "$HOME" claude-code)"
  [ "$result" = "$home_norm" ]
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

# EPERM-aware GC: under the sandbox `kill -0` on a live pid returns EPERM. Reading
# that as dead would delete a live session's marker; only ESRCH drops it. `kill`
# is stubbed to script each errno string (real EPERM is hard to force).

@test "marker-gc: keeps a marker whose pid is EPERM-live (sandbox)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  agmsg_write_project_marker 4242 "$ROOT"
  kill() { echo "bash: kill: (4242) - Operation not permitted" >&2; return 1; }
  agmsg_marker_gc_stale
  [ -f "$(agmsg_project_marker_path 4242)" ]
}

@test "marker-gc: drops a marker whose pid is ESRCH-dead" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # A pid that is genuinely gone, so the real ps agrees with the stubbed kill
  # (same rationale as test_instance_id.bats's gone_pid helper). The magic
  # number 4242 this used to hardcode is a live process on some CI runners,
  # which made the ps cross-check in _agmsg_pid_alive_local report the marker
  # as still owned by a live agent and skip the GC (#595).
  local gone; gone="$(bash -c 'echo $$')"; wait_for_pid_exit "$gone" || true
  agmsg_write_project_marker "$gone" "$ROOT"
  kill() { echo "bash: kill: ($gone) - No such process" >&2; return 1; }
  agmsg_marker_gc_stale
  [ ! -f "$(agmsg_project_marker_path "$gone")" ]
}

@test "marker-gc: sourcing resolve-project.sh alone provides the liveness helper" {
  # The ancestor walk and the marker GC both decide liveness, and a bare
  # `kill -0` calls a live-but-unsignalable agent dead. Leaving the helper to
  # whoever sourced this file is what let that happen, so it is pulled in here.
  run bash -c '
    export SKILL_DIR="'"$SKILL_DIR"'"
    source "$SKILL_DIR/scripts/lib/resolve-project.sh"
    declare -F _agmsg_pid_alive >/dev/null
  '
  [ "$status" -eq 0 ]
}

@test "marker-gc: skips (keeps marker) when _agmsg_pid_alive is unavailable" {
  # Defense in depth, now that the helper is sourced above: a caller that unsets
  # or shadows it must still not reach `|| rm -f`, where a command-not-found
  # would delete a live agent's marker. Unset it to reach the guard.
  agmsg_write_project_marker 4242 "$ROOT"
  run bash -c '
    export SKILL_DIR="'"$SKILL_DIR"'"
    source "$SKILL_DIR/scripts/lib/resolve-project.sh"
    unset -f _agmsg_pid_alive
    declare -F _agmsg_pid_alive >/dev/null && { echo "helper still defined"; exit 2; }
    agmsg_marker_gc_stale
  '
  [ "$status" -eq 0 ]
  [ -f "$(agmsg_project_marker_path 4242)" ]
}

# --- pid-recycling guard ---

@test "pid-is-agent: a live non-agent process is not trusted" {
  # $$ is bats/bash, not claude/codex — must not be accepted as an agent.
  run agmsg_pid_is_agent "$$" claude-code
  [ "$status" -ne 0 ]
}

# --- Claude Code 2.1.x daemon architecture (#349) ---

@test "pid-is-agent: excludes a 'claude daemon run' process even though argv0 matches" {
  skip_on_windows "process argv faking via exec -a (#349)"
  bash -c 'exec -a "claude daemon run --json-path /tmp/agmsg-test-daemon.json" sleep 5' 3>&- &
  local p=$!
  sleep 0.3
  run agmsg_pid_is_agent "$p" claude-code
  kill "$p" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "pid-is-agent: accepts the real session shape (version-named binary + --bg-spare)" {
  skip_on_windows "process argv faking via exec -a (#349)"
  # --bg-spare appears on the REAL per-session binary too (per #349's report),
  # so it must NOT be an exclusion signal on its own — only "daemon run"
  # identifies the daemon. This is the actual reported shape:
  # ".../claude/versions/2.1.199 --bg-spare ...".
  bash -c 'exec -a "2.1.199 --bg-spare" sleep 5' 3>&- &
  local p=$!
  sleep 0.3
  run agmsg_pid_is_agent "$p" claude-code
  kill "$p" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "pid-is-agent: accepts a version-named claude-code session binary" {
  skip_on_windows "process argv faking via exec -a (#349)"
  bash -c 'exec -a "2.1.199" sleep 5' 3>&- &
  local p=$!
  sleep 0.3
  run agmsg_pid_is_agent "$p" claude-code
  kill "$p" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "pid-is-agent: accepts a version-named session binary under a full versions/ path" {
  skip_on_windows "process argv faking via exec -a (#349)"
  bash -c 'exec -a "/home/x/.local/share/claude/versions/2.1.199" sleep 5' 3>&- &
  local p=$!
  sleep 0.3
  run agmsg_pid_is_agent "$p" claude-code
  kill "$p" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "pid-is-agent: a version-named binary is NOT accepted for a non-claude-code type" {
  skip_on_windows "process argv faking via exec -a (#349)"
  bash -c 'exec -a "2.1.199" sleep 5' 3>&- &
  local p=$!
  sleep 0.3
  run agmsg_pid_is_agent "$p" codex
  kill "$p" 2>/dev/null || true
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
    >"$BATS_TEST_TMPDIR/w.out" 2>&1 3>&- &
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
