#!/usr/bin/env bats

# Unit tests for the shared boot-command construction (#339):
#   scripts/lib/boot-command.sh
# Covers the one-key, cli-immediately-after resume convention and the actas
# prompt / role-args tail, independent of spawn.sh and resurrect-panes.sh.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/type-registry.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/boot-command.sh"
}

teardown() { teardown_test_env; }

# --- agmsg_role_resume_head ---

@test "resume_head: empty uuid emits nothing (fresh)" {
  [ -z "$(agmsg_role_resume_head claude-code "")" ]
}

@test "resume_head: emits the manifest resume_arg value verbatim, then the uuid" {
  # claude-code's manifest resume_arg is --resume.
  [ "$(agmsg_role_resume_head claude-code sess-1)" = " --resume sess-1" ]
}

@test "resume_head: nothing when the type has no resume_arg" {
  [ -z "$(agmsg_role_resume_head gemini sess-1)" ]
}

@test "resume_head: composes right after the cli, before other args" {
  # This is the whole convention: <cli><resume head>... must yield
  # `claude --resume <uuid>` adjacently, so a subcommand shape would too.
  local line
  line="claude$(agmsg_role_resume_head claude-code sess-1)$(agmsg_role_cli_args claude-code T-alice '/agmsg actas alice')"
  [[ "$line" == "claude --resume sess-1 "* ]]
}

# --- agmsg_role_cli_args (tail) ---

@test "role_cli_args: name flag + prompt, no resume token in the tail" {
  local out; out="$(agmsg_role_cli_args claude-code T-alice '/agmsg actas alice')"
  [[ "$out" == *"-n T-alice"* ]]
  [[ "$out" == *"actas"* ]]
  [[ "$out" != *"--resume"* ]]
}

@test "role_cli_args: a type without name_arg omits the name flag" {
  local out; out="$(agmsg_role_cli_args gemini T-alice '/agmsg actas alice')"
  [[ "$out" != *" -n "* ]]
  [[ "$out" == *"actas"* ]]
}

@test "role_cli_args: %q-quotes the prompt so spaces survive" {
  local out; out="$(agmsg_role_cli_args claude-code T-alice '/agmsg actas alice')"
  # printf %q renders the spaces as backslash-escapes.
  [[ "$out" == *'/agmsg\ actas\ alice'* ]]
}

# --- agmsg_actas_prompt ---

@test "actas_prompt: default '/' prefix + install command name + actas <agent>" {
  # cmd name is the skill dir basename (the install command name).
  local cmd; cmd="$(basename "$SKILL_DIR")"
  [ "$(agmsg_actas_prompt claude-code alice)" = "/${cmd} actas alice" ]
}

# --- agmsg_role_resume_uuid (gate) ---

@test "role_resume_uuid: empty for a type with no resume_arg" {
  agmsg_role_session_record T alice sess-1 /proj gemini
  [ -z "$(agmsg_role_resume_uuid gemini T alice /proj)" ]
}

@test "role_resume_uuid: empty when force_fresh is set" {
  agmsg_role_session_record T alice sess-1 /proj claude-code
  # transcript present, but force_fresh=1 must still yield empty.
  local munged; munged="$(printf '%s' /proj | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
  mkdir -p "$HOME/.claude/projects/$munged"; : > "$HOME/.claude/projects/$munged/sess-1.jsonl"
  [ -z "$(agmsg_role_resume_uuid claude-code T alice /proj 1)" ]
}

@test "role_resume_uuid: returns the uuid when record + transcript exist" {
  agmsg_role_session_record T alice sess-1 /proj claude-code
  local munged; munged="$(printf '%s' /proj | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
  mkdir -p "$HOME/.claude/projects/$munged"; : > "$HOME/.claude/projects/$munged/sess-1.jsonl"
  [ "$(agmsg_role_resume_uuid claude-code T alice /proj)" = "sess-1" ]
}
