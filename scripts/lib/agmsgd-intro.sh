#!/usr/bin/env bash
# One-time introduction to agmsgd for an install that has not turned it on.
#
# Sourced by session-start.sh. The notice goes to the agent's own screen (hook
# stdout), once per install: the first SessionStart after the install is seen
# with agmsgd off writes run/agmsgd-intro-shown, and no later session prints it
# again. It never switches anything; the reader decides.
#
# Requires: SKILL_DIR and RUN_DIR set; type-registry.sh sourced by the caller.

[ -n "${_AGMSG_AGMSGD_INTRO_SH:-}" ] && return 0
_AGMSG_AGMSGD_INTRO_SH=1

agmsg_agmsgd_intro_notice() {
  local type="${1:-}" skill_dir="${SKILL_DIR:-}" run_dir="${RUN_DIR:-}" marker prefix cmd
  [ -n "$skill_dir" ] && [ -n "$run_dir" ] || return 0
  marker="$run_dir/agmsgd-intro-shown"
  case "$type" in claude-code|codex) ;; *) return 0 ;; esac
  [ ! -e "$marker" ] || return 0
  if ! declare -F agmsg_daemon_read_state >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$skill_dir/scripts/lib/daemon-state.sh"
  fi
  agmsg_daemon_read_state
  # Only a recorded intent that is not "on" gets the notice. An install with no
  # readable record cannot switch anyway, so there is nothing to offer.
  case "${AGMSGD_DESIRED:-unknown}" in off|unset) ;; *) return 0 ;; esac
  # Claim the marker before printing, and print only if this call created it:
  # two sessions starting together show it once, and a marker that cannot be
  # written shows nothing rather than the same line on every start.
  mkdir -p "$run_dir" 2>/dev/null || return 0
  ( set -C; : > "$marker" ) 2>/dev/null || return 0
  cmd="$(basename "$skill_dir")"
  prefix="$(agmsg_type_get "$type" cmd_prefix 2>/dev/null || true)"
  [ -n "$prefix" ] || prefix="/"
  printf 'AGMSG: A new delivery, agmsgd, is available: notices arrive directly, with no Monitor watch to re-arm. Switch with %s%s delivery agmsgd. Nothing changes until you do.\n' "$prefix" "$cmd"
}
