#!/usr/bin/env bash
# _bridge-key.sh — the one place bridge_key is derived (#1470 review round 5).
#
# Both the direct session-start.sh path and the out-of-sandbox launcher
# independently filtered PAIRS down to the "safe" set (every registered
# codex pair for the project whose OWN role-session record names this same
# project and thread -- a role with no matching record has no live TUI to
# receive turns, so it is excluded) and then derived bridge_key from it:
# team.agent for exactly one safe pair, a sha1 of the whole set otherwise.
# Two copies of that derivation is how a reader (self-fix.sh's own state
# check) ends up looking at a DIFFERENT key than the one a writer used the
# moment a project has more than one registered codex seat -- the writer's
# safe set can collapse to one pair while the reader, counting every
# registered pair instead of filtering them, hashes a different set
# entirely. This file is the single function every caller uses instead.
#
# Required caller-set variable: SKILL_DIR.
# Requires role-session.sh, resolve-project.sh and hash.sh already sourced
# (agmsg_role_session_uuid/_get, agmsg_canonical_path, agmsg_sha1).

[ -n "${_AGMSG_CODEX_BRIDGE_KEY_SH:-}" ] && return 0
_AGMSG_CODEX_BRIDGE_KEY_SH=1

: "${SKILL_DIR:?_bridge-key.sh requires SKILL_DIR}"

# Prints the bridge_key this (project, thread) combination uses; empty
# (rc 0, no output) when no registered codex pair is safe for it -- that is
# "no bridge_key to check", never a key of its own.
agmsg_codex_bridge_key() {   # <project> <thread_id>
  local project="$1" thread_id="$2" project_phys pairs
  local candidate_team candidate_name candidate_thread candidate_project candidate_project_phys
  local safe_pairs="" pair_n key_team key_name
  [ -n "$thread_id" ] || return 0
  project_phys="$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")"
  pairs="$("$SKILL_DIR/scripts/identities.sh" "$project" codex 2>/dev/null || true)"
  while IFS=$'\t' read -r candidate_team candidate_name; do
    [ -n "$candidate_team" ] || continue
    candidate_thread="$(agmsg_role_session_uuid "$candidate_team" "$candidate_name" 2>/dev/null || true)"
    [ -n "$candidate_thread" ] || continue
    candidate_project="$(agmsg_role_session_get "$candidate_team" "$candidate_name" project 2>/dev/null || true)"
    candidate_project_phys="$(agmsg_canonical_path "$candidate_project" 2>/dev/null || printf '%s' "$candidate_project")"
    { [ "$candidate_project_phys" = "$project_phys" ] && [ "$candidate_thread" = "$thread_id" ]; } || continue
    safe_pairs="${safe_pairs:+$safe_pairs$'\n'}${candidate_team}"$'\t'"${candidate_name}"
  done <<< "$pairs"
  [ -n "$safe_pairs" ] || return 0
  pair_n="$(printf '%s\n' "$safe_pairs" | grep -c . || true)"
  if [ "${pair_n:-0}" -eq 1 ]; then
    IFS=$'\t' read -r key_team key_name <<<"$safe_pairs"
    printf '%s.%s' "$key_team" "$key_name"
  else
    printf '%s' "$(printf '%s' "$safe_pairs" | agmsg_sha1)"
  fi
}
