#!/usr/bin/env bash

# Collection, comparison, repair, and rendering helpers for team.sh. Terminal-
# specific observation and readiness proofs stay in the drivers; this layer
# joins them into one backend-neutral roster status.

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

# #1131: the placement record is a CLAIM about which pane a seat lives in, not a
# guaranteed address. A record can point at ANOTHER seat's pane -- codex's commands
# run under a shared app-server, so its environment reports the daemon's pane and
# the record is written for a pane the seat does not live in (measured on live
# seats: the environment named a pane a DIFFERENT seat was sitting in). Acting on
# that pane would overwrite the other seat's label -- --fix would break the correct
# row to match the wrong one. So before --fix trusts the record's pane, verify it
# against an
# environment-INDEPENDENT source: the pane whose label is <team>:<agent>, when
# exactly one carries it (_agmsg_terminal_resolve_by_label, #1112). If the label
# settles on a pane that DISAGREES with the record, the record is wrong -- rewrite
# the RECORD (never the other seat's pane) and hand back the verified ref so the
# caller acts on the real pane.
#
# When the label cannot settle it -- zero matches (a seat that never named itself)
# or more than one -- the record is kept as-is: no worse than today. A seat with no
# distinguishing label needs a different source entirely -- asking the seat to emit
# a token and seeing which pane it lands in (the #1124 route) -- which is
# deliberately out of scope for this change.
#
#   agmsg_team_verify_placement <team> <agent> <rec-path> <ref> <project> <type>
#     -> prints the ref to act on (verified/corrected, or the original), rc 0.
agmsg_team_verify_placement() {
  local team="$1" agent="$2" rec="$3" ref="$4" project="$5" type="$6"
  local verified v_terminal v_id v_ref tab
  declare -F _agmsg_terminal_resolve_by_label >/dev/null 2>&1 || { printf '%s\n' "$ref"; return 0; }
  verified="$(_agmsg_terminal_resolve_by_label "$team" "$agent" 2>/dev/null)" || verified=""
  [ -n "$verified" ] || { printf '%s\n' "$ref"; return 0; }
  tab="$(printf '\t')"
  v_terminal="${verified%%"$tab"*}"; v_id="${verified#*"$tab"}"
  [ -n "$v_terminal" ] && [ -n "$v_id" ] || { printf '%s\n' "$ref"; return 0; }
  v_ref="$(agmsg_terminal_ref "$v_terminal" "$v_id" 2>/dev/null)" || v_ref=""
  [ -n "$v_ref" ] || { printf '%s\n' "$ref"; return 0; }
  if [ "$v_ref" = "$ref" ]; then
    printf '%s\n' "$ref"; return 0            # the record already names the seat's pane
  fi
  # The record names a pane the label says is not this seat's. Correct the RECORD,
  # atomically (a failed write must not truncate the record it was going to fix),
  # and act on the pane the label found -- never the other seat's.
  if declare -F agmsg_write_atomic >/dev/null 2>&1; then
    agmsg_write_atomic "$rec" "$(printf '%s\t%s\t%s' "$v_ref" "$project" "$type")" 2>/dev/null || true
  fi
  printf '%s\n' "$v_ref"
  return 0
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
#
# Two halves, because they are two kinds of act (#1110): the pane names (label
# and key) are attributes written through the terminal's own API; the CLI
# session name is repaired by TYPING a rename command into the pane. The halves
# are separable work and a caller may want only one -- so each is its own
# function, and `agmsg_team_fix_identity_loaded` is their union. The pane-names
# half never calls terminal_poke; that is its contract, not an accident of the
# cells it is handed.

# <team> <agent> <type> <terminal> <pane> <pane_cell> <key_cell>
#   -> pane_label and agent_key actions. Never types into the pane.
agmsg_team_fix_pane_names_loaded() {
  local team="$1" agent="$2" type="$3" terminal="$4" pane="$5"
  local pane_cell="$6" key_cell="$7"
  local reason rc=0

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
}

# Count the confirmation lines "<confirm_prefix> <expected>." currently visible in
# a pane's scrollback. Used only by a rename_confirm type (codex): the line
# PERSISTS after a rename and `--fix` runs repeatedly (and a person may have typed
# /rename by hand), so a later run must not read an EARLIER line as its own. The
# caller counts before and after its keystroke and requires an INCREASE; the
# expected name is the same every run, so newness -- not the name -- is the only
# thing that separates this rename from a prior one. An unreadable pane fails
# (rc 1, no output) rather than reading as 0 -- see the read-failure note below.
_agmsg_rename_confirm_count() {   # <pane> <confirm_prefix> <expected>
  local screen
  # Ask for a generous window so a pre-existing line is captured too. The shipped
  # pane drivers pass this depth to their backends, but it remains a request rather
  # than a guarantee about an external driver's buffer. It does not need to be a
  # guarantee: before and after read the SAME window on the SAME driver, so the count
  # DELTA is valid whatever depth the backend can provide.
  #
  # A READ FAILURE is not zero matches (advisor, #1120). Returning 0 here would let a
  # transient peek failure before the keystroke set a false baseline of 0, and a
  # recovered read afterward count a PRE-EXISTING line as if it were new -> a false
  # renamed_and_verified. So fail with NO output and let the caller treat an unread
  # count as "cannot establish/confirm", never as zero.
  screen="$(terminal_peek "$1" --lines 400 2>/dev/null)" || return 1
  printf '%s\n' "$screen" | grep -cF -- "$2 $3." || true
}

# <team> <agent> <type> <terminal> <pane> <session_cell>
#   -> the cli_session action. This is the half that TYPES into the pane
#   (`<rename_cmd> <team>-<agent>`). Two shapes, told apart by the manifest, not by
#   the type name: a rename_confirm type (codex) cannot be pre-read, so it types
#   UNCONDITIONALLY and confirms by a NEW announcement line; a readback type
#   (claude-code) types only on a mismatch and re-reads the name. Both need the
#   type to declare a rename command and the pane to report ready.
agmsg_team_rename_session_loaded() {
  # $4 (terminal) is accepted for a signature parallel to the pane-names half;
  # the rename goes through the loaded driver's terminal_poke and needs no name.
  local team="$1" agent="$2" type="$3" pane="$5"
  local session_cell="$6"
  local expected_session="$team-$agent" readiness state reason rc=0 observed title tries
  local rename_cmd session_src rename_confirm before after

  # A rename_confirm type (codex) has no dependable pre-read of its current name,
  # so --fix does NOT gate the keystroke on the (unknown) pre-check: it types
  # UNCONDITIONALLY and confirms by a NEW announcement line. "Cannot read the
  # name" is not "cannot rename" (#1109 followup). Kept separate from the readback
  # path below so a reader can see why codex behaves differently.
  rename_confirm="$(agmsg_type_get "$type" rename_confirm 2>/dev/null || true)"
  if [ -n "$rename_confirm" ]; then
    rename_cmd="$(agmsg_type_get "$type" rename_cmd 2>/dev/null || true)"
    if [ -z "$rename_cmd" ]; then
      _agmsg_team_fix_result cli_session skipped no_rename_cmd
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
    # Newness, not presence: count the confirmation line before and after, require
    # an INCREASE. A pre-existing line (an earlier run, a hand-typed rename) is in
    # `before`, so it cannot pass a keystroke that never landed.
    #
    # The baseline must be READ, not assumed. If the before-peek fails we have no
    # trustworthy zero to measure against -- and a recovered after-peek would then
    # count a pre-existing line as new (advisor, #1120). So an unreadable baseline
    # does NOT type: a keystroke we could not verify is worse than none, and this is
    # transient -- the next --fix run reads the baseline and proceeds.
    before="$(_agmsg_rename_confirm_count "$pane" "$rename_confirm" "$expected_session")" || {
      _agmsg_team_fix_result cli_session skipped baseline_unreadable
      return 0
    }
    rc=0
    terminal_poke "$pane" "$rename_cmd $expected_session" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      _agmsg_team_fix_result cli_session failed "terminal_poke_rc_$rc"
      return 0
    fi
    tries=0
    while [ "$tries" -lt 20 ]; do
      # A failed after-peek is not "zero matches" either -- leave `after` empty so
      # it cannot satisfy the comparison, and try again; only a real read that
      # EXCEEDS the baseline confirms.
      after="$(_agmsg_rename_confirm_count "$pane" "$rename_confirm" "$expected_session")" || after=""
      if [ -n "$after" ] && [ "$after" -gt "$before" ]; then
        _agmsg_team_fix_result cli_session changed renamed_and_verified
        return 0
      fi
      sleep 0.1 2>/dev/null || true
      tries=$((tries + 1))
    done
    # Typed, but no NEW confirmation line. The line is the command's own immediate
    # output, not a header that may already have scrolled off, so its absence is a
    # real failure -- never poked_unverified.
    _agmsg_team_fix_result cli_session failed rename_not_observed
    return 0
  fi

  case "$session_cell" in
    mismatch\(*)
      # The ability to rename is a manifest datum, not a type name (#1081): a type
      # that declares rename_cmd can be renamed, one that does not is skipped with
      # the reason naming the datum -- so a new renamable type needs no edit here.
      rename_cmd="$(agmsg_type_get "$type" rename_cmd 2>/dev/null || true)"
      if [ -z "$rename_cmd" ]; then
        _agmsg_team_fix_result cli_session skipped no_rename_cmd
        return 0
      fi
      session_src="$(_agmsg_cli_session_source "$type")"
      readiness="$(agmsg_team_input_ready_loaded "$type" "$pane")"
      IFS="$(printf '\t')" read -r state reason <<EOF
$readiness
EOF
      if [ "$state" != ready ]; then
        _agmsg_team_fix_result cli_session skipped "${state}_$reason"
        return 0
      fi
      rc=0
      terminal_poke "$pane" "$rename_cmd $expected_session" >/dev/null 2>&1 || rc=$?
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
        [ "$(agmsg_cli_session_observed "$type" "$title" "$pane")" = "$expected_session" ] \
          && { _agmsg_team_fix_result cli_session changed renamed_and_verified; return 0; }
        sleep 0.1 2>/dev/null || true
        tries=$((tries + 1))
      done
      # Poked, never observed to take. A `title` name is authoritative -- still
      # wrong after the rename is a real failure. A `screen` name that scrolls off
      # is not observable, so there this is the third word: poked, could not
      # confirm -- never "failed" on a screen we could not read (#1081).
      case "$session_src" in
        screen:*) _agmsg_team_fix_result cli_session poked_unverified rename_not_observed ;;
        *)        _agmsg_team_fix_result cli_session failed rename_not_observed ;;
      esac
      ;;
    ok\(*) _agmsg_team_fix_result cli_session skipped already_matches ;;
    n/a:*) _agmsg_team_fix_result cli_session skipped "${session_cell#n/a:}" ;;
    *) _agmsg_team_fix_result cli_session skipped "${session_cell#unknown:}" ;;
  esac
}

# <team> <agent> <type> <terminal> <pane> <pane_cell> <key_cell> <session_cell>
#   -> all three actions: the pane names, then the session rename (`team --fix`).
agmsg_team_fix_identity_loaded() {
  agmsg_team_fix_pane_names_loaded "$1" "$2" "$3" "$4" "$5" "$6" "$7"
  agmsg_team_rename_session_loaded "$1" "$2" "$3" "$4" "$5" "$8"
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
