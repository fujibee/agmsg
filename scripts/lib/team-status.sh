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

# Compare one terminal observation with the naming contract for this
# registration. Output: activity, three identity cells, aggregate consistency.
agmsg_team_identity_loaded() {
  local team="$1" agent="$2" type="$3" terminal="$4" pane="$5"
  local raw activity actual_label actual_key title expected_label expected_key
  local actual_session expected_session pane_cell key_cell session_cell consistency name_arg
  raw="$(agmsg_team_observe_loaded "$pane")"
  IFS="$(printf '\t')" read -r activity actual_label actual_key title <<EOF
$raw
EOF
  expected_label="$team:$agent"
  case "$terminal" in
    herdr)
      if declare -F _herdr_internal_key >/dev/null 2>&1; then
        expected_key="$(_herdr_internal_key "$team" "$agent" 2>/dev/null)" \
          || expected_key=unknown:key_derivation_failed
      else
        expected_key=unknown:key_derivation_unavailable
      fi
      ;;
    tmux) expected_key="$expected_label" ;;
    plain) expected_key=n/a:no_addressable_pane ;;
    *) expected_key=unknown:terminal_key_contract_unknown ;;
  esac
  if [ "${AGMSG_TERMINAL_NAMING:-}" = off ]; then
    actual_label=n/a:disabled_by_policy
    pane_cell=n/a:disabled_by_policy
  else
    pane_cell="$(agmsg_identity_cell "$expected_label" "$actual_label")"
  fi
  case "$expected_key" in
    n/a:*|unknown:*) key_cell="$expected_key" ;;
    *) key_cell="$(agmsg_identity_cell "$expected_key" "$actual_key")" ;;
  esac
  name_arg="$(agmsg_type_get "$type" name_arg 2>/dev/null || true)"
  if [ -z "$name_arg" ]; then
    expected_session=n/a:no_session_name
    actual_session=n/a:no_session_name
    session_cell=n/a:no_session_name
  else
    expected_session="$team-$agent"
    case "$title" in
      n/a:*|unknown:*) actual_session="$title"; session_cell="$title" ;;
      *)
        actual_session="$(agmsg_cli_session_from_title "$title")"
        session_cell="$(agmsg_identity_cell "$expected_session" "$actual_session")"
        ;;
    esac
  fi
  consistency="$(agmsg_identity_consistency "$pane_cell" "$key_cell" "$session_cell")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$activity" "$actual_label" "$expected_label" "$actual_key" "$expected_key" \
    "$actual_session" "$expected_session" \
    "$pane_cell" "$key_cell" "$session_cell" "$consistency"
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

_agmsg_team_json_quote() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/''/g")"
  sqlite3 :memory: "SELECT json_quote('$escaped');"
}

agmsg_team_identity_json() {
  local cell="$1" expected="$2" actual="$3" status reason
  case "$cell" in
    ok\(*\))
      printf '{"status":"ok","actual":%s}' "$(_agmsg_team_json_quote "$actual")"
      ;;
    mismatch\(*\))
      printf '{"status":"mismatch","expected":%s,"actual":%s}' \
        "$(_agmsg_team_json_quote "$expected")" "$(_agmsg_team_json_quote "$actual")"
      ;;
    n/a:*)
      reason="${cell#n/a:}"
      printf '{"status":"n/a","reason":%s}' "$(_agmsg_team_json_quote "$reason")"
      ;;
    unknown:*)
      reason="${cell#unknown:}"
      printf '{"status":"unknown","reason":%s}' "$(_agmsg_team_json_quote "$reason")"
      ;;
    *)
      status=invalid_identity_cell
      printf '{"status":"unknown","reason":%s}' "$(_agmsg_team_json_quote "$status")"
      ;;
  esac
}

agmsg_team_render_json_row() {
  local member="$1" type="$2" project="$3" terminal="$4" pane="$5"
  local container="$6" live="$7" activity="$8" delivery="$9"
  shift 9
  local label_cell="$1" label_expected="$2" label_actual="$3"
  local key_cell="$4" key_expected="$5" key_actual="$6"
  local session_cell="$7" session_expected="$8" session_actual="$9"
  shift 9
  local consistency="$1"
  printf '{"member":%s,"type":%s,"project":%s,"terminal":%s,"pane":%s,"container":%s,"live":%s,"activity":%s,"delivery":%s,"pane_label":%s,"agent_key":%s,"cli_session":%s,"consistency":%s}' \
    "$(_agmsg_team_json_quote "$member")" "$(_agmsg_team_json_quote "$type")" \
    "$(_agmsg_team_json_quote "$project")" "$(_agmsg_team_json_quote "$terminal")" \
    "$(_agmsg_team_json_quote "$pane")" "$(_agmsg_team_json_quote "$container")" \
    "$(_agmsg_team_json_quote "$live")" "$(_agmsg_team_json_quote "$activity")" \
    "$(_agmsg_team_json_quote "$delivery")" \
    "$(agmsg_team_identity_json "$label_cell" "$label_expected" "$label_actual")" \
    "$(agmsg_team_identity_json "$key_cell" "$key_expected" "$key_actual")" \
    "$(agmsg_team_identity_json "$session_cell" "$session_expected" "$session_actual")" \
    "$(_agmsg_team_json_quote "$consistency")"
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
