#!/usr/bin/env bash
# safe-poke.sh — the ONE shared "is it safe to type here" guard for every
# caller that submits text into a pane, plus the #1384 herdr recovery for an
# abandoned draft.
#
# Before this existed, poke.sh carried its own copy of the #1321/#1322
# input-box check (typing into ANOTHER member's pane), while self-rename.sh
# and self-write.sh called terminal_poke directly, unchecked (typing into
# THIS session's OWN pane -- a human co-piloting the same seat, or a draft
# left in it, carries exactly the same corruption risk poke.sh already
# guarded against). Consolidated into one routine, routing all four call
# sites through it, without changing self-rename.sh's/self-write.sh's own
# calling shape (return-value handling, no output) -- both already redirect
# `>/dev/null 2>&1`, so nothing this file prints reaches them.
#
# Requires: SKILL_DIR set (the #1384 draft file's directory), and the
# target's terminal driver already loaded via agmsg_terminal_load -- this
# never loads one itself, the same division every other terminal_*
# consumer in this codebase keeps.

[ -n "${_AGMSG_SAFE_POKE_SH:-}" ] && return 0
_AGMSG_SAFE_POKE_SH=1

_AGMSG_SAFE_POKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_AGMSG_SAFE_POKE_LIB_DIR/input-box.sh"

# Reads <id>'s input box once and classifies it, setting the caller's own
# _AGMSG_SAFE_POKE_IB_RC / _AGMSG_SAFE_POKE_IB_SNAPSHOT /
# _AGMSG_SAFE_POKE_IB_REGION (plain-statement call, never `x="$(...)"` --
# see poke.sh's original comment on this, unchanged in spirit: a command
# substitution runs in a subshell, and these are side-channel globals).
#   _AGMSG_SAFE_POKE_IB_RC        0 = box confirmed & safe to compare; 14 =
#                                  a real draft (styled read only) or the
#                                  box's own structure could not be
#                                  confirmed; anything else = a driver-level
#                                  terminal_peek failure, propagate as-is
#   _AGMSG_SAFE_POKE_IB_SNAPSHOT  normalized comparison key, meaningful only
#                                  when _AGMSG_SAFE_POKE_IB_RC = 0
#   _AGMSG_SAFE_POKE_IB_REGION    the located STYLED region, set whenever
#                                  agmsg_input_box_locate succeeded (RC 0
#                                  or the real-draft 14) -- empty otherwise
#
# <styled> is 1 when the driver offers terminal_peek_styled (checked once
# by the caller, via `declare -F`) -- a driver without it only gets the
# two-snapshot change check (narrower: won't catch a STALLED real draft),
# never a regression from what shipped before this existed.
_agmsg_safe_poke_read_box() {
  local id="$1" marker="$2" boxed="$3" styled="$4"
  local screen="" peek_rc=0 region="" region_rc=0
  if [ "$styled" -eq 1 ]; then
    screen="$(terminal_peek_styled "$id")" || peek_rc=$?
  else
    screen="$(terminal_peek "$id")" || peek_rc=$?
  fi
  if [ "$peek_rc" -ne 0 ]; then
    _AGMSG_SAFE_POKE_IB_RC="$peek_rc"
    return 0
  fi
  region="$(agmsg_input_box_locate "$marker" "$boxed" "$screen")" || region_rc=$?
  if [ "$region_rc" -ne 0 ]; then
    # Cannot confirm where the box even is (transient redraw, alternate
    # screen) -- fails toward refusing, never toward typing.
    _AGMSG_SAFE_POKE_IB_RC=14
    return 0
  fi
  # Stashed regardless of the real-draft verdict below (#1384): the recovery
  # path needs the located region to preserve, and the only two ways this
  # function can set RC=14 with a region actually located are both right
  # here -- a failed locate above never reaches this line.
  _AGMSG_SAFE_POKE_IB_REGION="$region"
  if [ "$styled" -eq 1 ] && agmsg_input_box_is_real_draft "$marker" "$region"; then
    _AGMSG_SAFE_POKE_IB_RC=14
    return 0
  fi
  _AGMSG_SAFE_POKE_IB_RC=0
  _AGMSG_SAFE_POKE_IB_SNAPSHOT="$(agmsg_input_box_normalize "$region")"
}

# #1384 (herdr only): the two-snapshot check above refuses on any real,
# STATIONARY draft, whether someone is actively typing (stationary because
# ordinary typing speed easily holds still for under ~1s) or a draft was
# left behind and nobody is watching -- content and change-detection alone
# cannot tell those apart. herdr's pane-focus signal can: focused means
# someone is plausibly there right now, not focused means the draft is
# abandoned and refusing it forever is the actual bug this closes.
#
# <region> is the STYLED region located just before this was called --
# preserved and compared against, never re-derived, so what gets saved and
# restored is the SAME read the refusal was decided from.
#
# Returns, meant to be assigned straight to the caller's rc:
#   0   delivered. Either the retyped draft verified byte-for-byte (in
#       code, via agmsg_input_box_normalize -- never eyeballed) against the
#       original, or it did not and that is reported on stderr with the
#       saved file's path -- the poke itself still succeeded either way.
#   14  focus landed on the pane between the first check and the point this
#       function would have cleared the box -- the SAME meaning as the
#       ordinary two-snapshot refusal, so the caller's own retry loop is
#       what handles it. Nothing was typed; the box is exactly as found.
#   other (driver failure clearing, poking, or retyping)  propagated so the
#       caller's normal driver-failure handling handles it. The draft file,
#       if one was written, is left in place on every path except a
#       confirmed 0-with-verified-match.
_agmsg_safe_poke_recover() {
  local id="$1" text="$2" team="$3" name="$4" marker="$5" boxed="$6" styled="$7" region="$8"
  local draft
  draft="$(agmsg_input_box_draft_text "$marker" "$boxed" "$region")"

  # SKILL_DIR/run/, mode 600: this is someone's unsent, unsubmitted text,
  # not a log -- the same directory tree pidfiles and locks already live
  # under, never scripts/ or anywhere shipped.
  local run_dir draft_file
  run_dir="$SKILL_DIR/run"
  mkdir -p "$run_dir" 2>/dev/null
  draft_file="$(mktemp "$run_dir/poke-draft.${team:-noteam}.${name:-noname}.XXXXXX" 2>/dev/null)" \
    || { echo "poke: could not create a file under '$run_dir' to save pane '$id''s draft -- refusing rather than risk it (input in progress)" >&2; return 14; }
  chmod 600 "$draft_file" 2>/dev/null
  printf '%s' "$draft" > "$draft_file"

  local rc=0 body=""
  body="$(terminal_input_clear "$id")" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$body" != ok ]; then
    echo "poke: could not clear pane '$id''s input box to deliver past its draft -- the draft is saved at $draft_file" >&2
    [ "$rc" -ne 0 ] || rc=12
    return "$rc"
  fi

  # Focus re-read #2: right after clearing, before either restoring outright
  # or going on to poke. Landing here means someone is now plausibly at the
  # keyboard -- put the draft straight back and refuse, never type the
  # poke's own text into a box someone just started using.
  local focus2=""
  focus2="$(terminal_pane_focused "$id" 2>/dev/null)" || focus2=""
  if [ "$focus2" != no ]; then
    terminal_input_type "$id" "$draft" >/dev/null 2>&1
    rm -f "$draft_file"
    echo "poke: pane '$id' gained focus while its draft was being cleared -- restored it and refusing to type over it (input in progress)" >&2
    return 14
  fi

  rc=0
  terminal_poke "$id" "$text" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    # The message never went in. Best effort: put the draft back rather
    # than leave the box empty because a poke attempt failed.
    terminal_input_type "$id" "$draft" >/dev/null 2>&1
    echo "poke: could not deliver to pane '$id' past its draft -- attempted to restore the draft; a saved copy also remains at $draft_file" >&2
    return "$rc"
  fi

  rc=0
  terminal_input_type "$id" "$draft" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "poke: delivered to pane '$id', but could not retype its draft afterward -- the draft is saved at $draft_file" >&2
    return 0
  fi

  # Verify in code, never by eye: compare the SAME normalized form used
  # everywhere else in this file, so the comparison is blind to styling
  # either read might carry, against the ORIGINAL region this function was
  # handed -- not a fresh classification, a byte-for-byte content check.
  local after_screen="" after_rc=0 restored_ok=0
  if [ "$styled" -eq 1 ]; then
    after_screen="$(terminal_peek_styled "$id")" || after_rc=$?
  else
    after_screen="$(terminal_peek "$id")" || after_rc=$?
  fi
  if [ "$after_rc" -eq 0 ]; then
    local after_region="" after_region_rc=0
    after_region="$(agmsg_input_box_locate "$marker" "$boxed" "$after_screen")" || after_region_rc=$?
    if [ "$after_region_rc" -eq 0 ] \
      && [ "$(agmsg_input_box_normalize "$after_region")" = "$(agmsg_input_box_normalize "$region")" ]; then
      restored_ok=1
    fi
  fi
  if [ "$restored_ok" -eq 1 ]; then
    rm -f "$draft_file"
  else
    echo "poke: delivered to pane '$id', but its retyped draft does not match what was there before -- the original is saved at $draft_file" >&2
  fi
  return 0
}

# agmsg_safe_poke <id> <text> <input_marker> <input_boxed> <team> <name>
#                 [--retries N] [--retry-delay SECONDS]
#                 [--backoff fixed|exponential]
#
# Types <text> into pane <id> and submits it via terminal_poke, after the
# input-box safety check above (#1321/#1322: two snapshots ~1s apart, a
# real draft by style refused outright) plus the #1384 herdr recovery for
# an abandoned (unfocused) real draft.
#
# <input_marker>/<input_boxed> are the CALLER's own agmsg_type_get lookups
# (input_prompt_marker / input_prompt_boxed), not derived here -- a caller
# on a terminal with no addressable screen at all (plain) passes an empty
# marker to skip the check entirely, exactly as poke.sh has always done;
# baking "which terminal is plain" into this shared file would duplicate a
# fact each caller already has cheaply in scope. An empty marker means: no
# check, one unconditional terminal_poke call.
#
# <team>/<name> are used only for the #1384 draft file's name and its
# diagnostic messages; a caller with no natural (team, name) pair may pass
# empty strings for both.
#
# Return value is terminal_poke's OWN convention: 0 delivered, 14 refused
# (a real draft with no safe way through), anything else the driver's own
# failure code. Every existing caller already checks against exactly this
# taxonomy (`rc=$?` against terminal_poke), so this is a drop-in
# replacement, not a new contract to teach.
agmsg_safe_poke() {
  local id="$1" text="$2" marker="$3" boxed="$4" team="$5" name="$6"
  shift 6
  local retries=0 retry_delay=2 backoff=exponential
  while [ $# -gt 0 ]; do
    case "$1" in
      --retries) retries="${2:-0}"; shift 2 ;;
      --retry-delay) retry_delay="${2:-2}"; shift 2 ;;
      --backoff) backoff="${2:-exponential}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local styled=0
  declare -F terminal_peek_styled >/dev/null 2>&1 && styled=1

  # The interval is fixed, not a flag: making it configurable would leave
  # "how long is long enough" an open question nobody has actually
  # measured, with the value drifting per caller. 1 second was chosen
  # because ordinary interactive typing -- including a Japanese IME
  # updating its pre-conversion buffer per kana -- changes the box well
  # under a second between keystrokes; measured (2026-09-21, read-only)
  # against three real idle panes over a full 8s span, the STATIONARY case
  # (Claude Code candidate text, Codex's placeholder) never changed at all.
  local settle_seconds=1

  local rc=0 attempt=0
  while :; do
    rc=0
    if [ -n "$marker" ]; then
      local ib_rc=0 ib_region=""
      _AGMSG_SAFE_POKE_IB_RC=0 _AGMSG_SAFE_POKE_IB_SNAPSHOT="" _AGMSG_SAFE_POKE_IB_REGION=""
      _agmsg_safe_poke_read_box "$id" "$marker" "$boxed" "$styled"
      ib_rc="$_AGMSG_SAFE_POKE_IB_RC"
      if [ "$ib_rc" -ne 0 ]; then
        rc="$ib_rc"
      else
        local snap1="$_AGMSG_SAFE_POKE_IB_SNAPSHOT"
        sleep "$settle_seconds"
        _AGMSG_SAFE_POKE_IB_RC=0 _AGMSG_SAFE_POKE_IB_SNAPSHOT="" _AGMSG_SAFE_POKE_IB_REGION=""
        _agmsg_safe_poke_read_box "$id" "$marker" "$boxed" "$styled"
        ib_rc="$_AGMSG_SAFE_POKE_IB_RC"
        if [ "$ib_rc" -ne 0 ]; then
          rc="$ib_rc"
        else
          [ "$snap1" = "$_AGMSG_SAFE_POKE_IB_SNAPSHOT" ] || rc=14
        fi
      fi
      ib_region="$_AGMSG_SAFE_POKE_IB_REGION"

      # #1384: a real-draft refusal with a located region to preserve, on a
      # driver that offers focus (herdr), with that pane confirmed NOT
      # focused, tries the save/clear/poke/restore recovery instead of the
      # plain refuse-or-retry below. Focused, undecidable, no region (the
      # box itself could not be located), or a driver with no focus signal
      # at all (tmux) -- every one of those falls straight through
      # unchanged.
      if [ "$rc" -eq 14 ] && [ -n "$ib_region" ] && declare -F terminal_pane_focused >/dev/null 2>&1; then
        local focused1=""
        focused1="$(terminal_pane_focused "$id" 2>/dev/null)" || focused1=""
        if [ "$focused1" = no ]; then
          _agmsg_safe_poke_recover "$id" "$text" "$team" "$name" "$marker" "$boxed" "$styled" "$ib_region"
          rc=$?
          [ "$rc" -eq 0 ] && return 0
        fi
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      terminal_poke "$id" "$text" >/dev/null || rc=$?
      return "$rc"
    fi
    # Retries exist to wait out someone still actively typing (RC=14) -- a
    # driver-level failure propagated above, or from terminal_poke's own
    # attempt, would not be fixed by waiting and must not be retried.
    [ "$rc" -eq 14 ] || return "$rc"
    [ "$attempt" -lt "$retries" ] || return "$rc"
    attempt=$((attempt + 1))
    local wait
    if [ "$backoff" = exponential ]; then
      wait=$((retry_delay * (1 << (attempt - 1))))
      [ "$wait" -le 60 ] || wait=60
    else
      wait="$retry_delay"
    fi
    sleep "$wait"
  done
}
