#!/usr/bin/env bash
# Codex state-root helpers shared by the monitor, hooks, and bridge launcher.

agmsg_codex_effective_home() {
  if [ -n "${AGMSG_CODEX_HOME:-}" ]; then
    printf '%s' "$AGMSG_CODEX_HOME"
  elif [ -n "${CODEX_HOME:-}" ]; then
    printf '%s' "$CODEX_HOME"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.codex' "$HOME"
  fi
}

agmsg_codex_default_home() {
  [ -n "${HOME:-}" ] && printf '%s/.codex' "$HOME"
}

# Legacy role records predate codex_home=. They belong to the default
# $HOME/.codex state root, never to an opt-in isolated home.
agmsg_codex_role_home_matches() {
  local recorded="$1" current default
  current="$(agmsg_codex_effective_home)"
  [ -n "$current" ] || return 1
  if [ -z "$recorded" ]; then
    default="$(agmsg_codex_default_home)"
    [ -n "$default" ] || return 1
    recorded="$default"
  fi
  [ "${recorded%/}" = "${current%/}" ]
}

agmsg_codex_sessions_dir() {
  local root
  root="$(agmsg_codex_effective_home)"
  [ -n "$root" ] && printf '%s/sessions' "${root%/}"
}
