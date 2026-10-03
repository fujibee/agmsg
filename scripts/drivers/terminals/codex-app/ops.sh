#!/usr/bin/env bash
# Sourced terminal ABI; no shell option changes or process inspection.
# Measured in a desktop conversation shell on 2026-10-03: originator is
# exactly "Codex Desktop", THREAD_ID is present, and ps is sandbox-denied.
# The app-server itself carries "Codex", which is not the shell marker.

terminal_check() { echo ok; return 0; }
terminal_describe() {
  printf 'name=codex-app\nbackend=Codex desktop app\ncapabilities=where\n'
}

terminal_id_ok() {
  [ -n "$1" ] || return 1
  case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  return 0
}

terminal_detect() {
  local sid="${1:-${CODEX_THREAD_ID:-}}"
  [ "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" = 'Codex Desktop' ] || return 1
  if terminal_id_ok "$sid"; then
    printf '%s\n' "$sid"
  else
    echo 'codex-app: no usable thread id (caller argument or CODEX_THREAD_ID) — cannot identify this desktop conversation' >&2
  fi
  return 0
}

terminal_self_env() {
  local sid="${1:-${CODEX_THREAD_ID:-}}"
  if [ "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" != 'Codex Desktop' ]; then
    printf 'n/a:not_in_terminal\n'
  elif ! terminal_id_ok "$sid"; then
    printf 'unknown:codex_app_thread_id_unset_or_malformed\n'
  else
    printf '%s\n' "$sid"
  fi
}

terminal_epoch() { printf 'n/a:no_generation\n'; }
terminal_where() { printf 'n/a:no_container_concept\n'; }
terminal_pane_state() {
  echo unknown
  echo 'unsupported: codex-app is the Codex desktop app, which has no addressable pane' >&2
  return 13
}

_codex_app_unsupported() {
  printf 'unsupported: codex-app does not implement %s — the Codex desktop app has no addressable pane\n' "$1" >&2
  return 13
}
terminal_spawn() { _codex_app_unsupported spawn; }
terminal_despawn() { _codex_app_unsupported despawn; }
terminal_peek() { _codex_app_unsupported peek; }
terminal_poke() { _codex_app_unsupported poke; }
terminal_arrange() { _codex_app_unsupported arrange; }
terminal_name() { _codex_app_unsupported name; }
terminal_expected_label() { printf 'n/a:no_addressable_pane\n'; }
terminal_team_observe() {
  printf 'n/a:no_addressable_pane\tn/a:no_addressable_pane\tn/a:no_addressable_pane\tn/a:no_addressable_pane\n'
}
