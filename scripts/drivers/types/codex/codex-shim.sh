#!/usr/bin/env bash
set -euo pipefail

# Optional Codex entrypoint shim for agmsg monitor mode.
#
# Install this as ~/.agents/bin/codex before the real Codex binary on PATH.
# In projects whose Codex delivery mode is `monitor`, interactive Codex TUI
# launches are routed through codex-monitor.sh. Everything else is passed
# through to the real Codex command unchanged.

if [ "${AGMSG_CODEX_SHIM_WRAPPER:-}" = "1" ] && [ -n "${AGMSG_CODEX_SHIM_SCRIPT_DIR:-}" ]; then
  SCRIPT_DIR="$AGMSG_CODEX_SHIM_SCRIPT_DIR"
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

is_agmsg_wrapper() {
  [ -f "$1" ] && grep -q "Optional Codex entrypoint shim for agmsg monitor mode" "$1" 2>/dev/null
}

resolve_real_codex() {
  if [ -n "${AGMSG_REAL_CODEX:-}" ]; then
    printf '%s\n' "$AGMSG_REAL_CODEX"
    return 0
  fi

  local self_dir self_path shim_target path_dir candidate candidate_dir candidate_path
  self_dir="$(cd "$(dirname "$0")" && pwd)"
  self_path="$self_dir/$(basename "$0")"
  shim_target="${AGMSG_CODEX_SHIM_TARGET:-}"

  local old_ifs="$IFS"
  IFS=:
  for path_dir in $PATH; do
    IFS="$old_ifs"
    [ -n "$path_dir" ] || path_dir="."
    candidate="$path_dir/codex"
    if [ -x "$candidate" ]; then
      candidate_dir="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd || true)"
      [ -n "$candidate_dir" ] || continue
      candidate_path="$candidate_dir/$(basename "$candidate")"
      if [ "$candidate_path" != "$self_path" ] \
        && [ "$candidate_path" != "$shim_target" ] \
        && ! is_agmsg_wrapper "$candidate_path"; then
        printf '%s\n' "$candidate_path"
        return 0
      fi
    fi
    IFS=:
  done
  IFS="$old_ifs"

  echo "agmsg codex shim: real codex not found on PATH" >&2
  return 1
}

project_from_args() {
  local project="$PWD"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cd|--cwd|-C)
        if [ "$#" -gt 1 ]; then
          project="$2"
          shift 2
          continue
        fi
        ;;
      --cd=*|--cwd=*)
        project="${1#*=}"
        shift
        continue
        ;;
    esac
    shift
  done

  if [ -d "$project" ]; then
    (cd "$project" && pwd)
  else
    printf '%s\n' "$PWD"
  fi
}

first_non_option() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cd|--cwd|-C)
        shift 2 || true
        ;;
      --cd=*|--cwd=*)
        shift
        ;;
      --help|--version|-h|-V)
        printf '%s\n' "$1"
        return 0
        ;;
      --*)
        shift
        ;;
      -*)
        shift
        ;;
      *)
        printf '%s\n' "$1"
        return 0
        ;;
    esac
  done
  return 1
}

is_monitor_project() {
  local project="$1"
  local status
  status="$("$SCRIPT_DIR/../../../delivery.sh" status codex "$project" 2>/dev/null || true)"
  printf '%s\n' "$status" | grep -qx "mode: monitor"
}

real_codex="$(resolve_real_codex)"

if [ "${AGMSG_CODEX_SHIM_DISABLE:-}" = "1" ] || [ "${AGMSG_CODEX_BRIDGE:-}" = "1" ]; then
  exec "$real_codex" "$@"
fi

project="$(project_from_args "$@")"
command_name="$(first_non_option "$@" || true)"

if ! is_monitor_project "$project"; then
  exec "$real_codex" "$@"
fi

monitor_cmd="${AGMSG_CODEX_MONITOR_CMD:-$SCRIPT_DIR/codex-monitor.sh}"

case "$command_name" in
  "")
    AGMSG_REAL_CODEX="$real_codex" exec "$monitor_cmd" --project "$project" --codex-command codex --
    ;;
  resume)
    monitor_args=()
    removed_resume=0
    for arg in "$@"; do
      if [ "$removed_resume" -eq 0 ] && [ "$arg" = "resume" ]; then
        removed_resume=1
        continue
      fi
      monitor_args+=("$arg")
    done
    if [ "${#monitor_args[@]}" -gt 0 ]; then
      AGMSG_REAL_CODEX="$real_codex" exec "$monitor_cmd" --project "$project" --codex-command resume -- "${monitor_args[@]}"
    else
      AGMSG_REAL_CODEX="$real_codex" exec "$monitor_cmd" --project "$project" --codex-command resume --
    fi
    ;;
  app-server|exec|login|logout|mcp|completion|debug|apply|review|sandbox|help|--help|-h|version|--version|-V)
    exec "$real_codex" "$@"
    ;;
  *)
    AGMSG_REAL_CODEX="$real_codex" exec "$monitor_cmd" --project "$project" --codex-command codex -- "$@"
    ;;
esac
