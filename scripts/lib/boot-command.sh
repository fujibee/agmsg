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

# Emit the resume HEAD for <type>: the manifest `resume_arg` value followed by
# <resume_uuid>, or nothing when the uuid is empty (=> fresh boot). Space-prefixed;
# resume_arg is emitted VERBATIM (bare manifest data), the uuid %q-quoted.
#
# One-key, cli-immediately-after convention: a single manifest key `resume_arg`
# carries the resume token in whatever shape the CLI wants -- a FLAG
# ('--resume', claude-code) or a SUBCOMMAND ('resume', codex 0.142's
# `codex resume <id> [prompt]`). Callers MUST emit this head right after the cli
# binary and before any other args. That position is mandatory for the subcommand
# shape (a subcommand must lead the argv) and harmless for the flag shape (flags
# are order-independent), so one emission order serves both -- no per-shape branch
# and no second manifest key.
agmsg_role_resume_head() {
  local type="$1" resume_uuid="$2" resume_arg
  [ -n "$resume_uuid" ] || return 0
  resume_arg="$(agmsg_type_get "$type" resume_arg)"
  [ -n "$resume_arg" ] || return 0
  printf ' %s %q' "$resume_arg" "$resume_uuid"
}

# Emit the role-identity TAIL for <type>: [name_arg <session_name>] [prompt_arg]
# <prompt>. Space-prefixed; flags are bare manifest data, values are %q-quoted.
# The caller has already emitted the cli, the resume head (agmsg_role_resume_head),
# and -- for spawn -- model + spawn-options. The resume head is separate because
# it must sit right after the cli (see the convention above); name/prompt are
# order-independent and live here.
agmsg_role_cli_args() {
  local type="$1" session_name="$2" prompt="$3"
  local name_arg prompt_arg
  name_arg="$(agmsg_type_get "$type" name_arg)"
  prompt_arg="$(agmsg_type_get "$type" prompt_arg)"
  [ -n "$name_arg" ] && printf ' %s %q' "$name_arg" "$session_name"
  [ -n "$prompt_arg" ] && printf ' %s' "$prompt_arg"
  printf ' %q' "$prompt"
}
