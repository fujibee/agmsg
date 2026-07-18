#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# Auto-detect tests must not depend on the actual runtime this suite itself
# happens to run under (#142): when bats runs from inside a real Codex/
# Gemini/etc session, ambient env vars and the real process tree can make
# detect_cli_type see a signal the test never set, masking the fallback (or
# a different env var's) path under test.
#
# Derived from the type registry (agmsg_type_get ... detect), not a
# hardcoded list -- detect_cli_type itself is registry-driven with "no
# hardcoded type list" by design (see its own comment in whoami.sh), so a
# hardcoded var list here would silently stop covering a future type's new
# detect= var. Found in review of the first cut of this fix.
clear_autodetect_env() {
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/type-registry.sh"
  local t detect v
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    detect="$(agmsg_type_get "$t" detect)"
    [ -n "$detect" ] && [ "$detect" != "explicit" ] || continue
    for v in $detect; do
      unset "$v" 2>/dev/null || true
    done
  done <<EOF
$(agmsg_known_types | sort -u)
EOF
}

# Prepend a fake `ps` to PATH so detect_cli_type's process-tree walk can
# never match a real ancestor process name (e.g. `codex` when this suite
# itself runs under a live Codex session) -- reports no process name and an
# immediate top-of-tree, so the walk always falls through to the default.
#
# Covers all THREE of compat.sh's process-lookup shapes, not just the
# POSIX one (P1 from review of the first cut): compat_get_comm/
# compat_get_ppid's POSIX branch (`ps -o comm=`/`ps -o ppid=`), AND their
# MSYS branch, which on a real MSYS host tries /proc/<pid>/cmdline and a
# WinPID/CIM lookup BEFORE ever falling back to `ps -l -p` -- so this also
# forces those two branches to skip straight to the ps fallback that this
# mock actually answers.
mock_no_agent_ps() {
  local bindir="$TEST_SKILL_DIR/mock-ps-bin"
  mkdir -p "$bindir"
  cat > "$bindir/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-l"*)
    # MSYS `ps -l -p <pid>` shape (compat_get_comm's final fallback,
    # compat_get_ppid, and _compat_get_winpid all parse this format by
    # HEADER COLUMN NAME, not position). Deliberately name no column
    # WINPID or PPID, so every one of those awk extractors finds nothing
    # and reports empty -- same "nothing found" outcome as the POSIX
    # branch below, not a specific pid value that could be misread as a
    # real ancestor.
    printf 'S UID PID TIME CMD\n'
    printf '0 0 1 0:00 mock-no-agent\n'
    ;;
  *"-o ppid="*) echo 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bindir/ps"
  export PATH="$bindir:$PATH"
  export _AGMSG_COMPAT_NO_PROC=1
  export _AGMSG_COMPAT_NO_CIM=1
}

# --- join.sh ---

@test "join: creates team and adds agent" {
  run bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Joined team myteam as alice" ]]
}

@test "join: creates team config on first join" {
  bash "$SCRIPTS/join.sh" newteam first claude-code /tmp/proj
  [ -f "$TEST_SKILL_DIR/teams/newteam/config.json" ]
}

@test "join: adds multiple agents to same team" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "2 member" ]]
}

@test "join: re-join with same name adds registration instead of duplicate agent" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "1 member" ]]
  [[ "$output" =~ "+1 more" ]]
}

@test "join: concurrent joins to the same team do not lose registrations (#141)" {
  # A fan-out of background joins spawning sqlite3.exe per call is slow and
  # timing-sensitive on the Windows runner (the experimental full leg); the lock
  # itself is exercised on Linux/macOS where the contention is reliable.
  skip_on_windows "concurrency fan-out is too slow/timing-sensitive on the Windows runner"
  # The registry config.json was read-modify-written with no serialization, so
  # concurrent joins clobbered each other and silently dropped agents. Launch a
  # fan-out of joins at once; every one must survive. This fails (count < N+1) if
  # the per-team lock regresses.
  local n=12
  bash "$SCRIPTS/join.sh" race seed claude-code /tmp/seed
  local pids=() i
  for i in $(seq 1 "$n"); do
    bash "$SCRIPTS/join.sh" race "agent$i" claude-code "/tmp/p$i" >/dev/null 2>&1 &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done

  local cfg="$TEST_SKILL_DIR/teams/race/config.json"
  run sqlite_mem "SELECT count(*) FROM json_each(json_extract(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.agents'));"
  [ "$status" -eq 0 ]
  [ "$output" -eq $((n + 1)) ]
}

@test "join: releases its lock (no .config.lock left behind)" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  [ ! -e "$TEST_SKILL_DIR/teams/myteam/.config.lock" ]
}

# --- leave.sh ---

@test "leave: removes agent from team" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam bob claude-code /tmp/proj-b
  run bash "$SCRIPTS/leave.sh" myteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Left team myteam" ]]
  run bash "$SCRIPTS/team.sh" myteam
  [[ ! "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
}

@test "leave: removes team dir when last member leaves" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/leave.sh" myteam alice
  [ ! -d "$TEST_SKILL_DIR/teams/myteam" ]
}

# --- team.sh ---

@test "team: shows team members with types" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "claude-code" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "codex" ]]
}

# --- whoami.sh ---

@test "whoami: returns agent identity" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "teams=myteam" ]]
}

@test "whoami: resolves project paths containing single quotes" {
  local project="$TEST_SKILL_DIR/pro'j"
  mkdir -p "$project/subdir"
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$project"
  run bash "$SCRIPTS/whoami.sh" "$project/subdir" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "teams=myteam" ]]
  [[ "$output" =~ "project=$project" ]]
  [[ ! "$output" =~ "not_joined=true" ]]
  [[ ! "$output" =~ ".parameter" ]]
}

@test "whoami: resolves team and agent names containing single quotes" {
  local team="O'Brien"
  local agent="al'ice"
  bash "$SCRIPTS/join.sh" "$team" "$agent" claude-code /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=$agent" ]]
  [[ "$output" =~ "teams=$team" ]]
  [[ ! "$output" =~ ".parameter" ]]
}

@test "whoami: ignores malformed team configs without sqlite parameter output" {
  mkdir -p "$TEST_SKILL_DIR/teams/bad"
  printf '{' > "$TEST_SKILL_DIR/teams/bad/config.json"
  run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
  [[ ! "$output" =~ ".parameter" ]]
  [[ ! "$output" =~ "malformed JSON" ]]
}

@test "whoami: returns not_joined when no match" {
  run bash "$SCRIPTS/whoami.sh" /tmp/unknown claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
}

@test "whoami: returns multiple when multiple identities" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam reviewer claude-code /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "multiple=true" ]]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "reviewer" ]]
}

@test "whoami: lists available teams when not joined" {
  bash "$SCRIPTS/join.sh" team1 alice claude-code /tmp/other
  run bash "$SCRIPTS/whoami.sh" /tmp/nothere claude-code
  [[ "$output" =~ "available_teams=team1" ]]
}

@test "whoami: finds re-joined agent in another project registration" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-b
  run bash "$SCRIPTS/whoami.sh" /tmp/proj-b claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "teams=myteam" ]]
}

@test "whoami: suggests same-type agents registered elsewhere when no exact match" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  run bash "$SCRIPTS/whoami.sh" /tmp/proj-b claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "suggest=true" ]]
  [[ "$output" =~ "agents=alice" ]]
  [[ "$output" =~ "available_teams=myteam" ]]
}

@test "whoami: auto-detects claude-code from CLAUDE_CODE_SESSION_ID env" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  clear_autodetect_env
  CLAUDE_CODE_SESSION_ID=test-session run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "type=claude-code" ]]
}

@test "whoami: auto-detects codex from CODEX_SANDBOX env" {
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj
  # Clear ALL ambient auto-detect vars, not just CLAUDE_CODE_SESSION_ID --
  # bats can run under a real Codex session that already exports
  # CODEX_THREAD_ID too, which would still land on codex here (so this
  # particular assertion happens to survive it) but masks whether
  # CODEX_SANDBOX specifically is what's being exercised.
  clear_autodetect_env
  CODEX_SANDBOX=seatbelt run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=bob" ]]
  [[ "$output" =~ "type=codex" ]]
}

@test "whoami: auto-detects codex from CODEX_THREAD_ID env" {
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj
  clear_autodetect_env
  CODEX_THREAD_ID=some-thread run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=bob" ]]
  [[ "$output" =~ "type=codex" ]]
}

@test "whoami: defaults to claude-code when no env vars set" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  clear_autodetect_env
  mock_no_agent_ps
  run bash "$SCRIPTS/whoami.sh" /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "type=claude-code" ]]
}

@test "whoami: explicit type overrides auto-detection" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj
  clear_autodetect_env
  CODEX_SANDBOX=test run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "type=claude-code" ]]
}

# --- reset.sh ---

@test "reset: removes only current project registration" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-b
  run bash "$SCRIPTS/reset.sh" /tmp/proj-a claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "removed 1 registration" ]]
  run bash "$SCRIPTS/whoami.sh" /tmp/proj-a claude-code
  [[ "$output" =~ "suggest=true" ]]
  run bash "$SCRIPTS/whoami.sh" /tmp/proj-b claude-code
  [[ "$output" =~ "agent=alice" ]]
}

@test "reset: removes agent when last registration is cleared" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  run bash "$SCRIPTS/reset.sh" /tmp/proj-a claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "removed 1 registration" ]]
  [ ! -d "$TEST_SKILL_DIR/teams/myteam" ]
}

# --- rename-team.sh ---

@test "rename-team: renames the team dir and updates config.json name" {
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/rename-team.sh" oldteam newteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Renamed team oldteam → newteam" ]]
  [ ! -d "$TEST_SKILL_DIR/teams/oldteam" ]
  [ -f "$TEST_SKILL_DIR/teams/newteam/config.json" ]
  run sqlite_mem "SELECT json_extract(readfile('$(rf "$TEST_SKILL_DIR/teams/newteam/config.json")'), '\$.name');"
  [ "$output" = "newteam" ]
}

@test "rename-team: preserves agents in the team" {
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" oldteam bob   codex       /tmp/proj-b
  bash "$SCRIPTS/rename-team.sh" oldteam newteam
  run bash "$SCRIPTS/team.sh" newteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "2 member" ]]
}

@test "rename-team: migrates messages to the new team name" {
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" oldteam bob   claude-code /tmp/proj-b
  bash "$SCRIPTS/send.sh" oldteam alice bob "hello"
  bash "$SCRIPTS/rename-team.sh" oldteam newteam
  run bash "$SCRIPTS/inbox.sh" newteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello" ]]
}

@test "rename-team: fails when old team is missing" {
  run bash "$SCRIPTS/rename-team.sh" nope newname
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Team not found: nope" ]]
}

@test "rename-team: fails when new team already exists" {
  bash "$SCRIPTS/join.sh" team-a alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" team-b bob   claude-code /tmp/proj-b
  run bash "$SCRIPTS/rename-team.sh" team-a team-b
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Team already exists: team-b" ]]
}

@test "rename-team: an inert empty target dir does not block the rename" {
  # The target is reserved by holding teams/<new>/.config.lock, so an existing
  # but config-less dir (e.g. left by an aborted rename) must not count as a team.
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj
  mkdir -p "$TEST_SKILL_DIR/teams/newteam"
  run bash "$SCRIPTS/rename-team.sh" oldteam newteam
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/newteam/config.json" ]
  [ ! -e "$TEST_SKILL_DIR/teams/newteam/.config.lock" ]
  run bash "$SCRIPTS/team.sh" newteam
  [[ "$output" =~ "alice" ]]
}

@test "rename-team: fails when old and new are identical" {
  bash "$SCRIPTS/join.sh" sameteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/rename-team.sh" sameteam sameteam
  [ "$status" -ne 0 ]
  [[ "$output" =~ "same" ]]
}

# --- rename.sh (agent rename) ---

@test "rename: renames an agent, preserving its registration" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  run bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Renamed claude → claude-orchestrator" ]]
  run bash "$SCRIPTS/team.sh" myteam
  [[ "$output" =~ "claude-orchestrator" ]]
  [[ ! "$output" =~ "claude " ]]
}

@test "rename: migrates messages to the new agent name" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob    claude-code /tmp/proj-b
  bash "$SCRIPTS/send.sh" myteam claude bob "hello"
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  run bash "$SCRIPTS/inbox.sh" myteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello" ]]
  [[ "$output" =~ "claude-orchestrator" ]]
}

@test "rename: fails when old agent is missing" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/rename.sh" myteam nope newname
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Agent nope not in team" ]]
}

@test "rename: fails when new agent already exists" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob   claude-code /tmp/proj-b
  run bash "$SCRIPTS/rename.sh" myteam alice bob
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Agent bob already exists" ]]
}

# --- rename.sh tombstone / actas revive guard (#360) ---

@test "rename: leaves a tombstone recording old -> new" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  run sqlite_mem "SELECT json_extract(readfile('$(rf "$TEST_SKILL_DIR/teams/myteam/config.json")'), '\$.renamed[0].from') || ' -> ' || json_extract(readfile('$(rf "$TEST_SKILL_DIR/teams/myteam/config.json")'), '\$.renamed[0].to');"
  [ "$output" = "claude -> claude-orchestrator" ]
}

@test "join: refuses to silently revive a name that was just renamed away" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  run bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  [ "$status" -ne 0 ]
  [[ "$output" =~ "was renamed to 'claude-orchestrator'" ]]
  run bash "$SCRIPTS/team.sh" myteam
  [[ ! "$output" =~ "claude " ]]
}

@test "join: --force still revives a renamed-away name when explicitly requested" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  run bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj --force
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Joined team myteam as claude" ]]
  run bash "$SCRIPTS/team.sh" myteam
  [[ "$output" =~ "claude-orchestrator" ]]
  [[ "$output" =~ "claude " ]]
}

@test "join: after --force revives a name, a later normal join for it no longer needs --force" {
  # Once --force deliberately reuses a renamed-away name, that identity's
  # tombstone must be cleared — otherwise every subsequent registration
  # (e.g. adding a second project) would keep hitting the same guard forever.
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj --force
  run bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj-2
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Joined team myteam as claude" ]]
}

@test "join: joining the new name after a rename succeeds normally" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  run bash "$SCRIPTS/join.sh" myteam claude-orchestrator claude-code /tmp/proj2
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Joined team myteam as claude-orchestrator" ]]
}

@test "join: the tombstone guard does not break on an agent name containing a quote (#87-class)" {
  # Exercises join.sh's new lookup directly against a hand-authored tombstone
  # (rather than going through rename.sh, which has its own pre-existing,
  # unrelated quote-handling gap in its old/new-exists checks — #360 doesn't
  # touch those) to isolate that THIS guard's json_each+WHERE value compare
  # is quote-safe, unlike a raw '$.renamed.<name>' path segment would be.
  local agent="al'ice"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<EOF
{
  "name": "myteam",
  "agents": {},
  "renamed": [
    {"from": "$agent", "to": "bob", "at": "2026-01-01T00:00:00Z"}
  ]
}
EOF
  run bash "$SCRIPTS/join.sh" myteam "$agent" claude-code /tmp/proj
  [ "$status" -ne 0 ]
  [[ "$output" =~ "was renamed to 'bob'" ]]
  [[ ! "$output" =~ "syntax error" ]]
  [[ ! "$output" =~ ".parameter" ]]
}

@test "join: rejects unknown agent type" {
  run bash "$SCRIPTS/join.sh" myteam alice claude /tmp/proj
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown agent type" ]]
}

@test "join: accepts claude-code" {
  run bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts codex" {
  run bash "$SCRIPTS/join.sh" myteam alice codex /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts gemini" {
  run bash "$SCRIPTS/join.sh" myteam alice gemini /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts antigravity" {
  run bash "$SCRIPTS/join.sh" myteam alice antigravity /tmp/proj
  [ "$status" -eq 0 ]
}

@test "join: accepts opencode" {
  run bash "$SCRIPTS/join.sh" myteam alice opencode /tmp/proj
  [ "$status" -eq 0 ]
}
# --- #140: team-name path traversal ---

@test "join: rejects a team name with path traversal (../)" {
  run bash "$SCRIPTS/join.sh" "../../escape-join" alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
  # Nothing was created outside teams/.
  [ ! -f "$(dirname "$TEST_SKILL_DIR")/escape-join/config.json" ]
}

@test "join: rejects '..' and '.' as team names" {
  run bash "$SCRIPTS/join.sh" ".." alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
  [[ "$output" =~ "not allowed" ]]
  run bash "$SCRIPTS/join.sh" "." alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
}

@test "join: rejects a team name starting with '-'" {
  run bash "$SCRIPTS/join.sh" "-rf" alice claude-code /tmp/proj
  [ "$status" -eq 1 ]
  [[ "$output" =~ "must not start with" ]]
}

@test "join: rejects an empty team name" {
  run bash "$SCRIPTS/join.sh" "" alice claude-code /tmp/proj
  [ "$status" -ne 0 ]
}

@test "team: rejects a traversal team name" {
  run bash "$SCRIPTS/team.sh" "../../escape-team"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "leave: rejects a traversal team name" {
  run bash "$SCRIPTS/leave.sh" "../../escape-leave" alice
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "rename: rejects a traversal team name" {
  run bash "$SCRIPTS/rename.sh" "../../escape-rename" old new
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "rename-team: rejects traversal on the new name and does not move outside teams/" {
  bash "$SCRIPTS/join.sh" srcteam bob claude-code /tmp/proj
  run bash "$SCRIPTS/rename-team.sh" srcteam "../../escape-renamed"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
  [ ! -f "$(dirname "$TEST_SKILL_DIR")/escape-renamed/config.json" ]
  # Source team is untouched.
  [ -f "$TEST_SKILL_DIR/teams/srcteam/config.json" ]
}

@test "rename-team: rejects traversal on the old name" {
  run bash "$SCRIPTS/rename-team.sh" "../../escape-old" newteam
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
}

@test "join: still accepts a UTF-8 (Japanese) team name" {
  run bash "$SCRIPTS/join.sh" "テストチーム" alice claude-code /tmp/proj
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/テストチーム/config.json" ]
}

@test "join: accepts hermes" {
  run bash "$SCRIPTS/join.sh" myteam alice hermes /tmp/proj
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/myteam/config.json" ]
}

@test "join: accepts grok-build" {
  run bash "$SCRIPTS/join.sh" myteam alice grok-build /tmp/proj
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/myteam/config.json" ]
}
