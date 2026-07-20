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
  # Subcommand shape: `codex resume cx-uuid-1 ...` -- resume token right after cli.
  [[ "$output" == *"codex resume cx-uuid-1"* ]]
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

@test "spawn: opencode launches its 'run --interactive' fixed subcommand prefix" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" opencode alice --project "$PROJ" --model anthropic/claude-opus-4-8 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"opencode run --interactive --model anthropic/claude-opus-4-8"* ]]
  [[ "$output" == *"actas"* ]]
  # no bare 'opencode' invocation without the fixed prefix
  [[ "$output" != *$'\n''opencode --model'* ]]
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
  run env TMUX="/tmp/fake,1,0" FAKE_UNAME_S="MINGW64_NT-10.0-19045" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  # A new window is the other branch.
  run env TMUX="/tmp/fake,1,0" FAKE_UNAME_S="MINGW64_NT-10.0-19045" \
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
  run env TMUX="/tmp/fake,1,0" FAKE_UNAME_S="Linux" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  # Unix tmux honors the shebang, so no `bash -l` wrapper is emitted.
  run grep -F 'bash -l' "$cap"
  [ "$status" -ne 0 ]
  # ...and the bare boot path is still the launched command.
  run grep -E 'split-window .* /.*boot-' "$cap"
  [ "$status" -eq 0 ]
}
