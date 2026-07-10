#!/usr/bin/env bash
# claude-code driver hook: does a resumable transcript exist for <uuid>?
#
# Claude Code persists each session as
#   ~/.claude/projects/<munged-project>/<uuid>.jsonl
# where <munged-project> is the ABSOLUTE project path with every character
# outside [A-Za-z0-9-] replaced by '-' (so '/', '.', and '_' all become '-';
# existing '-' and case are preserved; runs of specials are NOT collapsed).
# Verified empirically against Claude Code 2.1.x, e.g.
#   /Users/fujibee/.dotfiles        -> -Users-fujibee--dotfiles
#   /tmp/munge_Test.dir_ab          -> -tmp-munge-Test-dir-ab
#
# This munging is the CLI's INTERNAL on-disk layout, so the knowledge lives in
# the claude-code driver and never leaks into core (spawn.sh only asks "does a
# transcript exist?"). Every failure path (unset HOME, unreadable dir, empty
# args) returns non-zero = "not found", so the resume-or-fresh boot wrapper
# fails open to a fresh session rather than resuming a phantom id.
#
# Sourced by spawn.sh when the type declares resume_arg; defines:
#   agmsg_transcript_exists <uuid> <project>  -> 0 if the transcript exists, else 1

agmsg_transcript_exists() {
  local uuid="$1" project="$2" munged file
  [ -n "$uuid" ] && [ -n "$project" ] || return 1
  [ -n "${HOME:-}" ] || return 1
  munged="$(printf '%s' "$project" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')" || return 1
  file="$HOME/.claude/projects/$munged/$uuid.jsonl"
  [ -f "$file" ]
}
