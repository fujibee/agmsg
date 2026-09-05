#!/usr/bin/env bash

# Pure rendering helpers for team.sh. Collection stays in team.sh and the
# terminal drivers; these functions only turn already-observed fields into the
# human-facing compact form.

# Resolve a recorded terminal/pane through the terminal registry's location
# contract. Output is always four TAB-separated, non-empty fields:
# terminal, pane, container, live. The driver's liveness answer is never
# inferred or revised here.
agmsg_team_location() {
  local terminal="$1" pane="$2" location rc=0 container live
  if ! agmsg_terminal_load "$terminal" >/dev/null 2>&1; then
    printf '%s\t%s\tunknown:driver_load_failed\tunknown:driver_load_failed\n' \
      "$terminal" "$pane"
    return 0
  fi
  if ! declare -F agmsg_terminal_location_loaded >/dev/null 2>&1; then
    printf '%s\t%s\tunknown:location_contract_unavailable\tunknown:location_contract_unavailable\n' \
      "$terminal" "$pane"
    return 0
  fi
  location="$(agmsg_terminal_location_loaded "$pane")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\t%s\tunknown:location_contract_rc_%s\tunknown:location_contract_rc_%s\n' \
      "$terminal" "$pane" "$rc" "$rc"
    return 0
  fi
  IFS="$(printf '\t')" read -r container live <<EOF
$location
EOF
  if [ -z "$container" ] || [ -z "$live" ]; then
    printf '%s\t%s\tunknown:location_contract_malformed\tunknown:location_contract_malformed\n' \
      "$terminal" "$pane"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$terminal" "$pane" "$container" "$live"
}

# Optional read extension supplied by terminal drivers that can observe live
# naming state. It prints four TAB-separated raw fields:
# activity, pane label, terminal agent key, CLI terminal title. A driver without
# the extension is observable as unknown, never as a matching empty string.
agmsg_team_observe_loaded() {
  local pane="$1" raw rc=0 activity pane_label agent_key cli_title
  if ! declare -F terminal_team_observe >/dev/null 2>&1; then
    printf 'unknown:observe_unsupported\tunknown:observe_unsupported\tunknown:observe_unsupported\tunknown:observe_unsupported\n'
    return 0
  fi
  raw="$(terminal_team_observe "$pane")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'unknown:observe_rc_%s\tunknown:observe_rc_%s\tunknown:observe_rc_%s\tunknown:observe_rc_%s\n' \
      "$rc" "$rc" "$rc" "$rc"
    return 0
  fi
  IFS="$(printf '\t')" read -r activity pane_label agent_key cli_title <<EOF
$raw
EOF
  if [ -z "$activity" ] || [ -z "$pane_label" ] || [ -z "$agent_key" ] || [ -z "$cli_title" ]; then
    printf 'unknown:observe_malformed\tunknown:observe_malformed\tunknown:observe_malformed\tunknown:observe_malformed\n'
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$activity" "$pane_label" "$agent_key" "$cli_title"
}

agmsg_identity_cell() {
  local expected="$1" actual="$2"
  case "$actual" in
    n/a:*|unknown:*) printf '%s\n' "$actual" ;;
    "$expected") printf 'ok(actual=%s)\n' "$actual" ;;
    *) printf 'mismatch(expected=%s,actual=%s)\n' "$expected" "$actual" ;;
  esac
}

agmsg_identity_consistency() {
  local cell saw_unknown=0
  for cell in "$@"; do
    case "$cell" in
      mismatch\(*) printf 'mismatch\n'; return 0 ;;
      unknown:*) saw_unknown=1 ;;
      ok\(*\)|n/a:*) : ;;
      *) saw_unknown=1 ;;
    esac
  done
  if [ "$saw_unknown" -eq 1 ]; then
    printf 'unverified\n'
  else
    printf 'ok\n'
  fi
}

# Claude prefixes its terminal title with a transient state glyph. Herdr's
# terminal_title_stripped removes terminal control bytes, not that glyph. Strip
# one leading non-ASCII/non-name token and its following spaces; keep ordinary
# text untouched so a real mismatching session name is still diagnosable.
agmsg_cli_session_from_title() {
  local title="$1" first rest
  case "$title" in
    *' '*)
      first="${title%% *}"
      rest="${title#* }"
      case "$first" in
        *[A-Za-z0-9_-]*) : ;;
        *)
          while [ "${rest# }" != "$rest" ]; do rest="${rest# }"; done
          printf '%s\n' "$rest"
          return 0
          ;;
      esac
      ;;
  esac
  printf '%s\n' "$title"
}

_agmsg_team_identity_detail() {
  local field="$1" cell="$2"
  case "$cell" in
    mismatch\(*\)|unknown:*) printf '    %s=%s\n' "$field" "$cell" ;;
  esac
}

agmsg_team_render_human_row() {
  local member="$1" type="$2" project="$3" terminal="$4" pane="$5"
  local container="$6" live="$7" activity="$8" delivery="$9"
  shift 9
  local pane_label="$1" agent_key="$2" cli_session="$3" consistency="$4"

  printf '  %s (%s) — %s   [%s %s @%s live=%s activity=%s delivery=%s identity=%s]\n' \
    "$member" "$type" "$project" "$terminal" "$pane" "$container" \
    "$live" "$activity" "$delivery" "$consistency"
  [ "$consistency" = ok ] && return 0
  _agmsg_team_identity_detail pane_label "$pane_label"
  _agmsg_team_identity_detail agent_key "$agent_key"
  _agmsg_team_identity_detail cli_session "$cli_session"
}
