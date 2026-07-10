#!/usr/bin/env bash
# codex driver hook: does a resumable rollout exist for <uuid>? (#339)
#
# Codex persists each session as a "rollout" file:
#   ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session_uuid>.jsonl
# The session UUID is the trailing component of the filename and is exactly the
# SESSION_ID `codex resume <SESSION_ID>` accepts (verified: it equals the
# session_meta payload.id). Unlike claude-code, the layout is date-partitioned,
# not cwd-keyed, so <project> is not part of the lookup.
#
# This on-disk layout is CLI-internal, so the check lives in the codex driver,
# never in core. Every failure (unset HOME, missing dir, empty uuid) returns
# non-zero = "not found", so the resume gate fails open to a fresh session --
# important because `codex resume <gone-uuid>` errors out ("no rollout found")
# rather than starting fresh (verified).
#
# Defines: agmsg_transcript_exists <uuid> <project> -> 0 if a rollout exists.

agmsg_transcript_exists() {
  local uuid="$1" sessions_dir
  [ -n "$uuid" ] || return 1
  [ -n "${HOME:-}" ] || return 1
  sessions_dir="$HOME/.codex/sessions"
  [ -d "$sessions_dir" ] || return 1
  find "$sessions_dir" -type f -name "rollout-*-$uuid.jsonl" 2>/dev/null | grep -q .
}
