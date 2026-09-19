#!/usr/bin/env bash

# Collection, comparison, repair, and rendering helpers for team.sh. Terminal-
# specific observation and readiness proofs stay in the drivers; this layer
# joins them into one backend-neutral roster status.

# Which of peek/poke/arrange this session can actually use against a resolved
# (terminal, pane) -- not merely which verbs the driver's MANIFEST advertises
# (terminal.conf's capabilities=, the implementation ceiling), and not a guess
# from whether the caller happens to share the target's terminal instance.
#
# Two signals, in this priority:
#
#  1. terminal_capability <verb> <id> (#1163) -- an OPTIONAL per-driver hook
#     that narrows the manifest ceiling for ONE runtime instance: 0 supported,
#     1 unsupported, 2 unknown. When a driver defines it, it is authoritative:
#     plain's peek/poke need an emulator-qualified id (plain:<emulator>:<tty>);
#     a bare plain:- placement is 13/unsupported for both, even though plain's
#     own manifest lists them. Plain's location probe (terminal_where) cannot
#     tell that difference -- it is UNCONDITIONALLY unsupported for every
#     plain id, qualified or not, because plain has no container concept at
#     all -- so falling back to the location probe here would report every
#     plain member as unreachable regardless of whether it actually is.
#
#  2. For a driver with no such hook (herdr, tmux today), the CALLER's own
#     location probe already ran (agmsg_team_location, called once per member
#     by team.sh before this) and is a genuine per-target reachability check:
#     each driver's terminal_where targets THAT id's own recorded socket
#     (HERDR_SOCKET_PATH / tmux -S), not the caller's -- so its outcome
#     stands as the answer, and the manifest ceiling is not narrowed further.
#
# Args: <terminal> <pane> <location_ok 0|1> <location_reason>
#   location_ok/location_reason are what team.sh already computed from
#   agmsg_team_location's container field -- passed in rather than re-probed,
#   so a driver without terminal_capability costs no second round-trip per
#   member.
#
# Output: one line, "<status> <detail>"
#   can <space-separated ops>   -- at least one op usable now
#   cannot <reason>             -- structurally unsupported (the rc-13 class:
#                                  a fact about this placement's SHAPE, not a
#                                  moment-in-time failure to reach it)
#   unknown <reason>            -- could not be verified (any other failure:
#                                  a transient/indeterminate reachability
#                                  problem, never conflated with "cannot")
agmsg_team_reach() {
  local terminal="$1" pane="$2" location_ok="$3" location_reason="$4"
  local caps op rc why has_hook=0
  local can_ops="" any_cannot=0 any_unknown=0 cannot_reason="" unknown_reason=""

  # agmsg_terminal_get itself never fails (an unknown terminal, or a manifest
  # it cannot read, degrades silently to its default, empty here) -- so an
  # empty caps read through it cannot distinguish "the manifest is real,
  # readable, and simply doesn't declare these ops" (cannot) from "the
  # manifest could not be established at all" (unknown, not the same claim).
  #
  # agmsg_terminal_dir alone is NOT enough to tell them apart: it only checks
  # that terminal.conf exists (-f) and passes the trust gate, never that its
  # CONTENT is readable. agmsg_terminal_get's own grep swallows a real read
  # failure (permission denied, a transient I/O error) into the same empty
  # result as "the key is simply absent" via `2>/dev/null || true` -- so a
  # manifest that exists but cannot be READ would pass agmsg_terminal_dir and
  # still land on the wrong (cannot) verdict without a direct check here.
  local tdir=""
  if ! tdir="$(agmsg_terminal_dir "$terminal" 2>/dev/null)" || [ ! -r "$tdir/terminal.conf" ]; then
    printf 'unknown %s\n' "terminal_manifest_unreadable"
    return 0
  fi
  caps="$(agmsg_terminal_get "$terminal" capabilities 2>/dev/null)" || caps=""
  declare -F terminal_capability >/dev/null 2>&1 && has_hook=1

  if [ "$has_hook" -ne 1 ] && [ "$location_ok" -ne 1 ]; then
    # No per-instance hook, and the one real reachability probe this driver
    # gets (location) already failed -- nothing left to narrow.
    case "$location_reason" in
      *_rc_13|unsupported) printf 'cannot %s\n' "${location_reason:-unreachable}" ;;
      *)                   printf 'unknown %s\n' "${location_reason:-unreachable}" ;;
    esac
    return 0
  fi

  for op in peek poke arrange; do
    case " $caps " in *" $op "*) ;; *) continue ;; esac
    if [ "$has_hook" -eq 1 ]; then
      rc=0
      why="$(terminal_capability "$op" "$pane" 2>&1 >/dev/null)" || rc=$?
      case "$rc" in
        0) can_ops="${can_ops:+$can_ops }$op" ;;
        # Two separate reasons, never merged into one "first wins" slot
        # a mixed peek=cannot/arrange=unknown result must not
        # let the unknown branch below print the cannot op's reason, or the
        # unsupported-shape claim survives into an indeterminate verdict.
        1) any_cannot=1;  [ -n "$cannot_reason" ]  || cannot_reason="${why#unsupported: }" ;;
        *) any_unknown=1; [ -n "$unknown_reason" ] || unknown_reason="${why:-terminal_capability_rc_$rc}" ;;
      esac
    else
      can_ops="${can_ops:+$can_ops }$op"
    fi
  done

  if [ -n "$can_ops" ]; then
    printf 'can %s\n' "$can_ops"
  elif [ "$any_unknown" -eq 1 ]; then
    printf 'unknown %s\n' "${unknown_reason:-could_not_verify}"
  elif [ "$any_cannot" -eq 1 ]; then
    printf 'cannot %s\n' "${cannot_reason:-unsupported}"
  else
    printf 'cannot %s\n' "driver_does_not_support_these_ops"
  fi
}

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
  local actual_session expected_session pane_cell key_cell session_cell consistency session_src
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
  # The session name is judged only when the type says how it can be OBSERVED
  # (session_name_source), not by whether it has a launch flag (#1081): codex has
  # no name_arg yet its name is readable early from the TUI header, so it must be
  # judged too. A type with no source has no observable name (n/a). A source that
  # cannot be read right now (TUI header scrolled off, screen unreadable) yields
  # unknown, NOT mismatch -- unobservable is never "wrong".
  session_src="$(_agmsg_cli_session_source "$type")"
  if [ -z "$session_src" ]; then
    expected_session=n/a:no_session_name
    actual_session=n/a:no_session_name
    session_cell=n/a:no_session_name
  else
    expected_session="$team-$agent"
    actual_session="$(agmsg_cli_session_observed "$type" "$title" "$pane")"
    case "$actual_session" in
      n/a:*|unknown:*) session_cell="$actual_session" ;;
      *) session_cell="$(agmsg_identity_cell "$expected_session" "$actual_session")" ;;
    esac
  fi
  consistency="$(agmsg_identity_consistency "$pane_cell" "$key_cell" "$session_cell")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$activity" "$actual_label" "$expected_label" "$actual_key" "$expected_key" \
    "$actual_session" "$expected_session" \
    "$pane_cell" "$key_cell" "$session_cell" "$consistency"
}

agmsg_identity_consistency() {
  local cell saw_unknown=0 saw_match=0
  for cell in "$@"; do
    case "$cell" in
      mismatch\(*) printf 'mismatch\n'; return 0 ;;
      unknown:*) saw_unknown=1 ;;
      ok\(*\)) saw_match=1 ;;
      n/a:*) : ;;
      *) saw_unknown=1 ;;
    esac
  done
  if [ "$saw_unknown" -eq 1 ]; then
    printf 'unverified\n'
  elif [ "$saw_match" -eq 0 ]; then
    printf 'n/a\n'
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

# Observe a type's CLI session name from OUTSIDE, per its `session_name_source`
# manifest datum (#1081). One shared reader for both the cli_session cell and the
# rename readback, so the two cannot disagree about what the name is.
#   <title> the terminal title already observed for this pane (used by `title`)
#   <pane>  the bare pane id (used by `screen:` to peek)
# Prints the observed name, or a namespaced `unknown:<why>` / `n/a:<why>`.
#
# UNOBSERVABLE IS UNKNOWN, NEVER FAILURE. A type whose name lives only in a TUI
# header that has scrolled off cannot be judged wrong, and a changed TUI layout
# must read as "could not confirm", not "rename failed". Only a name we actually
# read and that differs is a mismatch; anything we could not read is unknown.
#   title           -> agmsg_cli_session_from_title of the terminal title
#   screen:<prefix> -> peek the pane, take ONLY the line beginning with <prefix>,
#                      and only its text after the prefix. The rest of the screen
#                      is another process's output: reported, never trusted (the
#                      peek posture SKILL.md states), so nothing else is read.
#   (absent)        -> n/a:no_session_name (no observable name; not renamable)
# The observation source for a type, resolved once: its session_name_source, or
# `title` when it has a launch name flag (name_arg) but no explicit source -- a
# name_arg type has always been read from the terminal title, so that stays true
# without every such manifest having to also spell out session_name_source.
_agmsg_cli_session_source() {   # <type>
  local s; s="$(agmsg_type_get "$1" session_name_source 2>/dev/null || true)"
  if [ -z "$s" ] && [ -n "$(agmsg_type_get "$1" name_arg 2>/dev/null || true)" ]; then
    s=title
  fi
  printf '%s\n' "$s"
}

agmsg_cli_session_observed() {   # <type> <title> <pane>
  local type="$1" title="$2" pane="$3" src prefix screen line name rc=0
  src="$(_agmsg_cli_session_source "$type")"
  case "$src" in
    "") printf 'n/a:no_session_name\n' ;;
    title)
      case "$title" in
        n/a:*|unknown:*) printf '%s\n' "$title" ;;
        *) agmsg_cli_session_from_title "$title" ;;
      esac
      ;;
    screen:*)
      prefix="${src#screen:}"
      screen="$(terminal_peek "$pane" 2>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ] || { printf 'unknown:screen_unreadable\n'; return 0; }
      # ONLY a line that BEGINS with the prefix -- the header, not a phrase that
      # merely appears somewhere in the conversation. `index($0,p)==1` is a
      # literal, line-start match (grep -F would accept "... Thread name: x" and
      # read the rest of an unrelated line as the name, #1102 review). First such
      # line wins; the rest of the screen is not judged.
      line="$(printf '%s\n' "$screen" | awk -v p="$prefix" 'index($0,p)==1 { print; exit }')"
      [ -n "$line" ] || { printf 'unknown:name_not_visible\n'; return 0; }
      name="${line#"$prefix"}"
      while [ "${name# }" != "$name" ]; do name="${name# }"; done      # lead ws
      while [ "${name% }" != "$name" ]; do name="${name% }"; done      # trail ws
      [ -n "$name" ] || { printf 'unknown:name_not_visible\n'; return 0; }
      # The header line is real, but everything after the prefix is still screen
      # text (#1102 review). A session name is short and has no control bytes;
      # anything else is not a name we can trust to compare or mark, so it reads
      # malformed rather than being passed through. A TAB especially would corrupt
      # the TAB-separated records this feeds.
      case "$name" in *[[:cntrl:]]*) printf 'unknown:name_malformed\n'; return 0 ;; esac
      [ "${#name}" -le 128 ] || { printf 'unknown:name_malformed\n'; return 0; }
      printf '%s\n' "$name"
      ;;
    *) printf 'unknown:session_name_source_unrecognized\n' ;;
  esac
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

# reach_status/reach_detail -> {"status":"can","ops":["peek","poke"]} |
# {"status":"cannot","reason":"..."} | {"status":"unknown","reason":"..."}
_agmsg_team_reach_json() {
  local status="$1" detail="$2" op first=1 out=""
  case "$status" in
    can)
      out='['
      for op in $detail; do
        [ "$first" -eq 1 ] || out="$out,"
        first=0
        out="$out$(_agmsg_team_json_quote "$op")"
      done
      out="$out]"
      printf '{"status":"can","ops":%s}' "$out"
      ;;
    cannot|unknown)
      printf '{"status":%s,"reason":%s}' "$(_agmsg_team_json_quote "$status")" "$(_agmsg_team_json_quote "$detail")"
      ;;
    *)
      printf '{"status":"unknown","reason":%s}' "$(_agmsg_team_json_quote "invalid_reach_status_$status")"
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
  local consistency="$1" reach_status="$2" reach_detail="$3" tool="${4:-}"
  # "tool" is the one field this row format has grown since #1284: null for
  # every existing type, the ext-tool name (e.g. "slack") for an ext-tool
  # registration. Every other key here is unchanged in name, meaning, and
  # position -- an existing reader that only looks at known keys sees no
  # difference.
  printf '{"member":%s,"type":%s,"project":%s,"terminal":%s,"pane":%s,"container":%s,"activity":%s,"delivery":%s,"pane_label":%s,"agent_key":%s,"cli_session":%s,"consistency":%s,"reach":%s,"tool":%s}' \
    "$(_agmsg_team_json_quote "$member")" "$(_agmsg_team_json_quote "$type")" \
    "$(_agmsg_team_json_quote "$project")" "$(_agmsg_team_json_quote "$terminal")" \
    "$(_agmsg_team_json_quote "$pane")" "$(_agmsg_team_json_quote "$container")" \
    "$(_agmsg_team_json_quote "$activity")" \
    "$(_agmsg_team_json_quote "$delivery")" \
    "$(agmsg_team_identity_json "$label_cell" "$label_expected" "$label_actual")" \
    "$(agmsg_team_identity_json "$key_cell" "$key_expected" "$key_actual")" \
    "$(agmsg_team_identity_json "$session_cell" "$session_expected" "$session_actual")" \
    "$(_agmsg_team_json_quote "$consistency")" \
    "$(_agmsg_team_reach_json "$reach_status" "$reach_detail")" \
    "$([ -n "$tool" ] && _agmsg_team_json_quote "$tool" || printf 'null')"
}

agmsg_team_render_human_row() {
  local member="$1" type="$2" project="$3" terminal="$4" pane="$5"
  local container="$6" activity="$7" delivery="$8"
  shift 8
  local pane_label="$1" agent_key="$2" cli_session="$3" consistency="$4"
  local reach_status="$5" reach_detail="$6" tool="${7:-}" reach_summary type_display
  case "$reach_status" in
    can) reach_summary="can:${reach_detail// /,}" ;;
    *)   reach_summary="$reach_status:$reach_detail" ;;
  esac
  type_display="$type"
  [ -n "$tool" ] && type_display="$type ($tool)"

  printf '  %s (%s) — %s   [%s %s @%s activity=%s delivery=%s identity=%s reach=%s]\n' \
    "$member" "$type_display" "$project" "$terminal" "$pane" "$container" \
    "$activity" "$delivery" "$consistency" "$reach_summary"
  [ "$consistency" = ok ] && return 0
  _agmsg_team_identity_detail pane_label "$pane_label"
  _agmsg_team_identity_detail agent_key "$agent_key"
  _agmsg_team_identity_detail cli_session "$cli_session"
}
