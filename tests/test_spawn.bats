#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env

  # Stub the agent CLIs so `command -v` succeeds without the real tools, and
  # provide a `record.sh` that captures the launch command instead of opening
  # a terminal. PATH is prepended so the stubs win.
  export STUB_BIN="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$STUB_BIN"
  for bin in claude codex grok hermes cursor-agent gemini agy copilot opencode; do
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

  # Never inherit a real tmux server or herdr env from the test runner —
  # force the OS-terminal path, which we redirect into record.sh via a {cmd}
  # template. Unsetting HERDR_ENV/HERDR_PANE_ID is critical when the test
  # runner itself is inside herdr: a real herdr pane split would affect the
  # live session.
  unset TMUX
  unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"

  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
}

teardown() {
  teardown_test_env
}

# --- argument validation ---

@test "spawn: rejects a known type with neither cli= nor spawn= (#277)" {
  # All nine built-ins are spawnable now, so the 'not supported by spawn yet'
  # gate (a known type missing both cli= and spawn=) needs a fixture — no
  # real built-in demonstrates it any more.
  local nd="$TEST_SKILL_DIR/scripts/drivers/types/noclitype"
  mkdir -p "$nd"
  printf 'name=noclitype\ntemplate=template.md\n' > "$nd/type.conf"
  run bash "$SCRIPTS/spawn.sh" noclitype foo --project "$PROJ"
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

@test "spawn: a multi-word cli= (opencode) checks only its first word's existence (#277)" {
  rm -f "$STUB_BIN/opencode"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$SCRIPTS/spawn.sh" opencode foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "'opencode' not found on PATH" ]]
  # never searches for the literal multi-word string as one executable name
  [[ "$output" != *"'opencode run --interactive' not found"* ]]
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
  [[ "$output" =~ "launched claude-code 'alice'" ]]

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

@test "spawn: names the session <team>-<agent> when the type has name_arg (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]

  # claude-code's manifest declares name_arg=-n, so the boot script launches the
  # CLI with `-n myteam-alice` (the resolved team joined to the agent name).
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"-n myteam-alice"* ]]
}

@test "spawn: boot script marks the session AGMSG_SPAWNED=1 (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  # The spawned session carries the marker so the actas flow suppresses the
  # hand-started "rename this session" tip.
  [[ "$output" == *"export AGMSG_SPAWNED=1"* ]]
}

@test "spawn: a type without name_arg emits no name flag (#339)" {
  # gemini's manifest has no name_arg=, so the boot script must not name the
  # session -- no bare `-n` token, unchanged from pre-#339 behavior.
  bash "$SCRIPTS/join.sh" gteam existing gemini "$PROJ"
  run bash "$SCRIPTS/spawn.sh" gemini bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]

  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *" -n "* ]]
  [[ "$output" != *"gteam-bob"* ]]
}

# Seed a role-session record + its transcript so spawn's resume path fires.
# Mirrors spawn's own project normalization + the driver's munging so the paths
# line up. With want_transcript=0 the record exists but the transcript does not
# (stale record → spawn must fall back to fresh).
seed_resumable() {
  local team="$1" agent="$2" uuid="$3" proj="$4" want_transcript="${5:-1}"
  local norm munged
  export SKILL_DIR="$TEST_SKILL_DIR"   # both libs below require it at source time
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/resolve-project.sh"
  norm="$(cd "$proj" && pwd)"
  norm="$(agmsg_normalize_project_path "$norm")"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record "$team" "$agent" "$uuid" "$norm"
  if [ "$want_transcript" -eq 1 ]; then
    munged="$(printf '%s' "$norm" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
    mkdir -p "$HOME/.claude/projects/$munged"
    : > "$HOME/.claude/projects/$munged/$uuid.jsonl"
  fi
}

@test "spawn: resumes the role's prior session when record + transcript exist (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  seed_resumable myteam alice "sess-uuid-1" "$PROJ" 1

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  # Resumed by uuid, still named after the role, still runs the actas prompt.
  [[ "$output" == *"--resume sess-uuid-1"* ]]
  [[ "$output" == *"-n myteam-alice"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: --fresh forces a fresh session even when resumable (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  seed_resumable myteam alice "sess-uuid-1" "$PROJ" 1

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --fresh
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
  [[ "$output" == *"-n myteam-alice"* ]]   # naming still applies
}

@test "spawn: falls back to fresh when the record's transcript is gone (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  seed_resumable myteam alice "sess-uuid-1" "$PROJ" 0   # record only, no transcript

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
}

@test "spawn: a fresh role (no record) boots fresh (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
}

@test "spawn: a type without resume_arg never resumes (#339)" {
  # gemini has no resume_arg in its manifest, so even with a record present the
  # boot must be fresh (and gemini also has no name_arg, so no -n either).
  bash "$SCRIPTS/join.sh" gteam existing gemini "$PROJ"
  seed_resumable gteam bob "sess-uuid-9" "$PROJ" 1

  run bash "$SCRIPTS/spawn.sh" gemini bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
}

@test "spawn: codex resumes via the 'resume' subcommand right after the cli (#339)" {
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  # Record a codex role->session and a matching rollout (codex's transcript).
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record cxteam bob "cx-uuid-1" "$PROJ" codex
  mkdir -p "$HOME/.codex/sessions/2026/07/05"
  : > "$HOME/.codex/sessions/2026/07/05/rollout-2026-07-05T10-00-00-cx-uuid-1.jsonl"

  run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  # Subcommand shape: `<shim> resume cx-uuid-1 ...` -- resume token right after
  # the executable (the bundled codex-shim.sh, which forwards argv to codex).
  [[ "$output" == *"codex-shim.sh resume cx-uuid-1"* ]]
  [[ "$output" == *"actas"* ]]
  # codex has no name_arg, so no -n.
  [[ "$output" != *" -n "* ]]
}

@test "spawn: codex boots fresh when no rollout backs the record (#339)" {
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record cxteam bob "cx-uuid-gone" "$PROJ" codex   # record, no rollout

  run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"resume"* ]]
}

@test "spawn: boot script unsets the type's session-identity vars (#294)" {
  # A same-type spawn (claude-code from a claude-code session) must not leak the
  # parent's CLAUDE_CODE_SESSION_ID to the child, or the child mistakes the
  # parent's session for its own and every turn fails with an Authentication
  # error. The generated boot script unsets the type's detect= vars up front.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"unset CLAUDE_CODE_SESSION_ID"* ]]
  # The unset must come before the CLI launch line, so the exec'd child never
  # sees the inherited var.
  run bash -c "grep -n 'unset CLAUDE_CODE_SESSION_ID' '$boot' | cut -d: -f1"
  local unset_line="$output"
  run bash -c "grep -n 'actas' '$boot' | head -1 | cut -d: -f1"
  [ "$unset_line" -lt "$output" ]
}

@test "spawn: does NOT unset a type's credential/detect vars (#294)" {
  # The strip list is a dedicated spawn_unset_env=, NOT detect=. gemini's
  # detect=GEMINI_CLI GEMINI_API_KEY: the session marker + a credential, not a session id —
  # stripping them would break the spawned child's auth (the opposite of the fix).
  # gemini has no spawn_unset_env=, so its boot script must emit no `unset` at all
  # and in particular must never unset GEMINI_API_KEY.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" gemini alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" != *"unset GEMINI_API_KEY"* ]]
  [[ "$output" != *"unset "* ]]
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
  [[ "$output" == *"codex-shim.sh -m gpt-5"* ]]
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
  # No real built-in is spawnable without a model_arg (#279 dropped hermes'
  # spawnable=yes, its only remaining example) — fixture a minimal one,
  # reusing the already-stubbed `claude` binary as its cli=.
  local nd="$TEST_SKILL_DIR/scripts/drivers/types/nomodeltype"
  mkdir -p "$nd"
  printf 'name=nomodeltype\ntemplate=template.md\ncli=claude\nspawnable=yes\n' > "$nd/type.conf"
  run bash "$SCRIPTS/spawn.sh" nomodeltype foo --project "$PROJ" --model whatever --no-wait
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

# --- newly spawnable types (#277): cursor, gemini, antigravity, copilot, opencode ---

@test "spawn: cursor launches cursor-agent with a bare positional prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" cursor alice --project "$PROJ" --model sonnet-4-thinking --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"cursor-agent --model sonnet-4-thinking"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: gemini launches gemini with a bare positional prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" gemini alice --project "$PROJ" --model gemini-3-pro --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"gemini --model gemini-3-pro"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: antigravity launches agy with --prompt-interactive (not a bare positional)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" antigravity alice --project "$PROJ" --model gemini-3-pro --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"agy --model gemini-3-pro --prompt-interactive"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: copilot launches copilot with --interactive (not a bare positional)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" copilot alice --project "$PROJ" --model gpt-5.4 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"copilot --model gpt-5.4 --interactive"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: opencode launches opencode with --prompt (not a bare positional)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" opencode alice --project "$PROJ" --model anthropic/claude-opus-4-8 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"opencode --model anthropic/claude-opus-4-8 --prompt"* ]]
  # opencode's actas prompt uses the '$' skill prefix, not Claude Code's '/' (#283).
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  run grep -F "\$$cmd"'\ actas' "$boot"
  [ "$status" -eq 0 ]
  run grep -F "/$cmd"'\ actas' "$boot"
  [ "$status" -ne 0 ]
}

@test "spawn: prompt_arg lands after spawn-options, immediately before the prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
antigravity:
  --sandbox: true
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" antigravity alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"agy --sandbox --prompt-interactive"* ]]
}

# --- spawn options (#273): per-type extra CLI args from a YAML file ---

@test "spawn: injects spawn-options flags from AGMSG_SPAWN_OPTIONS_FILE" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
  --dangerously-skip-permissions: true
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude --permission-mode acceptEdits --dangerously-skip-permissions"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: spawn-options flags land after --model, before the actas prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --model claude-opus-4-8 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude --model claude-opus-4-8 --permission-mode acceptEdits"* ]]
}

@test "spawn: a false spawn-options value suppresses that flag" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
claude-code:
  --dangerously-skip-permissions: false
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "spawn: only the spawned type's section applies, not another type's" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
codex:
  --sandbox: workspace-write
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *"--sandbox"* ]]
}

@test "spawn: no spawn-options file leaves the launch unchanged" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env AGMSG_SPAWN_OPTIONS_FILE="$TEST_SKILL_DIR/no-such-file.yaml" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude"*"actas"* ]]
}

@test "spawn: falls back to ~/.agmsg/config/spawn_options.yaml when the env var is unset" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$HOME/.agmsg/config"
  cat > "$HOME/.agmsg/config/spawn_options.yaml" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
YAML
  unset AGMSG_SPAWN_OPTIONS_FILE
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"--permission-mode acceptEdits"* ]]
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

@test "spawn: --boot-prompt appends an initial task to the actas prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait \
    --boot-prompt "review the diff"
  [ "$status" -eq 0 ]

  # The boot script still carries the actas slash command, and now ALSO the
  # task text, so the spawned agent claims its identity AND acts on the task in
  # its first turn. (printf %q escapes spaces, so assert on tokens.)
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"diff"* ]]
}

@test "spawn: without --boot-prompt the boot script carries no extra task text" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]

  # Guards the byte-identical claim: with no --boot-prompt, only the actas command
  # is passed — no task text leaks into the boot script.
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" != *"review the diff"* ]]
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
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" PATH="$STUB_BIN:$notmux" \
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

@test "spawn: resolve_team reads team configs via agmsg_sql_readfile_path (Windows-native sqlite3 regression)" {
  # sqlite3.exe (native Windows) cannot readfile() a POSIX-form path: it returns
  # NULL, the JSON probe yields no rows, and spawn dies with 'no team is
  # registered' even though join succeeded. The helper cygpath-converts and
  # SQL-escapes; a bare sed-escape here reintroduces the bug. No portable
  # runtime probe exists (it needs a native sqlite3 plus a POSIX-form tmpdir),
  # so assert the source directly.
  run grep -F 'cfg_sql=$(agmsg_sql_readfile_path "$config_file")' "$SCRIPTS/spawn.sh"
  [ "$status" -eq 0 ]
}

@test "spawn: codex boot prompt uses the \$ skill prefix, not / (#283)" {
  # codex invokes a skill with \$<cmd>, not Claude Code's /<cmd>. The boot script
  # must carry \$<cmd> actas, never /<cmd> actas. (%q escapes the space as "\ ",
  # so match the "<prefix><cmd>\ actas" token — the cd path's /<cmd>/proj has no
  # "\ actas" and so can't false-match the slash form.)
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  run grep -F "\$$cmd"'\ actas' "$boot"
  [ "$status" -eq 0 ]
  run grep -F "/$cmd"'\ actas' "$boot"
  [ "$status" -ne 0 ]
}

@test "spawn: claude-code boot prompt keeps the / slash prefix (#283)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  run grep -F "/$cmd"'\ actas' "$boot"
  [ "$status" -eq 0 ]
  run grep -F "\$$cmd"'\ actas' "$boot"
  [ "$status" -ne 0 ]
}

@test "spawn: '/'-prefixed boot prompt is guarded against MSYS path conversion" {
  # On Git Bash / MSYS, an argv token starting with '/' is rewritten to a
  # Windows path when handed to a native binary: '/agmsg actas alice' arrives
  # as 'C:/Program Files/Git/agmsg actas alice'. The boot script must scope it
  # out via MSYS2_ARG_CONV_EXCL on the CLI launch line (prefix-scoped, NOT
  # MSYS_NO_PATHCONV=1, so genuine path args keep converting).
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  # The guard must sit on the same line as the CLI invocation, ahead of it.
  run grep -E "^MSYS2_ARG_CONV_EXCL=/$cmd claude" "$boot"
  [ "$status" -eq 0 ]
}

@test "spawn: \$-prefixed boot prompt gets no MSYS guard (codex)" {
  # '$'-prefixed prompts are not path-shaped, so no exclusion is emitted —
  # keeps the boot script byte-identical for agentskills CLIs.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run grep -F "MSYS2_ARG_CONV_EXCL" "$boot"
  [ "$status" -ne 0 ]
}

@test "spawn: boot script keeps the .command suffix only on macOS (#282)" {
  # macOS `open -a Terminal` needs .command to execute the file; every other
  # launcher runs it via bash or its shebang, and on Windows .command makes
  # Explorer/psmux open it in Notepad instead of running it.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  if [ "$(uname -s)" = "Darwin" ]; then
    [[ "$boot" == *.command ]]
  else
    [[ "$boot" != *.command ]]
  fi
}

@test "spawn: macOS terminal launch does not steal focus (Terminal and iTerm)" {
  # A no-op-Terminal spawn (no $TMUX, no AGMSG_TERMINAL override) exercises
  # launch_macos_terminal() itself, which every other test in this file
  # bypasses via the record.sh {cmd} template. `-g`/`--background` must be
  # present so `open` never brings the newly launched terminal to the front
  # -- without it, spawning from a caller with no tmux context (e.g. a GUI
  # app) interrupts whatever the user is doing in the foreground app.
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "launch_macos_terminal() is Darwin-only"
  fi
  unset AGMSG_TERMINAL
  # Deterministic regardless of which terminal actually runs this test suite
  # (launch_macos_terminal defaults to "iterm" when $TERM_PROGRAM is
  # iTerm.app, which would otherwise make this assertion flaky on an iTerm
  # dev machine).
  unset TERM_PROGRAM
  cat > "$STUB_BIN/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
EOF
  chmod +x "$STUB_BIN/open"

  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  run cat "$CAPTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-g -a Terminal"* ]]

  rm -f "$CAPTURE"
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  AGMSG_TERMINAL=iterm run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  run cat "$CAPTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-g -a iTerm"* ]]
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

@test "spawn: --no-wait on a monitor=YES type still reports launched-unconfirmed (no post-input confirmation)" {
  # Full-head review: --no-wait skips the readiness handshake by request, so startup is
  # NOT confirmed — exactly like monitor=no. Both no-confirmation paths must report
  # status=launched-unconfirmed (a distinct note keeps the reasons apart). A monitor=YES
  # type (claude-code) with --no-wait is the arm that was silently falling through both
  # branches with no status line at all.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "status=launched-unconfirmed" <<<"$output"
  grep -q "note=no-wait" <<<"$output"
  refute grep -q "status=ready" <<<"$output"
}

@test "spawn: codex skips the readiness wait (no Monitor)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping readiness wait"* ]]
}

@test "spawn: grok-build skips the readiness wait even without --no-wait (monitor=no)" {
  # Regression guard: grok-build's monitor watcher attaches via the agent's
  # actas/rule launch (no SessionStart hook) and only in monitor mode, so there
  # is no ready sentinel for spawn to await. With monitor=no, spawn must skip the
  # wait and return immediately instead of hanging a default turn/off-mode spawn
  # until --ready-timeout. (Without this, monitor=yes made the wait fire.)
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" grok-build alice --project "$PROJ" \
    --terminal "true # {cmd}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping readiness wait"* ]]
  [[ "$output" != *"status=timeout"* ]]
  [[ "$output" != *"status=ready"* ]]
}

@test "spawn: a no-handshake type (monitor=no) reports startup UNCONFIRMED, not a bare success" {
  # Observed live: "spawned" printed while the agent had not started (a startup shell prompt
  # ate the first keystroke of the boot command). A type with no readiness handshake
  # cannot confirm startup, so spawn must say so DISTINCTLY — status=launched-unconfirmed
  # with an explanation — instead of letting the placement line stand as success.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" \
    --terminal "true # {cmd}"
  [ "$status" -eq 0 ]
  grep -q "status=launched-unconfirmed" <<<"$output"
  grep -q "note=no-readiness-handshake" <<<"$output"
  grep -q "STARTUP IS UNCONFIRMED" <<<"$output"
  # the placement line is a placement FACT, not a success claim
  grep -q "launched codex 'reviewer'" <<<"$output"
  refute grep -q "spawned codex 'reviewer'" <<<"$output"
}

@test "spawn: --no-wait says 'launched' (never 'spawned'), and its unconfirmed NOTE differs from monitor=no's" {
  # The placement word is 'launched', never 'spawned', on the --no-wait path too; and
  # the two no-confirmation reasons read apart — --no-wait carries note=no-wait, a
  # monitor=no type carries note=no-readiness-handshake (distinct wording).
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "launched claude-code 'alice'" <<<"$output"
  refute grep -q "spawned claude-code 'alice'" <<<"$output"
  grep -q "status=launched-unconfirmed" <<<"$output"
  grep -q "note=no-wait" <<<"$output"
  refute grep -q "note=no-readiness-handshake" <<<"$output"
}

@test "spawn: a CONFIRMED start (handshake) is the only path that proves startup (status=ready)" {
  # The positive observation — the watcher attaching (the ready sentinel) — is what
  # distinguishes "started" from "typed but never ran". Only status=ready asserts it.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$TEST_SKILL_DIR/run"
  local ready="$TEST_SKILL_DIR/run/ready.myteam__alice"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 10 --terminal "touch $ready # {cmd}"
  [ "$status" -eq 0 ]
  grep -q "launched claude-code 'alice'" <<<"$output"
  grep -q "status=ready" <<<"$output"
  refute grep -q "status=launched-unconfirmed" <<<"$output"
}

# --- initial prompt (--boot-prompt) ---
# spawn folds an optional initial task into the agent's first prompt: the boot
# prompt becomes the actas slash command followed (newline-separated) by the
# task, so the new agent claims its identity AND starts the task in one turn —
# the only way to hand a one-shot goal to a no-Monitor peer (codex). These tests
# assert on the generated boot script the terminal template is handed (captured
# via record.sh), the same way the actas-prompt tests above do.

@test "spawn: --boot-prompt requires a task (missing arg errors)" {
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --boot-prompt
  [ "$status" -ne 0 ]
  [[ "$output" == *"--boot-prompt needs a task"* ]]
}

@test "spawn: --boot-prompt \"\" is treated as no task (no-op, not an error)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # An explicit empty string must NOT abort the spawn — it degrades to a plain
  # spawn (so a scripted `--boot-prompt "$VAR"` with an empty VAR still works).
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --boot-prompt ""
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  # No task appended → no newline-join → boot prompt unchanged.
  [[ "$output" != *'\n'* ]]
}

@test "spawn: --boot-prompt folds the initial task into the boot prompt (codex)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" \
    --boot-prompt "REVIEW_THE_DIFF"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"reviewer"* ]]
  [[ "$output" == *"REVIEW_THE_DIFF"* ]]
}

# --- #335: psmux on Windows cannot exec an extensionless boot script ---
#
# These fake `uname -s` (via a stub honoring $FAKE_UNAME_S) and stub `tmux` to
# capture its argv, so the Windows launch path is exercised on a Linux/macOS
# runner. On Windows the boot script must run through `bash -l`; elsewhere the
# bare path (shebang-honored by Unix tmux) is kept.

@test "spawn: launch_in_tmux runs the boot script via bash -l on Windows (#335)" {
  local cap="$TEST_SKILL_DIR/tmux-argv.txt"
  : > "$cap"
  cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Linux}"
EOF
  chmod +x "$STUB_BIN/uname"
  cat > "$STUB_BIN/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cap"
case "\$1" in
  new-window)   echo '@1' ;;
  split-window) echo '%1' ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/tmux"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # Default target is a split pane.
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" FAKE_UNAME_S="MINGW64_NT-10.0-19045" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  # A new window is the other branch.
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" FAKE_UNAME_S="MINGW64_NT-10.0-19045" \
    bash "$SCRIPTS/spawn.sh" claude-code bob --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  # Both branches must launch through `bash -l <boot>`, not the bare path.
  run grep -E 'split-window .* bash -l /' "$cap"
  [ "$status" -eq 0 ]
  run grep -E 'new-window .* bash -l /' "$cap"
  [ "$status" -eq 0 ]
}

@test "spawn: launch_in_tmux keeps the bare boot path off Windows (#335)" {
  local cap="$TEST_SKILL_DIR/tmux-argv.txt"
  : > "$cap"
  cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Linux}"
EOF
  chmod +x "$STUB_BIN/uname"
  cat > "$STUB_BIN/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cap"
case "\$1" in
  new-window)   echo '@1' ;;
  split-window) echo '%1' ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/tmux"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" FAKE_UNAME_S="Linux" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  # Unix tmux honors the shebang, so no `bash -l` wrapper is emitted.
  run grep -F 'bash -l' "$cap"
  [ "$status" -ne 0 ]
  # ...and the bare boot path is still the launched command.
  run grep -E 'split-window .* /.*boot-' "$cap"
  [ "$status" -eq 0 ]
}

# --- herdr placement ---

# Helper: set up a fake herdr binary that records calls and returns canned JSON.
_setup_fake_herdr() {
  local herdr_stub="$STUB_BIN/herdr"
  export HERDR_CALL_LOG="$TEST_SKILL_DIR/herdr-calls.log"
  cat > "$herdr_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
# Responses are overridable so a test can hand back a differently shaped
# document (reordered keys, nested fields, extra pane objects) without
# rewriting the stub.
DEFAULT_SPLIT='{"id":"cli:pane:split","result":{"pane":{"pane_id":"wT:pN","tab_id":"wT:tA"},"type":"pane_info"}}'
DEFAULT_TAB='{"id":"cli:tab:create","result":{"root_pane":{"pane_id":"wT:pR","tab_id":"wT:tN"},"tab":{"tab_id":"wT:tN","label":"test"},"type":"tab_created"}}'
case "$1/$2" in
  pane/split)
    printf '%s\n' "${HERDR_SPLIT_RESPONSE:-$DEFAULT_SPLIT}"
    ;;
  pane/rename|pane/run|pane/close)
    echo '{"id":"cli:pane:'"$2"'","result":{"type":"ok"}}'
    ;;
  pane/process-info)
    # requirement 1: default to a READY pane (foreground pgid == shell pid) so the
    # readiness gate passes; a test overrides HERDR_PROCESS_INFO_RESPONSE (and its exit
    # via HERDR_PROCESS_INFO_RC) to drive the not-ready / unknown arms. The default is
    # assigned separately, NOT inside ${VAR:-…}: braces in a default terminate the
    # parameter expansion early and leak trailing } into the output.
    pi_out="$HERDR_PROCESS_INFO_RESPONSE"
    [ -n "$pi_out" ] || pi_out='{"result":{"process_info":{"shell_pid":4242,"foreground_process_group_id":4242}}}'
    printf '%s\n' "$pi_out"
    exit "${HERDR_PROCESS_INFO_RC:-0}"
    ;;
  tab/create)
    printf '%s\n' "${HERDR_TAB_RESPONSE:-$DEFAULT_TAB}"
    ;;
  tab/close)
    echo '{"id":"cli:tab:close","result":{"type":"ok"}}'
    ;;
  *)
    echo '{"error":"unknown stub call: '"$*"'}' >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$herdr_stub"
  export HERDR_ENV=1
  export HERDR_PANE_ID="wT:pSelf"
  export HERDR_WORKSPACE_ID="wT"
  # Clear the terminal template so spawn does not take the template path.
  unset AGMSG_TERMINAL
  # Ensure the run/ directory exists for placement records.
  mkdir -p "$TEST_SKILL_DIR/run"
}

@test "spawn: herdr split — launches in a herdr pane with herdr: placement record" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"launched claude-code 'alice' in herdr"* ]]

  # herdr was called: pane split, pane rename, pane run.
  grep -q "pane split wT:pSelf --direction right --no-focus" "$HERDR_CALL_LOG"
  grep -q "pane rename wT:pN alice" "$HERDR_CALL_LOG"
  grep -q "pane run wT:pN" "$HERDR_CALL_LOG"

  # Placement record uses herdr: scheme tag.
  local rec="$TEST_SKILL_DIR/run/spawn.myteam__alice"
  [ -f "$rec" ]
  local rec_id
  IFS=$'\t' read -r rec_id _ _ < "$rec"
  [ "$rec_id" = "herdr:wT:pN" ]
}

@test "spawn: herdr split --split v maps to --direction down" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --split v
  [ "$status" -eq 0 ]
  grep -q "pane split wT:pSelf --direction down --no-focus" "$HERDR_CALL_LOG"
}

@test "spawn: herdr --window uses tab create and extracts root_pane pane_id" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  grep -q "tab create --workspace wT --label alice" "$HERDR_CALL_LOG"
  grep -q "pane run wT:pR" "$HERDR_CALL_LOG"

  local rec="$TEST_SKILL_DIR/run/spawn.myteam__alice"
  [ -f "$rec" ]
  local rec_id
  IFS=$'\t' read -r rec_id _ _ < "$rec"
  [ "$rec_id" = "herdr:wT:pR" ]
}

@test "spawn: herdr --window falls back to split when HERDR_WORKSPACE_ID is unset" {
  _setup_fake_herdr
  unset HERDR_WORKSPACE_ID
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  # Fell back to split, not tab create.
  refute grep -q "tab create" "$HERDR_CALL_LOG"
  grep -q "pane split" "$HERDR_CALL_LOG"
}

@test "spawn: tmux takes priority over herdr (backward compat for tmux-inside-herdr)" {
  _setup_fake_herdr
  # Set $TMUX so the tmux path wins; re-set the terminal template so the test
  # doesn't actually run tmux (use the stub recorder).
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%0"
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"
  # Provide a tmux stub that just records the call.
  cat > "$STUB_BIN/tmux" <<'TMUXSTUB'
#!/usr/bin/env bash
case "$1" in
  split-window) echo "%99" ;;
  select-pane|set-window-option) ;;
esac
TMUXSTUB
  chmod +x "$STUB_BIN/tmux"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"in tmux"* ]]
  # herdr was NOT called.
  [ ! -f "$HERDR_CALL_LOG" ] || ! grep -q "pane split" "$HERDR_CALL_LOG"
}

# --- herdr response parsing: address the pane id by path, never by position ---
#
# herdr's replies are structured JSON, so key order and neighbouring objects
# are not part of the contract. Reading the id positionally (last "pane_id" in
# the text, or the first one inside a `[^}]*` window) silently selects a
# different pane when the shape shifts — spawn would then rename that pane, run
# the boot script in it, and persist its id as the placement record. These fix
# the shapes that break positional matching.

_spawn_recorded_id() {
  local rec="$TEST_SKILL_DIR/run/spawn.myteam__alice" id
  [ -f "$rec" ] || return 1
  IFS=$'\t' read -r id _ _ < "$rec"
  printf '%s' "$id"
}

@test "spawn: herdr split picks result.pane.pane_id even when another pane object follows it" {
  _setup_fake_herdr
  # A second pane object after the target: a trailing-match reader takes
  # wT:pWRONG and would drive the wrong pane.
  export HERDR_SPLIT_RESPONSE='{"id":"cli:pane:split","result":{"pane":{"pane_id":"wT:pRIGHT"},"neighbor":{"pane_id":"wT:pWRONG"}},"type":"pane_info"}'
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "pane run wT:pRIGHT" "$HERDR_CALL_LOG"
  refute grep -q "wT:pWRONG" "$HERDR_CALL_LOG"
  [ "$(_spawn_recorded_id)" = "herdr:wT:pRIGHT" ]
}

@test "spawn: herdr split tolerates reordered keys in the pane object" {
  _setup_fake_herdr
  export HERDR_SPLIT_RESPONSE='{"result":{"type":"pane_info","pane":{"tab_id":"wT:tA","cwd":"/x","pane_id":"wT:pLAST"}},"id":"cli:pane:split"}'
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [ "$(_spawn_recorded_id)" = "herdr:wT:pLAST" ]
}

@test "spawn: herdr --window reads root_pane.pane_id past a nested object" {
  _setup_fake_herdr
  # `scroll` and `agent_session` are real herdr fields that sort before
  # pane_id; a `[^}]*` window stops at the first closing brace and misses it.
  export HERDR_TAB_RESPONSE='{"id":"cli:tab:create","result":{"root_pane":{"agent_session":{"kind":"id"},"scroll":{"offset_from_bottom":0},"pane_id":"wT:pNESTED"},"tab":{"tab_id":"wT:tN","pane_id":"wT:pTABWRONG"},"type":"tab_created"}}'
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  grep -q "pane run wT:pNESTED" "$HERDR_CALL_LOG"
  refute grep -q "wT:pTABWRONG" "$HERDR_CALL_LOG"
  [ "$(_spawn_recorded_id)" = "herdr:wT:pNESTED" ]
}

@test "spawn: herdr split fails closed on a malformed or unusable response" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local body
  # Not JSON at all; the right path missing; and a non-string value. None may
  # be treated as a usable pane id, and none may leave a placement record.
  for body in 'not json at all {{{' \
              '{"id":"cli:pane:split","result":{"type":"ok"}}' \
              '{"result":{"pane":{"pane_id":42}}}'; do
    _setup_fake_herdr
    export HERDR_SPLIT_RESPONSE="$body"
    run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
    [ "$status" -ne 0 ]
    # The pane-id extraction + fail-closed now lives in the herdr driver (its own
    # tests pin the exact reasons); spawn reports the placement failure and — the
    # contract that matters here — leaves NO placement record and renames/runs nothing.
    grep -q "placement failed" <<<"$output"
    [ ! -f "$TEST_SKILL_DIR/run/spawn.myteam__alice" ]
    ! grep -q "pane run" "$HERDR_CALL_LOG"
  done
}

# --- requirement 1: herdr pre-input pane readiness (process-info gate) ---
# process-info's foreground_process_group_id == shell_pid says the shell is at its
# prompt. The gate acts on THREE outcomes distinctly (like peek's 10/12/13).

@test "spawn req1: a NOT-READY pane (foreground process running) is not typed — fail with reason, pane closed" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RESPONSE='{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200}}}'
  # The wait bound is FIXED (no env knob): this loops the whole bound (~5s) before failing.
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -ne 0 ]
  grep -q "was not ready for input" <<<"$output"
  refute grep -q "pane run" "$HERDR_CALL_LOG"     # the boot was NOT typed
  grep -q "pane close" "$HERDR_CALL_LOG"          # the pane we created was closed
  [ ! -f "$TEST_SKILL_DIR/run/spawn.myteam__alice" ]   # nothing launched -> no record
}

@test "spawn req1: UNKNOWN readiness (process-info errors) still types, warns BEFORE-typing, and records" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RC=1                  # process-info fails -> UNKNOWN (arm 3)
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "pane run" "$HERDR_CALL_LOG"            # arm 3 types anyway
  grep -q "BEFORE the boot was typed" <<<"$output"
  [ -f "$TEST_SKILL_DIR/run/spawn.myteam__alice" ]
}

@test "spawn req1: null==null process-info is UNKNOWN, not READY (equality only after validation)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RESPONSE='{"result":{"process_info":{"shell_pid":null,"foreground_process_group_id":null}}}'
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "BEFORE the boot was typed" <<<"$output"   # UNKNOWN, not a silent ready
  grep -q "pane run" "$HERDR_CALL_LOG"
}

@test "spawn req1: a numeric-STRING pid is UNKNOWN on BOTH arms and either field (json_type must be integer)" {
  # json_extract turns a JSON string "5" into 5, which would pass a digit
  # check; the classifier requires json_type=integer on BOTH fields. Each case below
  # must be UNKNOWN -> type + BEFORE-typing warning, NOT the NOT-READY 5s-wait/fail and
  # NOT a silent ready. The cases pin the drift a one-sided control would miss:
  #   - "5"/"5"  numeric string, EQUAL   (a value-only check would call it READY)
  #   - "5"/"6"  numeric string, UNEQUAL (must NOT fall to NOT-READY; the gate is on the
  #                                       values, not only the equality arm)
  #   - 5 / "5"  MIXED: an integer and a numeric string (catches type-gating only ONE
  #                                       field — the ungated string would match READY)
  #   - "5"/ 5   MIXED the other way
  local resp
  for resp in '{"result":{"process_info":{"shell_pid":"5","foreground_process_group_id":"5"}}}' \
              '{"result":{"process_info":{"shell_pid":"5","foreground_process_group_id":"6"}}}' \
              '{"result":{"process_info":{"shell_pid":5,"foreground_process_group_id":"5"}}}' \
              '{"result":{"process_info":{"shell_pid":"5","foreground_process_group_id":5}}}'; do
    bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ" >/dev/null 2>&1 || true
    _setup_fake_herdr
    export HERDR_PROCESS_INFO_RESPONSE="$resp"
    run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
    [ "$status" -eq 0 ]                                     || { echo "FAIL status=$status for $resp"; return 1; }
    grep -q "BEFORE the boot was typed" <<<"$output"       || { echo "FAIL not UNKNOWN warning for $resp"; return 1; }
    grep -q "pane run" "$HERDR_CALL_LOG"                    || { echo "FAIL not typed for $resp"; return 1; }
    refute grep -q "was not ready for input" <<<"$output"  || { echo "FAIL fell to NOT-READY for $resp"; return 1; }
  done
}

@test "spawn req1: a READY pane types with NO readiness warning" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr                                # default process-info = equal pids
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "pane run" "$HERDR_CALL_LOG"
  refute grep -q "BEFORE the boot was typed" <<<"$output"
}

@test "spawn req1: a non-herdr (plain) spawn never runs the process-info gate" {
  # The gate is herdr-only; a plain placement must not emit its warning.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  refute grep -q "BEFORE the boot was typed" <<<"$output"
}

@test "spawn req1: arm-3 (pre-input) and launched-unconfirmed (post-input) are DISTINCT messages" {
  # The two 'unconfirmed' reasons must read apart. A monitor=no type spawned
  # through herdr with UNKNOWN readiness shows BOTH, worded differently.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RC=1                  # arm 3 (before-typing unknown)
  run env -u TMUX bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "BEFORE the boot was typed" <<<"$output"          # arm 3, before typing
  grep -q "status=launched-unconfirmed" <<<"$output"         # requirement 2, after typing
  grep -q "no-readiness-handshake" <<<"$output"
}

# --- --terminal-driver / AGMSG_TERMINAL_DRIVER override ---
@test "spawn: --terminal-driver plain forces the OS-terminal path even when \$TMUX is set" {
  # The default setup provides a {cmd} template (AGMSG_TERMINAL -> record.sh), so the
  # plain path is captured. With $TMUX set, detection would pick tmux; the override
  # must force the OS terminal instead.
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%0"
  : > "$CAPTURE"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --terminal-driver plain
  [ "$status" -eq 0 ]
  grep -q "terminal template" <<<"$output"
  [ -s "$CAPTURE" ]        # the OS-terminal launcher ran (record.sh captured it)
}

@test "spawn: AGMSG_TERMINAL_DRIVER=plain forces the OS-terminal path (env form)" {
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%0" AGMSG_TERMINAL_DRIVER=plain
  : > "$CAPTURE"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [ -s "$CAPTURE" ]
}

@test "spawn: --terminal-driver validates EARLY — before team resolution or any state change" {
  # An unknown driver is a deterministic arg typo, so it must fail before spawn
  # registers a role or writes a boot file, and before an unrelated 'no team' can mask
  # it. With NO team registered for the project, a bogus driver must STILL error with
  # 'unknown terminal driver' (not 'no team') — proving the check runs at parse time.
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --terminal-driver bogus
  [ "$status" -ne 0 ]
  grep -q "unknown terminal driver" <<<"$output"
  refute grep -q "no team" <<<"$output"
  # Nothing was registered for the spawn target (it failed before the pre-join).
  [ ! -f "$TEST_SKILL_DIR/run/spawn.myteam__alice" ]
}

@test "spawn: a placement-record WRITE failure -> status=spawned-but-unrecorded, non-zero" {
  # The record is the only authority peek/poke/despawn --force have. If the write
  # fails (here: the run dir made read-only, so agmsg_write_atomic cannot even create
  # its temp beside the record — the shape a real ENOSPC/permission failure takes),
  # the member is live but unaddressable — a distinct, worse state than a clean spawn,
  # so spawn reports status=spawned-but-unrecorded with the pane ref and exits
  # non-zero, not ready. The atomic write also guarantees the failure NEVER truncates
  # a correct existing record; here there is none yet, only the failed create.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$TEST_SKILL_DIR/run"
  chmod 500 "$TEST_SKILL_DIR/run"                       # record write will fail
  cat > "$STUB_BIN/tmux" <<'T'
#!/usr/bin/env bash
case "$1" in split-window) echo '%9' ;; select-pane|set-window-option) ;; esac
exit 0
T
  chmod +x "$STUB_BIN/tmux"
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  chmod 700 "$TEST_SKILL_DIR/run"                       # restore so teardown can clean up
  [ "$status" -ne 0 ]
  grep -q "status=spawned-but-unrecorded" <<<"$output"
  grep -q "tmux:%9" <<<"$output"
}

@test "spawn: the plain driver's '-' protocol value never leaks to spawn stdout" {
  # _launch_os_terminal captures terminal_spawn's record-op stdout ('-' = placed, no
  # pane) and verifies it, rather than letting it print. A normal OS-terminal spawn
  # must not emit a lone '-' line alongside the human status.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  refute grep -qx -- '-' <<<"$output"          # no line that is just the protocol '-'
  grep -q "terminal template" <<<"$output"     # the OS-terminal path did run
}

# --- codex launches through the bundled shim, by path (spawn_wrapper=) ---------
# A person's shell reaches codex-shim.sh as a function or a PATH entry; the
# non-interactive shell that runs a boot script has neither, so a bare `codex`
# there is the real binary and the seat starts without --remote (measured: the
# bridge restarts every few seconds against a thread it cannot own). The
# manifest names the shim relative to the type directory and spawn addresses it
# by that bundled path.

# The executable of a boot script's CLI line: the first word that is not a
# leading VAR=value assignment (the MSYS argv guard, #336, prefixes every line).
_boot_line_executable() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i !~ /=/) { print $i; exit } }'
}

@test "spawn: codex is launched through the bundled shim by its absolute path, not a bare cli" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  # The CLI line's first word is the shim inside THIS skill dir -- not `codex`,
  # not something found on PATH.
  local shim; shim="$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-shim.sh"
  grep -qF "$shim" "$boot"
  # And it is the executable of the actas line (the token before the prompt).
  local line; line="$(grep -F 'actas' "$boot" | head -1)"
  echo "actas line: $line"
  [ "$(_boot_line_executable "$line")" = "$shim" ]
  # The bare cli must not be launched anywhere in the script.
  [ "$(grep -cE '^codex |^[A-Z_]+=[^ ]* codex ' "$boot")" -eq 0 ]
}

@test "spawn: a declared wrapper that is missing is a refusal, never a silent bare-cli launch" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  # Break the bundled shim (the type manifest still declares it).
  chmod -x "$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-shim.sh"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'launch wrapper'
  printf '%s\n' "$output" | grep -qF 'codex-shim.sh'
  # Nothing was placed or launched: no boot script was handed to the terminal.
  [ ! -s "$CAPTURE" ]
  chmod +x "$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-shim.sh"
}

@test "spawn: a type without spawn_wrapper still launches its bare cli (claude-code)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  # The actas line's executable is the bare `claude` (resolved by the pane's
  # PATH), with no wrapper in front of it.
  local line; line="$(grep -F 'actas' "$boot" | head -1)"
  echo "actas line: $line"
  [ "$(_boot_line_executable "$line")" = claude ]
  [ "$(grep -c 'codex-shim' "$boot")" -eq 0 ]
}

@test "spawn: a spawned codex reaches the real binary WITH --remote (argv read from the boot script's launch)" {
  # End to end: run the boot script spawn wrote. Its shim resolves the real
  # codex on PATH (a fake that records argv and can bring up an app-server),
  # enters codex-monitor because the project is in monitor mode, and execs the
  # real binary with --remote. The argv the fake recorded is the evidence.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" bash "$boot"
  _assert_bridged_argv
}

@test "spawn: a codex seat spawned FROM a bridged codex seat still reaches the real binary WITH --remote" {
  # codex-monitor exports AGMSG_CODEX_BRIDGE=1 right before it execs the bridged
  # TUI, so a seat spawned from inside that session inherits it, and the shim
  # passes straight to the real binary when it sees it -- ahead of any guard in
  # codex-monitor (found in review). The boot script must unset the inherited
  # bridge/opt-out state BEFORE the wrapper runs; this seeds all of it and reads
  # the argv that arrives.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  # The guard sits BEFORE the act: the namespace-clearing line (every
  # AGMSG_CODEX_* exported variable, enumerated at boot time) and the literal
  # unset both precede the wrapper line. One assertion per line, on purpose: an
  # `a && b && c` list does not fail the test when `a` fails.
  local ns_ln lit_ln cli_ln
  ns_ln="$(grep -n 'for _v in $(env | sed .*AGMSG_CODEX_' "$boot" | head -1 | cut -d: -f1)"
  lit_ln="$(grep -n '^unset .*CODEX_THREAD_ID' "$boot" | head -1 | cut -d: -f1)"
  cli_ln="$(grep -n 'codex-shim.sh' "$boot" | head -1 | cut -d: -f1)"
  [ -n "$ns_ln" ]
  [ -n "$lit_ln" ]
  [ -n "$cli_ln" ]
  [ "$ns_ln" -lt "$cli_ln" ]
  [ "$lit_ln" -lt "$cli_ln" ]
  grep -q '^unset .*AGMSG_REAL_CODEX' "$boot"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_CODEX_BRIDGE=1 AGMSG_CODEX_BRIDGE_APP_SERVER="ws://127.0.0.1:1" AGMSG_CODEX_BRIDGE_LAUNCHER=1 \
    CODEX_THREAD_ID=parent-thread bash "$boot"
  _assert_bridged_argv
}

@test "spawn: an inherited AGMSG_CODEX_SHIM_DISABLE=1 does not make a spawned codex seat bypass the shim" {
  # The shim's other early exit. Seeded ALONE, so this variable is proven
  # handled on its own and not only in the company of the bridge one.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_CODEX_SHIM_DISABLE=1 bash "$boot"
  _assert_bridged_argv
}

# Fake codex + bridge stack for the end-to-end launches: a `codex` on PATH that
# records its argv and can serve a fake app-server, a stub bridge launcher, and a
# stand-in for the shell the boot script execs into at the end.
_install_fake_codex_bridge_stack() {
  export CALL_LOG="$TEST_SKILL_DIR/codex-calls.log"
  cat > "$STUB_BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.142.2"; exit 0 ;;
  app-server)
    python3 - <<'PY'
import socket, sys, os
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16); s.settimeout(0.2)
print("codex app-server (WebSockets)")
print("  listening on: ws://127.0.0.1:%d" % s.getsockname()[1]); sys.stdout.flush()
ppid = os.getppid()
while True:
    if os.getppid() != ppid:
        break
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
PY
    ;;
  *)
    printf 'real-codex' >> "$CALL_LOG"
    for a in "$@"; do printf ' <%s>' "$a" >> "$CALL_LOG"; done
    printf '\n' >> "$CALL_LOG"
    ;;
esac
FAKE
  chmod +x "$STUB_BIN/codex"
  # The bridge launcher is detached and Node-based; stand in for it BY FILE in
  # this test copy of the skill, not through AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:
  # the boot script unsets every shim-stack override, so an env hook set by the
  # test would be cleared before the wrapper runs (which is the point).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-bridge-launcher.sh"
  # The boot script ends with `exec "$SHELL" -i`; give it a shell that just exits.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/noshell"; chmod +x "$STUB_BIN/noshell"
}

# The evidence both end-to-end tests read: the real binary was reached exactly
# once, bridged, with the actas prompt. Then the fake app-server is put down.
_assert_bridged_argv() {
  [ -f "$CALL_LOG" ]
  # The real binary was reached exactly once, with the bridge flag and the actas prompt.
  [ "$(grep -c '^real-codex' "$CALL_LOG")" -eq 1 ]
  grep -q '^real-codex <--remote> <ws://127\.0\.0\.1:[0-9][0-9]*>' "$CALL_LOG"
  grep -q 'actas' "$CALL_LOG"
  grep -q 'reviewer' "$CALL_LOG"
  # Clean up the fake app-server the shim brought up.
  local pf pid
  for pf in "$TEST_SKILL_DIR"/run/codex-app-server.*.pid; do
    [ -f "$pf" ] || continue
    pid="$(cat "$pf" 2>/dev/null)"; [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
}

@test "spawn: an inherited PATH-wrapper install (AGMSG_CODEX_SHIM_WRAPPER/SCRIPT_DIR) cannot repoint the bundled shim" {
  # The installed ~/.agents/bin wrapper exports AGMSG_CODEX_SHIM_WRAPPER=1 and
  # AGMSG_CODEX_SHIM_SCRIPT_DIR before starting the bundled shim; a codex started
  # through it passes both to anything it spawns. Inherited, the bundled shim
  # would take the PARENT's script dir as its own (codex-shim.sh, the WRAPPER
  # branch) -- here a stale directory with no delivery.sh, which the shim reads
  # as "not a monitor project" and passes straight to the real binary (found in
  # review). Seeded with exactly that, the seat must still arrive bridged.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  local stale; stale="$TEST_SKILL_DIR/stale-install"; mkdir -p "$stale"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_CODEX_SHIM_WRAPPER=1 AGMSG_CODEX_SHIM_SCRIPT_DIR="$stale" AGMSG_CODEX_SHIM_TARGET="$stale/codex" bash "$boot"
  _assert_bridged_argv
}

@test "spawn: inherited resolution overrides (real binary, monitor, launcher) do not steer a spawned codex seat" {
  # The remaining shim-stack inputs: a parent's AGMSG_REAL_CODEX,
  # AGMSG_CODEX_MONITOR_CMD and the launcher command overrides. Seeded with paths
  # that do not exist, the seat must still resolve everything from its own
  # install and arrive bridged; if any of them leaked through, the launch would
  # fail or go plain, and the argv below would not be recorded.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_REAL_CODEX=/nonexistent/parent-codex AGMSG_CODEX_MONITOR_CMD=/nonexistent/parent-monitor \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/nonexistent/parent-launcher AGMSG_CODEX_BRIDGE_CMD=/nonexistent/parent-bridge \
    bash "$boot"
  _assert_bridged_argv
}

@test "spawn: every environment variable the codex shim stack reads is cleared for a spawned seat (reader inventory)" {
  # The list in type.conf is only as good as its coverage. This pins it to the
  # readers: every ${AGMSG_CODEX_*} / ${AGMSG_REAL_CODEX} the shim, monitor and
  # launcher consult must be in spawn_unset_env, so the next control variable
  # added to the stack cannot be inherited by a spawned seat unnoticed. The
  # spawn marker itself is the one exception -- it is what the seat is.
  # Derivation: every `$VAR`/`${VAR` in the stack's bash files and every
  # `process.env.VAR` in the bridge, for VAR matching AGMSG_* or CODEX_*.
  # Each such name must be covered by spawn_unset_env — literally, or by a
  # namespace entry (`PREFIX*`) — unless it is on the short, reasoned keep list
  # below. A new reader outside the namespace fails here, which is the only way
  # a deny rule can say "we would notice".
  local dir="$SCRIPTS/drivers/types/codex" v listed entry covered
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/type-registry.sh"
  listed="$(agmsg_type_get codex spawn_unset_env)"
  # Kept on purpose (each with its reason in type.conf): the seat's own marker;
  # agmsg-wide configuration the CLI's actas flow legitimately inherits; test
  # hooks that only bats sets; and names that are script-local variables
  # assigned inside the stack before they are read, never environment inputs
  # (role-session lookup results, codex-monitor's parsed command/args/version,
  # the doc URL constant from delivery.sh).
  local keep=" AGMSG_SPAWNED AGMSG_BASH AGMSG_WATCH_ONCE_INTERVAL AGMSG_WATCH_ONCE_TIMEOUT AGMSG_TEST_DISPATCHER_STALE_BARRIER AGMSG_TEST_ASSUME_CODEX_SOCKET AGMSG_ROLE_SESSION_UUID AGMSG_ROLE_SESSION_PROJECT CODEX_ARGS CODEX_COMMAND CODEX_VERSION CODEX_MONITOR_DOC_URL "
  local inventory missing=""
  inventory="$( { grep -ohE '\$\{?(AGMSG_[A-Z0-9_]+|CODEX_[A-Z0-9_]+)' "$dir"/codex-shim.sh "$dir"/codex-monitor.sh "$dir"/_app-server.sh "$dir"/codex-bridge-launcher.sh "$dir"/codex-record-session.sh "$dir"/_session-start.sh "$dir"/codex-shim-install.sh "$dir"/_delivery.sh | sed -E 's/^\$\{?//'; grep -ohE 'process\.env\.(AGMSG_[A-Z0-9_]+|CODEX_[A-Z0-9_]+)' "$dir"/codex-bridge.js | sed 's/process\.env\.//'; } | sort -u )"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$keep" in *" $v "*) continue ;; esac
    covered=0
    for entry in $listed; do
      case "$entry" in
        *\*) case "$v" in "${entry%\*}"*) covered=1 ;; esac ;;
        *)   [ "$v" = "$entry" ] && covered=1 ;;
      esac
    done
    [ "$covered" -eq 1 ] || missing="$missing $v"
  done <<LIST
$inventory
LIST
  echo "inventory: $(printf '%s\n' "$inventory" | wc -l | tr -d ' ') names; not covered:$missing"
  [ -z "$missing" ]
  # Positive controls for the extractor: the inventory must contain the names
  # the two review rounds found, or an empty scan would pass vacuously.
  printf '%s\n' "$inventory" | grep -qx 'AGMSG_CODEX_SHIM_SCRIPT_DIR'
  printf '%s\n' "$inventory" | grep -qx 'AGMSG_CODEX_BRIDGE'
  printf '%s\n' "$inventory" | grep -qx 'CODEX_THREAD_ID'
}

@test "spawn: a shim-stack control variable that does not exist yet is still cleared (namespace, not list)" {
  # The deny-list failed twice in review, each time by one name. The boot
  # script therefore clears the whole AGMSG_CODEX_* namespace as enumerated from
  # the environment at boot time. Seed a name no code reads today and dump the
  # environment the real binary actually receives: the seeded name is gone,
  # while an ordinary variable survives (positive control: the dump is real and
  # the clearing is not "unset everything").
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  # Extend the fake: on the bridged launch, also dump its environment.
  sed -i.bak 's|    printf .real-codex. >> "\$CALL_LOG"|    env > "$CALL_LOG.env"\n&|' "$STUB_BIN/codex"; rm -f "$STUB_BIN/codex.bak"
  grep -q 'env > "\$CALL_LOG.env"' "$STUB_BIN/codex"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" AGMSG_CODEX_FUTURE_KNOB=1 SPAWN_TEST_CANARY=alive bash "$boot"
  _assert_bridged_argv
  [ -f "$CALL_LOG.env" ]
  grep -q '^SPAWN_TEST_CANARY=alive$' "$CALL_LOG.env"
  [ "$(grep -c '^AGMSG_CODEX_FUTURE_KNOB=' "$CALL_LOG.env")" -eq 0 ]
  # And the seat's own marker is NOT cleared by the namespace rule.
  grep -q '^AGMSG_SPAWNED=1$' "$CALL_LOG.env"
}
