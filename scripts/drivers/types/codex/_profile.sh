#!/usr/bin/env bash
# The Codex profile (CODEX_HOME) a conversation really runs in.
#
# Newer Codex runs tool commands in the managed app-server's shell, whose
# environment carries only HOME, LANG, LOGNAME, PATH, SHELL and USER, so a
# CODEX_HOME given to the TUI never reaches `actas`. The SessionStart hook runs
# in the TUI's environment, so it publishes the profile per thread and
# codex-record-session.sh reads it back instead of falling to ~/.codex.
# Sourced with resolve-project.sh already loaded (agmsg_canonical_path,
# agmsg_normalize_project_path).

# Prints the absolute, canonical profile directory of THIS process's
# environment (CODEX_HOME, else $HOME/.codex). Prints nothing and returns 1
# when it is not an existing absolute directory.
agmsg_codex_profile_from_env() {
  local home="${CODEX_HOME:-${HOME:+$HOME/.codex}}"
  agmsg_codex_profile_canonical "$home"
}

agmsg_codex_profile_canonical() {
  local home="${1:-}"
  case "$home" in
    *[[:cntrl:]]*|'') return 1 ;;
    /* | [A-Za-z]:/* | [A-Za-z]:\\*) ;;
    *) return 1 ;;
  esac
  [ -d "$home" ] || return 1
  home="$(agmsg_canonical_path "$home")" || return 1
  home="$(agmsg_normalize_project_path "$home")" || return 1
  case "$home" in
    *[[:cntrl:]]*|'') return 1 ;;
    /* | [A-Za-z]:/* | [A-Za-z]:\\*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$home"
}

_agmsg_codex_thread_home_file() {   # <run_dir> <thread>
  case "${2:-}" in
    *[!0-9A-Fa-f-]*|'') return 1 ;;
  esac
  [ -n "${1:-}" ] || return 1
  printf '%s/codex-thread-home.%s\n' "$1" "$2"
}

# SessionStart side: remember this thread's profile (from the hook's own
# environment). Best effort.
agmsg_codex_thread_home_publish() {   # <run_dir> <thread>
  local file home tmp
  file="$(_agmsg_codex_thread_home_file "$1" "$2")" || return 0
  home="$(agmsg_codex_profile_from_env)" || return 0
  mkdir -p "$1" 2>/dev/null || return 0
  tmp="$file.$$"
  printf '%s\n' "$home" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# actas side: the profile the hook published for this thread, if still valid.
agmsg_codex_thread_home_lookup() {   # <run_dir> <thread>
  local file home
  file="$(_agmsg_codex_thread_home_file "$1" "$2")" || return 1
  [ -f "$file" ] || return 1
  IFS= read -r home < "$file" || [ -n "$home" ] || return 1
  agmsg_codex_profile_canonical "$home"
}
