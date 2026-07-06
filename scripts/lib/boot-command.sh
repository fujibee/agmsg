#!/usr/bin/env bash
# boot-command.sh — shared construction of a role's resume-or-fresh boot command.
#
# Two launchers bring a role up: spawn.sh (a new/resumed role in a fresh
# terminal/pane) and resurrect-panes.sh (relaunch a role into its tmux pane after
# a server restart). Centralizing the pieces here keeps them from drifting on
# flag order or the resume-vs-fresh gate.
#
# Requires: SKILL_DIR set; type-registry.sh and role-session.sh sourced by the
# caller (for agmsg_type_get / agmsg_type_dir / agmsg_role_session_uuid).

[ -n "${_AGMSG_BOOT_COMMAND_SH:-}" ] && return 0
_AGMSG_BOOT_COMMAND_SH=1

: "${SKILL_DIR:?boot-command.sh requires SKILL_DIR}"

# The actas prompt a booted role runs as its first input:
#   <cmd_prefix><cmd_name> actas <agent>
# cmd_name is the installed command (skill dir basename, honoring a custom
# install name); cmd_prefix is '/' for Claude Code slash commands and '$' for
# agentskills CLIs (type.conf cmd_prefix=). Re-running actas is what re-arms a
# resumed session's watcher, exclusivity lock, and active FROM.
agmsg_actas_prompt() {
  local type="$1" agent="$2" cmd_name cmd_prefix
  cmd_name="$(basename "$SKILL_DIR")"
  cmd_prefix="$(agmsg_type_get "$type" cmd_prefix)"
  [ -n "$cmd_prefix" ] || cmd_prefix="/"
  printf '%s%s actas %s' "$cmd_prefix" "$cmd_name" "$agent"
}

# Resolve the resumable session id for a role, or print nothing when it should
# boot fresh. Fail-open at every gate: force-fresh, no resume_arg, no record, no
# transcript-existence driver hook, or a stale record whose transcript is gone
# all yield empty (=> fresh). <force_fresh> non-zero forces empty.
agmsg_role_resume_uuid() {
  local type="$1" team="$2" agent="$3" project="$4" force_fresh="${5:-0}"
  local resume_arg cand tdir
  [ "$force_fresh" = 0 ] || return 0
  resume_arg="$(agmsg_type_get "$type" resume_arg)"
  [ -n "$resume_arg" ] || return 0
  cand="$(agmsg_role_session_uuid "$team" "$agent" 2>/dev/null || true)"
  [ -n "$cand" ] || return 0
  # The on-disk transcript layout is CLI-internal, so the existence check lives
  # in the type driver (scripts/drivers/types/<type>/_transcript-exists.sh),
  # never here. Absent hook => cannot verify => fresh.
  tdir="$(agmsg_type_dir "$type" 2>/dev/null || true)"
  { [ -n "$tdir" ] && [ -f "$tdir/_transcript-exists.sh" ]; } || return 0
  # shellcheck disable=SC1090
  . "$tdir/_transcript-exists.sh"
  command -v agmsg_transcript_exists >/dev/null 2>&1 || return 0
  agmsg_transcript_exists "$cand" "$project" || return 0
  printf '%s' "$cand"
}

# Emit the role-identity CLI args for <type>, in the order every launcher agrees
# on: [name_arg <session_name>] [resume_arg <uuid>] [prompt_arg] <prompt>. Each
# token is space-prefixed; flags are bare manifest data, values are %q-quoted.
# The caller has already emitted the cli binary (and, for spawn, model +
# spawn-options). A non-empty <resume_uuid> adds the resume flag; empty => fresh.
#
# Resume shape: this assumes the FLAG form `<resume_arg> <uuid>` placed among the
# CLI's options (claude-code's `--resume <uuid>`). Some CLIs instead resume via a
# SUBCOMMAND that must lead the argv, e.g. codex 0.142's `codex resume <id>
# [prompt]`. Wiring one up would need a manifest hint for the emission shape and a
# branch here (subcommand => emit right after the cli, before other flags), not
# just a different resume_arg string. #339 is claude-code-scoped; a codex resume
# is a deliberate follow-up (out of scope here).
agmsg_role_cli_args() {
  local type="$1" session_name="$2" resume_uuid="$3" prompt="$4"
  local name_arg resume_arg prompt_arg
  name_arg="$(agmsg_type_get "$type" name_arg)"
  resume_arg="$(agmsg_type_get "$type" resume_arg)"
  prompt_arg="$(agmsg_type_get "$type" prompt_arg)"
  [ -n "$name_arg" ] && printf ' %s %q' "$name_arg" "$session_name"
  [ -n "$resume_uuid" ] && [ -n "$resume_arg" ] && printf ' %s %q' "$resume_arg" "$resume_uuid"
  [ -n "$prompt_arg" ] && printf ' %s' "$prompt_arg"
  printf ' %q' "$prompt"
}
