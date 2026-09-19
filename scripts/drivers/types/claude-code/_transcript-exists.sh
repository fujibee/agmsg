#!/usr/bin/env bash
# claude-code driver hook: locate / test for a session's own transcript.
#
# Claude Code persists each session as
#   <config-dir>/projects/<munged-project>/<uuid>.jsonl
# where <config-dir> is $CLAUDE_CONFIG_DIR when set (a multi-account/profile
# install, e.g. ~/.claude-accounts/<profile>) and $HOME/.claude otherwise --
# both are the CLI's own env contract, not agmsg's; a caller running under a
# profile whose config dir this ignored would resolve every path one
# directory too shallow and never find a real transcript (#1229 review: this
# was measured wrong against a live multi-account session before the fix).
# <munged-project> is the ABSOLUTE project path with every character outside
# [A-Za-z0-9-] replaced by '-' (so '/', '.', and '_' all become '-'; existing
# '-' and case are preserved; runs of specials are NOT collapsed). Verified
# empirically against Claude Code 2.1.x, e.g.
#   /Users/fujibee/.dotfiles        -> -Users-fujibee--dotfiles
#   /tmp/munge_Test.dir_ab          -> -tmp-munge-Test-dir-ab
#
# This munging is the CLI's INTERNAL on-disk layout, so the knowledge lives in
# the claude-code driver and never leaks into core (spawn.sh only asks "does a
# transcript exist?"; peek.sh's plain-no-pane fallback,
# _peek_native_transcript, only asks to read its tail). Every failure path
# (no resolvable config dir, unreadable dir, empty args) fails closed, so a
# resume-or-fresh boot wrapper falls back to fresh rather than resuming a
# phantom id, and a peek fallback reports "no record" rather than fabricating
# one.
#
# Sourced by spawn.sh when the type declares resume_arg, and by peek.sh for
# the plain-driver peek fallback. Defines:
#   agmsg_transcript_path <uuid> <project>          -> prints the resolved
#     .jsonl path on stdout; rc 0 iff project/uuid are non-empty AND a config
#     dir could be resolved. Never checks the file itself.
#   agmsg_transcript_exists <uuid> <project>        -> 0 iff that path exists
#   agmsg_transcript_tail <uuid> <project> [lines]  -> the file's last <lines>
#     (default 20) raw JSONL lines on stdout; rc 0 iff the file is readable.
#     A pure read -- never writes, never parses the JSON (that is the
#     printer's job, not this hook's).

agmsg_transcript_path() {   # <uuid> <project>
  local uuid="$1" project="$2" root munged
  [ -n "$uuid" ] && [ -n "$project" ] || return 1
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    root="$CLAUDE_CONFIG_DIR"
  elif [ -n "${HOME:-}" ]; then
    root="$HOME/.claude"
  else
    return 1
  fi
  munged="$(printf '%s' "$project" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')" || return 1
  printf '%s/projects/%s/%s.jsonl\n' "$root" "$munged" "$uuid"
}

agmsg_transcript_exists() {
  local file
  file="$(agmsg_transcript_path "$1" "$2")" || return 1
  [ -f "$file" ]
}

agmsg_transcript_tail() {   # <uuid> <project> [lines]
  local file lines="${3:-20}"
  file="$(agmsg_transcript_path "$1" "$2")" || return 1
  [ -r "$file" ] || return 1
  tail -n "$lines" -- "$file"
}
