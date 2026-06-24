#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env

  # Stub the agent CLIs so `command -v` succeeds without the real tools, and
  # provide a `record.sh` that captures the launch command instead of opening
  # a terminal. PATH is prepended so the stubs win.
  export STUB_BIN="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$STUB_BIN"
  for bin in claude codex grok hermes; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$bin"
    chmod +x "$STUB_BIN/$bin"
  done
  export CAPTURE="$TEST_SKILL_DIR/launch-capture.txt"
  cat > "$STUB_BIN/record.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
EOF
  chmod +x "$STUB_BIN/record.sh"
  export PATH="$STUB_BIN:$PATH"

  # Never inherit a real tmux server from the test runner — force the
  # OS-terminal path, which we redirect into record.sh via a {cmd} template.
  unset TMUX
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"

  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
}

teardown() {
  teardown_test_env
}

# --- argument validation ---

@test "spawn: rejects unsupported agent type (gemini)" {
  run bash "$SCRIPTS/spawn.sh" gemini foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported by spawn yet" ]]
}

@test "spawn: rejects unsupported agent type (opencode)" {
  run bash "$SCRIPTS/spawn.sh" opencode foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported by spawn yet" ]]
}

@test "spawn: rejects unknown agent type" {
  run bash "$SCRIPTS/spawn.sh" frobnicate foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown agent type" ]]
}

@test "spawn: requires a name" {
  run bash "$SCRIPTS/spawn.sh" claude-code
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage" ]]
}

@test "spawn: rejects invalid --split" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ" --split z
  [ "$status" -ne 0 ]
  [[ "$output" =~ "--split must be" ]]
}

@test "spawn: rejects a nonexistent project" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project /no/such/dir
  [ "$status" -ne 0 ]
  [[ "$output" =~ "project path does not exist" ]]
}

@test "spawn: errors when the target CLI is not installed" {
  rm -f "$STUB_BIN/codex"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # Restrict PATH so a real codex installed on the host can't satisfy the
  # check — only the stub dir (now lacking codex) plus system utilities.
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$SCRIPTS/spawn.sh" codex foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not found on PATH" ]]
}

# --- team resolution ---

@test "spawn: errors when no team is registered for the project" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no team is registered" ]]
}

@test "spawn: errors when the project belongs to multiple teams without --team" {
  bash "$SCRIPTS/join.sh" team-a existing-a claude-code "$PROJ"
  bash "$SCRIPTS/join.sh" team-b existing-b codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "multiple teams" ]]
}

@test "spawn: team resolution survives a single quote in the project path" {
  # resolve_team reads configs via readfile() + SQL string literals, so a
  # project path with a single quote no longer produces a SQL syntax error or
  # a false "no team is registered". (The spawn as a whole may still fail
  # downstream: join.sh and the other shared scripts bind config JSON via
  # `.param set`, which can't carry a single quote — a pre-existing,
  # codebase-wide limitation tracked separately, not introduced here.)
  local quoted="$TEST_SKILL_DIR/pro'j"
  mkdir -p "$quoted"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$quoted"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$quoted"
  [[ "$output" != *"no team is registered"* ]]
  [[ "$output" != *"syntax error"* ]]
}

@test "spawn: --team disambiguates a multi-team project" {
  bash "$SCRIPTS/join.sh" team-a existing-a claude-code "$PROJ"
  bash "$SCRIPTS/join.sh" team-b existing-b codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --team team-b --no-wait
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" =~ team-b$'\t'alice ]]
}

# --- happy path / launch command ---

@test "spawn: pre-joins the name and launches the CLI with the actas prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "spawned claude-code 'alice'" ]]

  # alice is now registered to the resolved team.
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" =~ "alice" ]]

  # The terminal template is handed the path to a generated boot script; that
  # script cd's into the project and runs claude with the actas slash command.
  # (printf %q escapes the spaces in the prompt as "\ ", so assert on tokens.)
  # The slash command is named after the skill dir basename (the install
  # command name), not a hardcoded "agmsg".
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"/$cmd"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"$PROJ"* ]]
}

@test "spawn: grok-build launches the plain grok CLI with the actas prompt" {
  # grok-build is spawnable and monitor=no, so spawn skips the readiness wait.
  # Delivery is a rule file (no hook), so no folder-trust flag is needed —
  # the launch is the bare `grok "/<cmd> actas <name>"`, like claude-code.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" grok-build alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"grok"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" != *"--trust"* ]]
}

# --- --model (#135): per-type model flag, pass-through id ---

@test "spawn --model: claude-code launch includes its --model flag + id" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --model claude-opus-4-8 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude --model claude-opus-4-8"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn --model: codex launch uses its -m model flag" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex alice --project "$PROJ" --model gpt-5 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"codex -m gpt-5"* ]]
}

@test "spawn --model: grok-build launch uses its --model flag" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" grok-build alice --project "$PROJ" --model grok-build --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"grok --model grok-build"* ]]
}

@test "spawn --model: refused for a type with no model_arg in its manifest" {
  run bash "$SCRIPTS/spawn.sh" hermes foo --project "$PROJ" --model whatever --no-wait
  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not support --model" ]]
}

@test "spawn: no --model leaves the launch flag-free" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *"--model"* ]]
}

@test "spawn: actas prompt uses the install command name (not hardcoded agmsg)" {
  # Rename the skill dir to a custom command name and re-point SCRIPTS so the
  # script resolves SKILL_DIR basename = the custom name.
  local custom="$TEST_SKILL_DIR/../m-$$"
  cp -R "$TEST_SKILL_DIR" "$custom"
  bash "$custom/scripts/join.sh" myteam existing claude-code "$PROJ"
  run env AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}" \
    bash "$custom/scripts/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"/m-$$"* ]]
  [[ "$output" != *"/agmsg actas"* ]]
  rm -rf "$custom"
}

@test "spawn: errors when \$TMUX is set but tmux is not on PATH" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # $TMUX set (we look like we're inside tmux) but a PATH that lacks the tmux
  # binary. Mirror the system utilities into a dir that omits tmux, so the test
  # holds on hosts where tmux IS installed (e.g. ubuntu-latest runners) — the
  # point is exercising spawn's "tmux binary not on PATH" branch, not whether
  # the host happens to ship tmux.
  local notmux="$BATS_TEST_TMPDIR/notmux-bin"
  mkdir -p "$notmux"
  local d f b
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=$(basename "$f")
      [ "$b" = tmux ] && continue
      [ -e "$notmux/$b" ] || ln -s "$f" "$notmux/$b" 2>/dev/null || true
    done
  done
  run env TMUX="/tmp/fake,1,0" PATH="$STUB_BIN:$notmux" \
    bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tmux binary is not on PATH" ]]
}

@test "spawn: codex spawns the codex CLI" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"reviewer"* ]]
}

# --- pre-flight exclusivity check ---

@test "spawn: refuses when the name is held by another live session" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$PROJ"
  # Forge a live owner for (myteam, alice).
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  printf '%s\n' LIVESID > "$TEST_SKILL_DIR/run/actas.myteam__alice.session"

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "held by a live session" ]]
}

# --- readiness handshake (#108) ---

@test "spawn: readiness handshake returns status=ready when the watcher attaches" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$TEST_SKILL_DIR/run"
  local ready="$TEST_SKILL_DIR/run/ready.myteam__alice"
  # The terminal "launch" just touches the ready sentinel (and comments out the
  # boot script so its interactive shell never runs in the test).
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 10 --terminal "touch $ready # {cmd}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ready"* ]]
}

@test "spawn: readiness handshake times out (status=timeout, exit 3) when nothing attaches" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 2 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
}

@test "spawn: --no-wait returns immediately with no readiness status" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" != *"status="* ]]
}

@test "spawn: codex skips the readiness wait (no Monitor)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping readiness wait"* ]]
}
