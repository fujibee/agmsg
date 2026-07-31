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
    bash "$SCRIPTS/join.sh" race "agent$i" claude-code "/tmp/p$i" >/dev/null 2>&1 3>&- &
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

@test "leave: retains an id-bearing team when its last member leaves" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/leave.sh" myteam alice
  [ -f "$TEST_SKILL_DIR/teams/myteam/config.json" ]
  [ -f "$TEST_SKILL_DIR/teams/myteam/roster.jsonl" ]
  [ "$(sqlite_mem "SELECT json_array_length(
    json_extract(readfile('$(rf "$TEST_SKILL_DIR/teams/myteam/config.json")'), '\$.agents'));")" -eq 0 ]
}

@test "leave: an agent name containing a single quote doesn't break the underlying SQL statement (#87-class)" {
  local agent="al'ice"
  bash "$SCRIPTS/join.sh" myteam "$agent" claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam bob claude-code /tmp/proj-b
  run bash "$SCRIPTS/leave.sh" myteam "$agent"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "syntax error" ]]
  [[ ! "$output" =~ ".parameter" ]]
  run bash "$SCRIPTS/team.sh" myteam
  [[ ! "$output" =~ "$agent" ]]
  [[ "$output" =~ "bob" ]]
}

@test "leave: rejects an agent name containing path-hazard characters" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/leave.sh" myteam "al.ice"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must not contain" ]]
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

@test "team: an agent name containing a single quote doesn't break the underlying SQL statement (#87-class)" {
  local agent="al'ice"
  bash "$SCRIPTS/join.sh" myteam "$agent" claude-code /tmp/proj
  run bash "$SCRIPTS/team.sh" myteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "$agent" ]]
  [[ ! "$output" =~ ".parameter" ]]
  [[ ! "$output" =~ "Manage SQL parameter bindings" ]]
  [ "$(echo "$output" | grep -c "$agent")" -eq 1 ]
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

@test "reset: retires the member when its last registration is cleared" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  run bash "$SCRIPTS/reset.sh" /tmp/proj-a claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "removed 1 registration" ]]
  [ -f "$TEST_SKILL_DIR/teams/myteam/config.json" ]
  [ -f "$TEST_SKILL_DIR/teams/myteam/roster.jsonl" ]
}

@test "reset: an explicit agent_id containing a single quote doesn't break the underlying SQL statement (#87-class)" {
  local agent="al'ice"
  bash "$SCRIPTS/join.sh" myteam "$agent" claude-code /tmp/proj-a
  run bash "$SCRIPTS/reset.sh" /tmp/proj-a claude-code "$agent"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "syntax error" ]]
  [[ ! "$output" =~ ".parameter" ]]
  [[ "$output" =~ "removed 1 registration" ]]
  [ -f "$TEST_SKILL_DIR/teams/myteam/config.json" ]
  [ -f "$TEST_SKILL_DIR/teams/myteam/roster.jsonl" ]
}

@test "reset: rejects an explicit agent_id containing path-hazard characters" {
  run bash "$SCRIPTS/reset.sh" /tmp/proj-a claude-code "al.ice"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must not contain" ]]
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

@test "rename-team: a new team name containing a single quote doesn't break the underlying SQL statement (#87-class)" {
  local newteam="o'brien"
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/rename-team.sh" oldteam "$newteam"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "syntax error" ]]
  [[ ! "$output" =~ ".parameter" ]]
  [ -f "$TEST_SKILL_DIR/teams/$newteam/config.json" ]
  # The "name" field must be the exact, uncorrupted string — not truncated at
  # the quote, and not left as the old name.
  run sqlite_mem "SELECT json_extract(readfile('$(rf "$TEST_SKILL_DIR/teams/$newteam/config.json")'), '\$.name');"
  [ "$output" = "$newteam" ]
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

@test "rename-team: atomically migrates cursor and sync sidecars" {
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj-a
  export SKILL_DIR="$TEST_SKILL_DIR" AGMSG_STORAGE_DRIVER=sqlite
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init oldteam >/dev/null
  storage_read_cursor_consume oldteam alice 0 >/dev/null
  _sqlite_sync_schema oldteam
  local generation db renamed_db store_dir
  generation=$(_sqlite_sync_generation oldteam)
  # This team is on the default shared partition, so both names resolve to the same
  # file and the rename rewrites columns rather than moving anything. A team that
  # owns its store is covered separately, in the partition tests.
  db=$(agmsg_db_path oldteam)
  renamed_db="$db"
  store_dir=$(agmsg_storage_dir)
  agmsg_sqlite "$db" "INSERT INTO sync_bindings
    (local_team,server_instance_id,remote_team_id,protocol_version,driver_generation)
    VALUES('oldteam','018f3f7e-0000-7000-8000-000000000000',
      '018f3f7e-0000-7000-8000-000000000001',1,'$generation');"
  mkdir -p "$store_dir/remote-sync"
  printf '{"local_team":"oldteam","binding":"fixture"}\n' \
    > "$store_dir/remote-sync/oldteam.json"
  chmod 600 "$store_dir/remote-sync/oldteam.json"
  bash "$SCRIPTS/rename-team.sh" oldteam newteam
  [ "$(agmsg_sqlite "$renamed_db" "SELECT team FROM read_cursors;" | tr -d '\r')" = newteam ]
  [ "$(agmsg_sqlite "$renamed_db" "SELECT local_team FROM sync_bindings;" | tr -d '\r')" = newteam ]
  [ ! -e "$store_dir/remote-sync/oldteam.json" ]
  [ "$(jq -r '.local_team' "$store_dir/remote-sync/newteam.json")" = newteam ]
}

@test "rename-team: JSONL keeps the cursor with the renamed event stream" {
  export SKILL_DIR="$TEST_SKILL_DIR" AGMSG_STORAGE_DRIVER=jsonl
  bash "$SCRIPTS/join.sh" oldteam alice claude-code /tmp/proj-a
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  local id tip
  id=$(storage_send oldteam bob alice hello)
  tip=$(storage_watch_tip oldteam:alice)
  storage_read_cursor_consume oldteam alice "$tip" "$id" >/dev/null
  bash "$SCRIPTS/rename-team.sh" oldteam newteam
  [ "$(storage_read_cursor_get newteam alice)" = "$tip" ]
  [ "$(storage_history newteam | jq -r '.team')" = newteam ]
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

@test "rename: atomically migrates cursor and remote member association" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj-a
  export SKILL_DIR="$TEST_SKILL_DIR" AGMSG_STORAGE_DRIVER=sqlite
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init myteam >/dev/null
  storage_read_cursor_consume myteam claude 0 >/dev/null
  _sqlite_sync_schema myteam
  local generation db
  generation=$(_sqlite_sync_generation myteam)
  # An agent rename does not move the store, so one path serves both ends.
  db=$(agmsg_db_path myteam)
  agmsg_sqlite "$db" "INSERT INTO sync_read_members
    (local_team,server_instance_id,remote_team_id,protocol_version,
     driver_generation,member_id,agent,remote_agent)
    VALUES('myteam','018f3f7e-0000-7000-8000-000000000000',
      '018f3f7e-0000-7000-8000-000000000001',1,'$generation',
      '018f3f7e-0000-7000-8000-000000000010','claude','claude');"
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  [ "$(agmsg_sqlite "$db" "SELECT agent FROM read_cursors;" | tr -d '\r')" = claude-orchestrator ]
  [ "$(agmsg_sqlite "$db" "SELECT agent FROM sync_read_members;" | tr -d '\r')" = claude-orchestrator ]
  [ "$(agmsg_sqlite "$db" "SELECT name_mismatch FROM sync_read_members;" | tr -d '\r')" = 1 ]
}

@test "rename: JSONL keeps exact reads and cursor with the new agent name" {
  export SKILL_DIR="$TEST_SKILL_DIR" AGMSG_STORAGE_DRIVER=jsonl
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj-a
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  local id tip
  id=$(storage_send myteam bob claude hello)
  tip=$(storage_watch_tip myteam:claude)
  storage_read_cursor_consume myteam claude "$tip" "$id" >/dev/null
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  [ "$(storage_read_cursor_get myteam claude-orchestrator)" = "$tip" ]
  [ "$(storage_history myteam | jq -r '.to')" = claude-orchestrator ]
  [ "$(storage_list_unread myteam claude-orchestrator | jq -s 'length')" -eq 0 ]
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

@test "rename: an old/new agent name containing a single quote doesn't break the underlying SQL statement (#87-class)" {
  local old="al'ice" new="bob's-alt"
  bash "$SCRIPTS/join.sh" myteam "$old" claude-code /tmp/proj
  run bash "$SCRIPTS/rename.sh" myteam "$old" "$new"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "syntax error" ]]
  [[ ! "$output" =~ ".parameter" ]]
  run node -e '
    const config = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.exit(Number(!Object.hasOwn(config.agents, process.argv[2]) ||
      Object.hasOwn(config.agents, process.argv[3])));
  ' "$TEST_SKILL_DIR/teams/myteam/config.json" "$new" "$old"
  [ "$status" -eq 0 ]
}

@test "rename: rejects an old/new agent name containing path-hazard characters" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/rename.sh" myteam alice "al.ice"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must not contain" ]]
  run bash "$SCRIPTS/rename.sh" myteam "al[0]" bob
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must not contain" ]]
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

@test "join: --force cannot reassign a renamed-away identity name" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  run bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj --force
  [ "$status" -ne 0 ]
  [[ "$output" =~ "permanently bound" ]]
}

@test "join: a rejected forced reassignment leaves the rename tombstone intact" {
  bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj
  bash "$SCRIPTS/rename.sh" myteam claude claude-orchestrator
  run bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj --force
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/join.sh" myteam claude claude-code /tmp/proj-2
  [ "$status" -ne 0 ]
  [[ "$output" =~ "was renamed to 'claude-orchestrator'" ]]
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

# --- SQL string-literal escaping for interpolated names (#223, #87) ---
# Team and agent names may contain a single quote (validate.sh only blocks path
# traversal). Before escaping, such a name broke the INSERT/UPDATE and was an
# injection surface (a name could widen the WHERE predicate). These pin the
# escaping so a quoted name round-trips and a crafted name cannot touch other
# rows.

@test "rename-team: escapes quoted team names and migrates only the matching team" {
  bash "$SCRIPTS/join.sh" "a'team"    alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" "a'team"    bob   claude-code /tmp/proj-b
  bash "$SCRIPTS/join.sh" "keep'team" carol claude-code /tmp/proj-c
  bash "$SCRIPTS/join.sh" "keep'team" dave  claude-code /tmp/proj-d
  bash "$SCRIPTS/send.sh" "a'team"    alice bob  "moved"
  bash "$SCRIPTS/send.sh" "keep'team" carol dave "stay"

  run bash "$SCRIPTS/rename-team.sh" "a'team" "n'team"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/a'team" ]
  [ -f "$TEST_SKILL_DIR/teams/n'team/config.json" ]

  # config "name" field updated to the quoted new name (json_set value escaped)
  run sqlite_mem "SELECT json_extract(readfile('$(rf "$TEST_SKILL_DIR/teams/n'team/config.json")'), '\$.name');"
  [ "$output" = "n'team" ]

  # the message moved to the new quoted team name (messages + events UPDATE escaped)
  run bash "$SCRIPTS/inbox.sh" "n'team" bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "moved" ]]

  # the other quoted team is untouched — the WHERE predicate was not widened
  run bash "$SCRIPTS/inbox.sh" "keep'team" dave
  [ "$status" -eq 0 ]
  [[ "$output" =~ "stay" ]]
}

@test "rename: escapes the agent name in the messages UPDATE without widening it" {
  # rename.sh rewrites the legacy messages table directly. Seed it with the
  # renamed agent's row plus an unrelated victim row that an unscoped/injection
  # predicate would wrongly rewrite. The seed goes into team t's own store —
  # the pre-split shared file is no longer what rename.sh reads.
  bash "$SCRIPTS/join.sh" t alice claude-code /tmp/proj
  export SKILL_DIR="$TEST_SKILL_DIR"
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init t >/dev/null
  local db; db="$(agmsg_db_path t)"
  sqlite3 "$db" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('t', 'alice', 'x', 'a-msg');"
  sqlite3 "$db" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('t', 'keepme', 'x', 'k-msg');"

  run bash "$SCRIPTS/rename.sh" t alice carol
  [ "$status" -eq 0 ]

  # the renamed agent's row moved to the new name ...
  run sqlite3 "$db" "SELECT from_agent FROM messages WHERE body='a-msg';"
  [ "$output" = "carol" ]
  # ... and the unrelated row was NOT rewritten (predicate stayed scoped)
  run sqlite3 "$db" "SELECT from_agent FROM messages WHERE body='k-msg';"
  [ "$output" = "keepme" ]
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

@test "team: a pulled member with no local registration is listed and counted" {
  # A machine that pulled a team holds members it has never registered locally:
  # the roster is real, the registrations are empty, and that is the correct
  # state rather than a broken one. The listing joined through the
  # registrations array, so those members produced no row at all and the team
  # read as empty.
  mkdir -p "$TEST_SKILL_DIR/teams/pulled"
  cat > "$TEST_SKILL_DIR/teams/pulled/config.json" <<'JSON'
{
  "name": "pulled",
  "team_id": "018f3f7e-2222-7000-8000-000000000002",
  "agents": {
    "alice": { "member_id": "018f3f7e-2222-7000-8000-000000000010", "registrations": [] },
    "bob":   { "member_id": "018f3f7e-2222-7000-8000-000000000011", "registrations": [] },
    "carol": { "member_id": "018f3f7e-2222-7000-8000-000000000012",
               "registrations": [ { "type": "claude-code", "project": "/tmp/p" } ] }
  },
  "created_at": "2026-07-29T00:00:00Z"
}
JSON
  run bash "$SCRIPTS/team.sh" pulled
  [ "$status" -eq 0 ]
  # Every member appears, not just the one with a registration.
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"bob"* ]]
  [[ "$output" == *"carol"* ]]
  # And the count agrees with the roster rather than with the join.
  [[ "$output" == *"3 member(s)"* ]]
  # The absence is described, not left blank.
  [[ "$output" == *"no local registration"* ]]
}

@test "team: a locally registered member still lists its type and project" {
  # The fix must not change what a normal member looks like.
  bash "$SCRIPTS/join.sh" localteam alice claude-code /tmp/project-x >/dev/null
  run bash "$SCRIPTS/team.sh" localteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice (claude-code) — /tmp/project-x"* ]]
  [[ "$output" == *"1 member(s)"* ]]
  [[ "$output" != *"no local registration"* ]]
}
