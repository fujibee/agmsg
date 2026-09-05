#!/usr/bin/env bash

# Pure rendering helpers for team.sh. Collection stays in team.sh and the
# terminal drivers; these functions only turn already-observed fields into the
# human-facing compact form.

# Resolve a recorded terminal/pane through the terminal driver's location read.
# Output is always three TAB-separated, non-empty fields: terminal, pane, and
# container. Liveness is deliberately absent until the pane-state contract
# lands; an unavailable column is not rendered as if it were an observation.
agmsg_team_location() {
  local terminal="$1" pane="$2" container rc=0
  if ! agmsg_terminal_load "$terminal" >/dev/null 2>&1; then
    printf '%s\t%s\tunknown:driver_load_failed\n' "$terminal" "$pane"
    return 0
  fi
  if ! declare -F terminal_where >/dev/null 2>&1; then
    printf '%s\t%s\tunknown:location_unsupported\n' "$terminal" "$pane"
    return 0
  fi
  container="$(terminal_where "$pane")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\t%s\tunknown:location_rc_%s\n' "$terminal" "$pane" "$rc"
    return 0
  fi
  if [ -z "$container" ]; then
    printf '%s\t%s\tunknown:location_malformed\n' "$terminal" "$pane"
    return 0
  fi
  case "$container" in *$'\t'*|*$'\n'*|*$'\r'*) container=unknown:location_malformed ;; esac
  printf '%s\t%s\t%s\n' "$terminal" "$pane" "$container"
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

# Normalize a driver's three-valued positive readiness proof. Output is
# "ready|not_ready|unknown<TAB>reason" and always returns zero so a diagnostic
# roster survives a terminal failure.
agmsg_team_input_ready_loaded() {
  local type="$1" pane="$2" cli raw rc=0 state reason
  cli="$(agmsg_type_get "$type" cli 2>/dev/null || true)"
  if [ -z "$cli" ]; then
    printf 'unknown\ttype_cli_unavailable\n'
    return 0
  fi
  if ! declare -F terminal_team_input_ready >/dev/null 2>&1; then
    printf 'unknown\treadiness_unsupported\n'
    return 0
  fi
  raw="$(terminal_team_input_ready "$pane" "$cli")" || rc=$?
  case "$rc" in
    0) state=ready ;;
    1) state=not_ready ;;
    *) state=unknown ;;
  esac
  case "$raw" in
    ready) reason=positive_agent_identity ;;
    not_ready:*) reason="${raw#not_ready:}" ;;
    unknown:*) reason="${raw#unknown:}" ;;
    *) state=unknown; reason=readiness_response_malformed ;;
  esac
  printf '%s\t%s\n' "$state" "$reason"
}

_agmsg_team_fix_result() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

_agmsg_team_identity_field_loaded() {
  local field="$1"; shift
  local identity _activity _al _el _ak _ek _as _es pane_cell key_cell session_cell _consistency
  identity="$(agmsg_team_identity_loaded "$@")"
  IFS="$(printf '\t')" read -r _activity _al _el _ak _ek _as _es pane_cell key_cell session_cell _consistency <<EOF
$identity
EOF
  case "$field" in
    pane_label) printf '%s\n' "$pane_cell" ;;
    agent_key) printf '%s\n' "$key_cell" ;;
    cli_session) printf '%s\n' "$session_cell" ;;
    *) printf 'unknown:invalid_identity_field\n' ;;
  esac
}

# Repair the independently writable identity fields for a live registration.
# Each field gets an explicit changed/skipped/failed action; no write is
# attempted unless its observed cell is a mismatch, and CLI input additionally
# requires a positive readiness proof.
agmsg_team_fix_identity_loaded() {
  local team="$1" agent="$2" type="$3" terminal="$4" pane="$5"
  local pane_cell="$6" key_cell="$7" session_cell="$8"
  local expected_session="$team-$agent" readiness state reason rc=0 observed title tries

  case "$pane_cell" in
    mismatch\(*)
      if [ "$terminal" != herdr ]; then
        _agmsg_team_fix_result pane_label skipped no_independent_field
      elif [ "${AGMSG_TERMINAL_NAMING:-}" = off ]; then
        _agmsg_team_fix_result pane_label skipped disabled_by_policy
      else
        terminal_name "$pane" "$team" "$agent" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 0 ] && case "$(_agmsg_team_identity_field_loaded pane_label "$team" "$agent" "$type" "$terminal" "$pane")" in ok\(*) true ;; *) false ;; esac; then
          _agmsg_team_fix_result pane_label changed renamed_and_verified
        else
          if [ "$rc" -eq 0 ]; then reason=rename_not_observed; else reason="terminal_name_rc_$rc"; fi
          _agmsg_team_fix_result pane_label failed "$reason"
        fi
      fi
      ;;
    ok\(*) _agmsg_team_fix_result pane_label skipped already_matches ;;
    n/a:*) _agmsg_team_fix_result pane_label skipped "${pane_cell#n/a:}" ;;
    *) _agmsg_team_fix_result pane_label skipped "${pane_cell#unknown:}" ;;
  esac

  rc=0
  case "$key_cell" in
    mismatch\(*)
      terminal_name "$pane" "$team" "$agent" key >/dev/null 2>&1 || rc=$?
      if [ "$rc" -eq 0 ] && case "$(_agmsg_team_identity_field_loaded agent_key "$team" "$agent" "$type" "$terminal" "$pane")" in ok\(*) true ;; *) false ;; esac; then
        _agmsg_team_fix_result agent_key changed renamed_and_verified
      else
        if [ "$rc" -eq 0 ]; then reason=rename_not_observed; else reason="terminal_name_rc_$rc"; fi
        _agmsg_team_fix_result agent_key failed "$reason"
      fi
      ;;
    ok\(*) _agmsg_team_fix_result agent_key skipped already_matches ;;
    n/a:*) _agmsg_team_fix_result agent_key skipped "${key_cell#n/a:}" ;;
    *) _agmsg_team_fix_result agent_key skipped "${key_cell#unknown:}" ;;
  esac

  case "$session_cell" in
    mismatch\(*)
      if [ "$type" != claude-code ]; then
        _agmsg_team_fix_result cli_session skipped rename_unsupported
        return 0
      fi
      readiness="$(agmsg_team_input_ready_loaded "$type" "$pane")"
      IFS="$(printf '\t')" read -r state reason <<EOF
$readiness
EOF
      if [ "$state" != ready ]; then
        _agmsg_team_fix_result cli_session skipped "${state}_$reason"
        return 0
      fi
      rc=0
      terminal_poke "$pane" "/rename $expected_session" >/dev/null 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        _agmsg_team_fix_result cli_session failed "terminal_poke_rc_$rc"
        return 0
      fi
      tries=0
      while [ "$tries" -lt 20 ]; do
        observed="$(agmsg_team_observe_loaded "$pane")"
        IFS="$(printf '\t')" read -r _ _ _ title <<EOF
$observed
EOF
        case "$title" in
          n/a:*|unknown:*) : ;;
          *) [ "$(agmsg_cli_session_from_title "$title")" = "$expected_session" ] \
               && { _agmsg_team_fix_result cli_session changed renamed_and_verified; return 0; } ;;
        esac
        sleep 0.1 2>/dev/null || true
        tries=$((tries + 1))
      done
      _agmsg_team_fix_result cli_session failed rename_not_observed
      ;;
    ok\(*) _agmsg_team_fix_result cli_session skipped already_matches ;;
    n/a:*) _agmsg_team_fix_result cli_session skipped "${session_cell#n/a:}" ;;
    *) _agmsg_team_fix_result cli_session skipped "${session_cell#unknown:}" ;;
  esac
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
  local container="$6" activity="$7" delivery="$8"
  shift 8
  local label_cell="$1" label_expected="$2" label_actual="$3"
  local key_cell="$4" key_expected="$5" key_actual="$6"
  local session_cell="$7" session_expected="$8" session_actual="$9"
  shift 9
  local consistency="$1"
  printf '{"member":%s,"type":%s,"project":%s,"terminal":%s,"pane":%s,"container":%s,"activity":%s,"delivery":%s,"pane_label":%s,"agent_key":%s,"cli_session":%s,"consistency":%s}' \
    "$(_agmsg_team_json_quote "$member")" "$(_agmsg_team_json_quote "$type")" \
    "$(_agmsg_team_json_quote "$project")" "$(_agmsg_team_json_quote "$terminal")" \
    "$(_agmsg_team_json_quote "$pane")" "$(_agmsg_team_json_quote "$container")" \
    "$(_agmsg_team_json_quote "$activity")" \
    "$(_agmsg_team_json_quote "$delivery")" \
    "$(agmsg_team_identity_json "$label_cell" "$label_expected" "$label_actual")" \
    "$(agmsg_team_identity_json "$key_cell" "$key_expected" "$key_actual")" \
    "$(agmsg_team_identity_json "$session_cell" "$session_expected" "$session_actual")" \
    "$(_agmsg_team_json_quote "$consistency")"
}

agmsg_team_render_human_row() {
  local member="$1" type="$2" project="$3" terminal="$4" pane="$5"
  local container="$6" activity="$7" delivery="$8"
  shift 8
  local pane_label="$1" agent_key="$2" cli_session="$3" consistency="$4"

  printf '  %s (%s) — %s   [%s %s @%s activity=%s delivery=%s identity=%s]\n' \
    "$member" "$type" "$project" "$terminal" "$pane" "$container" \
    "$activity" "$delivery" "$consistency"
  [ "$consistency" = ok ] && return 0
  _agmsg_team_identity_detail pane_label "$pane_label"
  _agmsg_team_identity_detail agent_key "$agent_key"
  _agmsg_team_identity_detail cli_session "$cli_session"
}
