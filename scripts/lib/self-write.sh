#!/usr/bin/env bash
# self-write.sh -- the ONE path by which a seat writes its own identity cells.
#
# #1152 inverted who writes a seat's identity. Before, three writers (spawn,
# `team --fix`, the seat's own hook) each wrote whichever seat they resolved,
# and every fix was an arbitration between them. Now one writer, the seat
# itself, writes ONLY its own cells, and nothing here reads another seat's state
# to decide a write. There is no "who is right" left to decide.
#
# WHERE THE PANE COMES FROM. Not from here. The seat does not derive or verify
# its pane: a leader sweeps the workspace and types `fix --pane P` into pane P,
# and the seat that receives it is in P by construction -- typing into P is the
# only way to reach P (koit, 2026-09-11). So <ref> arrives as an argument and is
# a LOCATION carried by the channel, never an identity: team and agent come from
# the seat's own actas, and no argument may name another seat.
#
# THE FENCE. Pane ids repeat across terminal instances (two herdr sessions both
# have a w1:p2; tmux has one id space per socket), so a pane id alone can name
# a live pane in another instance. Each write generation therefore takes a
# fence -- the driver's <instance, terminal_id> for the pane -- once, stores it
# in the placement record, and re-reads it right before EVERY later mutation in
# the generation; a difference in either half refuses the mutation, visibly.
# This is best-effort safety: a preflight check that minimises the window, not
# an atomic fence. The read and the keystroke are separate calls, so a pane
# closed and reused between them is not caught; a full fence needs the terminal
# to compare-and-type. A herdr restart changes every terminal_id, so a stored
# fence expires with the server: the record then refuses instead of writing into
# whatever now sits at that id, and the next sweep re-delivers.
#
# CELLS, in order, each independent: record (REQUIRED -- the only cell a seat's
# reachability runs through) / label / key / session (decorations: their failure
# is visible, and does not stop the record). The session cell types
# `<rename_cmd> <team>-<agent>` UNCONDITIONALLY, at most once per generation,
# when the pane's input is ready: there is no pre-read skip, no stored mark and
# no process flag, because every one of those was a stale value keyed to skip a
# needed rename (#1130's shape). The title before and after is observation only.
#
# EXCLUSION. The whole generation runs under the seat-local single-flight lock
# (self-write-lock.sh). A second writer on the same seat sees `none:busy` --
# never a silent drop, because "did it, not fixed" and "doing it now" look the
# same from outside.
#
# OUTPUT. One line per fact, never silence:
#   seat=<team>/<agent> sid=<owner> pane=<ref>        or
#   seat=... none:<busy:<owner>|bad_ref|no_driver|lock_unknown:<r>|fence_unreadable:<r>>
#   seat=... unsupported:<r>                            (plain: no pane exists)
#   fence=<instance>:<terminal_id>
#   record  attempt=<ok|failed:<r>>            readback=<verified|mismatch:<seen>|unavailable:<r>|not_attempted>
#   label   attempt=<ok|failed:<rc>|skipped:<r>> readback=<...>
#   key     attempt=<same as label: one terminal_name call> readback=<...>
#   session attempt=<ok|failed:<rc>|skipped:<r>> readback=<verified|matched_no_delta|unchanged:<seen>|mismatch:<seen>|unavailable:<r>|not_attempted>
#   policy=<accepted|accepted_unverified|repair_incomplete>
# The same lines are written, last and atomically, to run/self-write-done.<t>__<a>.
# policy is decided HERE and only here: accepted = record verified;
# accepted_unverified = record written, readback unavailable; anything else in
# the record = repair_incomplete. Decorations never change it.

: "${SKILL_DIR:?self-write.sh requires SKILL_DIR}"
# shellcheck disable=SC1091
. "${SKILL_DIR:?self-write.sh requires SKILL_DIR}/scripts/lib/actas-lock.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?self-write.sh requires SKILL_DIR}/scripts/lib/self-write-lock.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?self-write.sh requires SKILL_DIR}/scripts/lib/registry-lock.sh"        # agmsg_write_atomic
# shellcheck disable=SC1091
. "${SKILL_DIR:?self-write.sh requires SKILL_DIR}/scripts/lib/terminal-registry.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?self-write.sh requires SKILL_DIR}/scripts/lib/type-registry.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?self-write.sh requires SKILL_DIR}/scripts/lib/role-session.sh"
# shellcheck disable=SC1091
. "${SKILL_DIR:?self-write.sh requires SKILL_DIR}/scripts/lib/team-status.sh"          # agmsg_cli_session_observed

agmsg_self_write_done_path() {   # <team> <agent>
  local t a; t="$(_actas_lock_encode "$1")"; a="$(_actas_lock_encode "$2")"
  printf '%s/self-write-done.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Accumulated report lines for one generation (printed as they happen, and
# written as the done file at the end).
_SW_LINES=""
_sw_say() { printf '%s\n' "$1"; _SW_LINES="${_SW_LINES}${1}"$'\n'; }

# Read the fence for the pane. Sets _SW_F_INSTANCE / _SW_F_TID; returns the
# driver's rc (0 value, 2 unreadable, 3 unsupported), or 4 when the driver has no
# fence op at all.
_sw_fence_read() {   # <id>
  local out rc=0
  _SW_F_INSTANCE=""; _SW_F_TID=""
  declare -F terminal_fence >/dev/null 2>&1 || return 4
  out="$(terminal_fence "$1")" || rc=$?
  _SW_F_INSTANCE="${out%%$'\t'*}"; _SW_F_TID="${out#*$'\t'}"
  return "$rc"
}

# Re-read the fence and compare with the stored pair. Prints the reason on a
# mismatch ("instance" / "terminal_id" / "unreadable:<r>"), nothing when equal.
_sw_fence_check() {   # <id> <instance> <tid>
  local rc=0
  _sw_fence_read "$1" || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'unreadable:%s\n' "${_SW_F_TID#unknown:}"; return 1; fi
  [ "$_SW_F_INSTANCE" = "$2" ] || { echo instance; return 1; }
  [ "$_SW_F_TID" = "$3" ]      || { echo terminal_id; return 1; }
  return 0
}

# Write the record cell. Prints "attempt=... readback=...".
_sw_cell_record() {   # <team> <agent> <ref> <project> <type> <fence>
  local rec content back
  rec="$(agmsg_spawn_path "$1" "$2")"
  if [ -z "$4" ] || [ -z "$5" ]; then
    printf 'attempt=failed:missing_fields readback=not_attempted\n'; return 0
  fi
  content="$(printf '%s\t%s\t%s\tfence=%s' "$3" "$4" "$5" "$6")"
  mkdir -p "${rec%/*}" 2>/dev/null || true
  if ! agmsg_write_atomic "$rec" "$content" 2>/dev/null; then
    printf 'attempt=failed:write readback=not_attempted\n'; return 0
  fi
  if back="$(head -1 "$rec" 2>/dev/null)"; then
    if [ "$back" = "$content" ]; then printf 'attempt=ok readback=verified\n'
    else printf 'attempt=ok readback=mismatch:%s\n' "${back%%$'\t'*}"; fi
  else
    printf 'attempt=ok readback=unavailable:record_unreadable\n'
  fi
  return 0
}

# The label and key cells: one terminal_name call, two separate readbacks.
# Prints two lines: "label attempt=... readback=..." and "key ...".
_sw_cell_label_key() {   # <id> <team> <agent>
  local id="$1" team="$2" agent="$3" rc=0 attempt obs lab key exp_label exp_key
  terminal_name "$id" "$team" "$agent" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then attempt=ok; else attempt="failed:$rc"; fi
  if declare -F _herdr_label >/dev/null 2>&1; then exp_label="$(_herdr_label "$team" "$agent")"; else exp_label="$team:$agent"; fi
  if declare -F _herdr_internal_key >/dev/null 2>&1; then exp_key="$(_herdr_internal_key "$team" "$agent" 2>/dev/null || true)"; else exp_key=""; fi
  if declare -F terminal_team_observe >/dev/null 2>&1 && obs="$(terminal_team_observe "$id" 2>/dev/null)"; then
    lab="$(printf '%s' "$obs" | awk -F '\t' 'NR==1{print $2}')"
    key="$(printf '%s' "$obs" | awk -F '\t' 'NR==1{print $3}')"
    printf 'label attempt=%s readback=%s\n' "$attempt" "$(_sw_judge "$lab" "$exp_label")"
    if [ -n "$exp_key" ]; then printf 'key attempt=%s readback=%s\n' "$attempt" "$(_sw_judge "$key" "$exp_key")"
    else printf 'key attempt=%s readback=unavailable:no_expected_key\n' "$attempt"; fi
  else
    printf 'label attempt=%s readback=unavailable:observe_failed\n' "$attempt"
    printf 'key attempt=%s readback=unavailable:observe_failed\n' "$attempt"
  fi
  return 0
}

# One observed value against one expected value -> a readback verdict.
_sw_judge() {   # <seen> <expected>
  case "$1" in
    "$2")            echo verified ;;
    n/a:*|unknown:*) printf 'unavailable:%s\n' "$1" ;;
    absent:*)        printf 'mismatch:%s\n' "$1" ;;
    *)               printf 'mismatch:%s\n' "$1" ;;
  esac
}

_sw_title_now() {   # <id> <type> -> observed session name or unknown:/n/a:
  local obs title
  if declare -F terminal_team_observe >/dev/null 2>&1 && obs="$(terminal_team_observe "$1" 2>/dev/null)"; then
    title="$(printf '%s' "$obs" | awk -F '\t' 'NR==1{print $4}')"
    agmsg_cli_session_observed "$2" "$title" "$1" 2>/dev/null
  else
    echo "unknown:observe_failed"
  fi
}

# The session cell. Prints "attempt=... readback=...".
_sw_cell_session() {   # <id> <team> <agent> <type>
  local id="$1" team="$2" agent="$3" type="$4" rename_cmd cli ready rc=0 expected before after
  rename_cmd="$(agmsg_type_get "$type" rename_cmd 2>/dev/null || true)"
  [ -n "$rename_cmd" ] || { printf 'attempt=skipped:no_rename_cmd readback=not_attempted\n'; return 0; }
  cli="$(agmsg_type_get "$type" cli 2>/dev/null || true)"
  declare -F terminal_team_input_ready >/dev/null 2>&1 || { printf 'attempt=skipped:no_readiness_op readback=not_attempted\n'; return 0; }
  ready="$(terminal_team_input_ready "$id" "$cli" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'attempt=skipped:not_ready:%s readback=not_attempted\n' "${ready#not_ready:}"; return 0 ;;
    *) printf 'attempt=skipped:readiness_unknown:%s readback=not_attempted\n' "${ready#unknown:}"; return 0 ;;
  esac
  expected="$team-$agent"
  before="$(_sw_title_now "$id" "$type")"      # a BASELINE for the delta, never a reason to skip
  rc=0
  terminal_poke "$id" "$rename_cmd $expected" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'attempt=failed:%s readback=not_attempted\n' "$rc"; return 0; fi
  after="$(_sw_title_now "$id" "$type")"
  case "$after" in
    "$expected")
      if [ "$before" = "$expected" ]; then printf 'attempt=ok readback=matched_no_delta\n'
      else printf 'attempt=ok readback=verified\n'; fi ;;
    n/a:*|unknown:*) printf 'attempt=ok readback=unavailable:%s\n' "$after" ;;
    "$before")       printf 'attempt=ok readback=unchanged:%s\n' "$after" ;;
    *)               printf 'attempt=ok readback=mismatch:%s\n' "$after" ;;
  esac
  return 0
}

# The entry. <owner> is the writer's instance token (the watcher's composite id).
# Exit: 0 a generation ran (policy line printed, done file written); 1 busy;
# 2 refused before any write (bad ref, no driver, lock unknown, fence unreadable);
# 3 unsupported here (plain).
agmsg_self_write() {   # <team> <agent> <ref> <owner>
  local team="$1" agent="$2" ref="$3" owner="$4"
  local term id head lockv fence_rc fence project type rec_line lk_lines sess_line policy
  _SW_LINES=""
  head="seat=$team/$agent sid=$owner pane=$ref"
  [ -n "$team" ] && [ -n "$agent" ] && [ -n "$owner" ] || { _sw_say "seat=$team/$agent sid=$owner none:bad_identity"; return 2; }
  if ! _agmsg_placement_split "$ref"; then _sw_say "$head none:bad_ref"; return 2; fi
  term="$_AGMSG_PS_TERM"; id="$_AGMSG_PS_ID"
  _agmsg_terminal_id_ok "$term" "$id" || { _sw_say "$head none:bad_ref"; return 2; }
  agmsg_terminal_load "$term" 2>/dev/null || { _sw_say "$head none:no_driver:$term"; return 2; }

  lockv="$(agmsg_self_write_lock_acquire "$team" "$agent" "$owner")"
  case "$lockv" in
    ok) ;;
    busy:*)    _sw_say "$head none:$lockv"; return 1 ;;
    *)         _sw_say "$head none:lock_$lockv"; return 2 ;;
  esac

  fence_rc=0
  _sw_fence_read "$id" || fence_rc=$?
  case "$fence_rc" in
    0) ;;
    3) _sw_say "$head unsupported:${_SW_F_TID#n/a:}"; agmsg_self_write_lock_release "$team" "$agent" "$owner"; return 3 ;;
    4) _sw_say "$head none:fence_unreadable:no_fence_op"; agmsg_self_write_lock_release "$team" "$agent" "$owner"; return 2 ;;
    *) _sw_say "$head none:fence_unreadable:${_SW_F_TID#unknown:}"; agmsg_self_write_lock_release "$team" "$agent" "$owner"; return 2 ;;
  esac
  # instance:terminal_id. The guarantee runs ONE way: the driver refuses an
  # instance containing ':' (unknown:socket_path_malformed), so the instance is
  # colon-free; the terminal_id is a server-issued string whose alphabet is not
  # ours to decide (and a failed read is spelled unknown:<why>, a colon already).
  # So readers split on the FIRST colon. An earlier revision split on the last
  # one, which truncated a tid holding a colon and made every re-read compare
  # unequal to it: a false refusal of every later cell (review, 2026-09-12).
  fence="$_SW_F_INSTANCE:$_SW_F_TID"
  _sw_say "$head"
  _sw_say "fence=$fence"

  project="$(agmsg_role_session_get "$team" "$agent" project 2>/dev/null || true)"
  type="$(agmsg_role_session_get "$team" "$agent" type 2>/dev/null || true)"

  # record -- the required cell. Written on the fence just read; nothing between.
  rec_line="$(_sw_cell_record "$team" "$agent" "$ref" "$project" "$type" "$fence")"
  _sw_say "record $rec_line"

  # label + key -- fence first.
  local why
  if why="$(_sw_fence_check "$id" "$_SW_F_INSTANCE" "${fence#*:}")"; then
    lk_lines="$(_sw_cell_label_key "$id" "$team" "$agent")"
    _sw_say "$(printf '%s' "$lk_lines" | sed -n 1p)"
    _sw_say "$(printf '%s' "$lk_lines" | sed -n 2p)"
  else
    _sw_say "label attempt=skipped:fence_mismatch:$why readback=not_attempted"
    _sw_say "key attempt=skipped:fence_mismatch:$why readback=not_attempted"
  fi

  # session -- fence again: this one types into the pane.
  if why="$(_sw_fence_check "$id" "$_SW_F_INSTANCE" "${fence#*:}")"; then
    sess_line="$(_sw_cell_session "$id" "$team" "$agent" "$type")"
    _sw_say "session $sess_line"
  else
    _sw_say "session attempt=skipped:fence_mismatch:$why readback=not_attempted"
  fi

  case "$rec_line" in
    "attempt=ok readback=verified")       policy=accepted ;;
    "attempt=ok readback=unavailable:"*)  policy=accepted_unverified ;;
    *)                                    policy=repair_incomplete ;;
  esac
  _sw_say "policy=$policy"
  agmsg_write_atomic "$(agmsg_self_write_done_path "$team" "$agent")" "${_SW_LINES%$'\n'}" 2>/dev/null || true
  agmsg_self_write_lock_release "$team" "$agent" "$owner"
  return 0
}
