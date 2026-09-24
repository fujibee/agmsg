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
#                                  a real draft (styled read only); 15 = the
#                                  box's own structure could not be
#                                  confirmed (#1391/#1402: distinct from 14 --
#                                  "cannot tell where the box is" is not the
#                                  same finding as "found it, and it looks
#                                  like someone is typing", and conflating
#                                  them into one code and message hid which
#                                  one actually happened); anything else = a
#                                  driver-level terminal_peek failure,
#                                  propagate as-is
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
    # screen) -- fails toward refusing, never toward typing (unchanged bias
    # from #1321), but as its own code (#1391/#1402): this is "could not
    # locate", not "found it and it looks occupied". No region to hand to
    # the #1384 recovery path below either -- the caller's own check on
    # ib_region being non-empty already keeps this branch out of it.
    _AGMSG_SAFE_POKE_IB_RC=15
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
# Re-reads <id>'s box and says whether it is now SAFE to type over: located,
# and (when a styled read is available) not classified as a real draft.
# Shared by the post-clear check and the final restore verification below --
# review found both were missing before this existed: the post-clear check
# was skipped outright (terminal_input_clear's own contract guarantees only
# that the keys were SENT, never that the box ended up empty -- a draft
# longer than the fixed key-repeat margin, or a key that did not land,
# both leave content that must be caught, not assumed away), and the
# restore verification existed only on the success path, not on the
# gained-focus-mid-clear abort path, which trusted terminal_input_type's
# restore without checking its own result at all.
_agmsg_safe_poke_box_is_empty() {
  local id="$1" marker="$2" boxed="$3" styled="$4"
  local screen="" rc=0
  if [ "$styled" -eq 1 ]; then
    screen="$(terminal_peek_styled "$id")" || rc=$?
  else
    screen="$(terminal_peek "$id")" || rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  local region="" region_rc=0
  region="$(agmsg_input_box_locate "$marker" "$boxed" "$screen")" || region_rc=$?
  [ "$region_rc" -eq 0 ] || return 1
  [ "$styled" -eq 1 ] || return 0
  agmsg_input_box_is_real_draft "$marker" "$region" && return 1
  return 0
}

# Re-reads <id>'s box and says whether it matches <expect_region> exactly
# (normalized, styling-blind) -- the retype verification, factored out so
# both places that retype a draft (the gained-focus-mid-clear abort, and
# the normal end of a successful poke) use the SAME "restored, confirmed"
# bar rather than one of them trusting terminal_input_type's own rc alone.
_agmsg_safe_poke_box_matches() {
  local id="$1" marker="$2" boxed="$3" styled="$4" expect_region="$5"
  local screen="" rc=0
  if [ "$styled" -eq 1 ]; then
    screen="$(terminal_peek_styled "$id")" || rc=$?
  else
    screen="$(terminal_peek "$id")" || rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  local region="" region_rc=0
  region="$(agmsg_input_box_locate "$marker" "$boxed" "$screen")" || region_rc=$?
  [ "$region_rc" -eq 0 ] || return 1
  [ "$(agmsg_input_box_normalize "$region")" = "$(agmsg_input_box_normalize "$expect_region")" ]
}

# Retypes <draft> into <id>'s box, but ONLY if the box first reads back
# empty -- never blind. Review, second round: the gained-focus-mid-clear
# abort typed the draft straight back without confirming the box was
# actually empty first -- a clear that only partially worked would then
# get the WHOLE draft appended on top of whatever was left, doubling or
# corrupting it, a write that catching the mismatch afterward cannot undo.
# This is now the ONLY way anything in this file retypes a draft, at every
# one of the three sites that do -- not just the one review found.
#
# Echoes exactly one word and returns 0 in every case (the caller decides
# what to report; this never types unconfirmed and never fails the caller
# by its own exit status):
#   matched    the box read back empty, the draft was typed, and the box
#              now matches <expect_region> byte-for-byte (normalized).
#   mismatch   the box read back empty and the draft was typed, but the
#              box does not match afterward -- typed, not confirmed.
#   refused    the box did NOT read back empty (or could not be confirmed)
#              -- NOTHING was typed; the pane is exactly as found.
_agmsg_safe_poke_retype_if_empty() {
  local id="$1" marker="$2" boxed="$3" styled="$4" draft="$5" expect_region="$6"
  if ! _agmsg_safe_poke_box_is_empty "$id" "$marker" "$boxed" "$styled"; then
    echo refused
    return 0
  fi
  terminal_input_type "$id" "$draft" >/dev/null 2>&1
  if _agmsg_safe_poke_box_matches "$id" "$marker" "$boxed" "$styled" "$expect_region"; then
    echo matched
  else
    echo mismatch
  fi
  return 0
}

# The existing two-snapshot screen check (styled real-draft classification,
# or a plain unstyled change comparison), factored out of agmsg_safe_poke
# unchanged in substance (#1443 continuation) so the SAME code path serves
# both its original caller (no terminal_input_draft at all) and the new
# terminal_input_draft fallback below when that hook itself answers
# "cannot tell" -- one function, not two copies that could drift apart.
# Sets the caller's own _AGMSG_SAFE_POKE_IB_RC / _AGMSG_SAFE_POKE_IB_REGION,
# exactly as _agmsg_safe_poke_read_box already documents.
_agmsg_safe_poke_screen_check() {
  local id="$1" marker="$2" boxed="$3" styled="$4" settle_seconds="$5"
  local ib_rc=0
  _AGMSG_SAFE_POKE_IB_RC=0 _AGMSG_SAFE_POKE_IB_SNAPSHOT="" _AGMSG_SAFE_POKE_IB_REGION=""
  _agmsg_safe_poke_read_box "$id" "$marker" "$boxed" "$styled"
  ib_rc="$_AGMSG_SAFE_POKE_IB_RC"
  [ "$ib_rc" -eq 0 ] || return 0
  local snap1="$_AGMSG_SAFE_POKE_IB_SNAPSHOT"
  sleep "$settle_seconds"
  _AGMSG_SAFE_POKE_IB_RC=0 _AGMSG_SAFE_POKE_IB_SNAPSHOT="" _AGMSG_SAFE_POKE_IB_REGION=""
  _agmsg_safe_poke_read_box "$id" "$marker" "$boxed" "$styled"
  ib_rc="$_AGMSG_SAFE_POKE_IB_RC"
  if [ "$ib_rc" -ne 0 ]; then
    return 0
  fi
  # _AGMSG_SAFE_POKE_IB_REGION already holds the SECOND read's region from
  # the call just above -- left as-is, never reset to the first read's
  # (review, #1446: an earlier draft of this extraction explicitly
  # reassigned it back to the first read's region here, which is exactly
  # the one case a changed box matters most: the recovery path below saves
  # and restores whatever region this function hands it, and restoring
  # STALE content instead of what is actually in the box now would be the
  # regression #1384 exists to prevent, reintroduced by this refactor).
  [ "$snap1" != "$_AGMSG_SAFE_POKE_IB_SNAPSHOT" ] && _AGMSG_SAFE_POKE_IB_RC=14
}

# Reads <id>'s draft via the driver's OWN terminal_input_draft (priority 1
# over the screen -- #1443 continuation): base64-decoded, ONE call, no
# region/styling concept at all. Sets the caller's own
# _AGMSG_SAFE_POKE_DRAFT_RC:
#   0   this read saw nothing typed
#   14  this read saw real content -- whatever it is; the two calls in
#       agmsg_safe_poke below never compare content across reads, because
#       ANY content at EITHER read is already enough to refuse
#   10  the driver could not tell for this pane (no agent identity
#       recognized, or unreachable) -- the caller falls back to the
#       existing screen-based check entirely, never reads this as "empty"
#       (#1443's own contract)
#   other  a genuine driver-level failure (e.g. identity confirmed but the
#          read itself failed), propagated as this poke attempt's own rc
_agmsg_safe_poke_draft_read() {
  local id="$1" b64="" rc=0
  b64="$(terminal_input_draft "$id" 2>/dev/null)" || rc=$?
  _AGMSG_SAFE_POKE_DRAFT_RC="$rc"
  if [ "$rc" -eq 0 ] && [ -n "$b64" ]; then
    _AGMSG_SAFE_POKE_DRAFT_RC=14
  fi
}

_agmsg_safe_poke_recover() {
  local id="$1" text="$2" team="$3" name="$4" marker="$5" boxed="$6" styled="$7" region="$8"
  local draft
  draft="$(agmsg_input_box_draft_text "$marker" "$boxed" "$region")"

  # SKILL_DIR/run/, mode 600: this is someone's unsent, unsubmitted text,
  # not a log -- the same directory tree pidfiles and locks already live
  # under, never scripts/ or anywhere shipped.
  local run_dir draft_file
  run_dir="${SKILL_DIR:?safe-poke.sh requires SKILL_DIR}/run"
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
  # keyboard -- retype ONLY if the box is confirmed empty first (review,
  # second round), and refuse to touch the pane at all otherwise, rather
  # than typing over whatever a partial clear left behind.
  local focus2=""
  focus2="$(terminal_pane_focused "$id" 2>/dev/null)" || focus2=""
  if [ "$focus2" != no ]; then
    local retyped
    retyped="$(_agmsg_safe_poke_retype_if_empty "$id" "$marker" "$boxed" "$styled" "$draft" "$region")"
    case "$retyped" in
      matched)
        rm -f "$draft_file"
        echo "poke: pane '$id' gained focus while its draft was being cleared -- restored it and refusing to type over it (input in progress)" >&2
        ;;
      mismatch)
        echo "poke: pane '$id' gained focus while its draft was being cleared, and restoring it could not be confirmed -- the draft is saved at $draft_file; refusing to type over the pane (input in progress)" >&2
        ;;
      *)
        echo "poke: pane '$id' gained focus while its draft was being cleared, and its box did not read back empty -- left it untouched rather than risk doubling its contents; the draft is saved at $draft_file; refusing to type over the pane (input in progress)" >&2
        ;;
    esac
    return 14
  fi

  # Proof the clear actually worked, not just that the keys were sent
  # (review): a draft longer than the fixed key-repeat margin, or a key
  # that did not land, both leave content here that must be caught before
  # the poke's own text is typed on top of it.
  if ! _agmsg_safe_poke_box_is_empty "$id" "$marker" "$boxed" "$styled"; then
    echo "poke: pane '$id' did not read back empty after clearing its input box -- not typing over it; the draft is saved at $draft_file" >&2
    return 12
  fi

  rc=0
  terminal_poke "$id" "$text" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    # The message never went in. Best effort: put the draft back, but --
    # same discipline as every retype in this file -- only if the box is
    # confirmed empty first.
    local retyped
    retyped="$(_agmsg_safe_poke_retype_if_empty "$id" "$marker" "$boxed" "$styled" "$draft" "$region")"
    case "$retyped" in
      matched) echo "poke: could not deliver to pane '$id' past its draft -- restored the draft; a saved copy also remains at $draft_file" >&2 ;;
      mismatch) echo "poke: could not deliver to pane '$id' past its draft, and restoring it could not be confirmed -- the draft is saved at $draft_file" >&2 ;;
      *) echo "poke: could not deliver to pane '$id' past its draft, and its box did not read back empty afterward -- left it untouched rather than risk doubling its contents; the draft is saved at $draft_file" >&2 ;;
    esac
    return "$rc"
  fi

  # Verify in code, never by eye: compare the SAME normalized form used
  # everywhere else in this file, so the comparison is blind to styling
  # either read might carry, against the ORIGINAL region this function was
  # handed -- not a fresh classification, a byte-for-byte content check.
  local retyped
  retyped="$(_agmsg_safe_poke_retype_if_empty "$id" "$marker" "$boxed" "$styled" "$draft" "$region")"
  case "$retyped" in
    matched) rm -f "$draft_file" ;;
    mismatch) echo "poke: delivered to pane '$id', but its retyped draft does not match what was there before -- the original is saved at $draft_file" >&2 ;;
    *) echo "poke: delivered to pane '$id', but its box did not read back empty afterward -- left the draft untyped rather than risk doubling its contents; the original is saved at $draft_file" >&2 ;;
  esac
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
# Return value is terminal_poke's OWN convention, extended by two codes this
# file's own input-box check owns: 0 delivered, 14 refused (a real draft with
# no safe way through), 15 refused (the box's own structure could not be
# confirmed on this read -- #1391/#1402, distinct from 14: "could not
# locate" is not "found it and it looks occupied"), anything else the
# driver's own failure code. self-rename.sh and self-write.sh only ever
# check for overall success/failure (`>/dev/null 2>&1`, `rc=$?` with no
# branch on a specific code), so 15 is a drop-in there too; poke.sh is the
# one caller that reports 14 and 15 differently to the operator.
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

  # The verb decides the method, never the terminal's name (#1443
  # continuation): a driver offering terminal_input_draft
  # reads the composer directly and never touches the screen at all -- the
  # most accurate method, checked FIRST. Only when that hook is absent does
  # this fall back to today's screen-based choice between styled (herdr/
  # tmux) and the narrower plain two-read comparison.
  local draft_capable=0 styled=0
  declare -F terminal_input_draft >/dev/null 2>&1 && draft_capable=1
  if [ "$draft_capable" -eq 0 ]; then
    declare -F terminal_peek_styled >/dev/null 2>&1 && styled=1
  fi

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
      local ib_region=""
      if [ "$draft_capable" -eq 1 ]; then
        # Two reads, 1s apart, same as the screen-based method -- NOT
        # because the hook itself is imprecise (a single call is already
        # authoritative for that instant), but because a single check still
        # misses someone who starts typing in the instant right after it
        # (review): read1 empty does not mean the box STAYS empty long
        # enough to poke safely over. The two reads' CONTENT is never
        # compared against each other -- content at either one is already
        # enough to refuse, so there is nothing to compare.
        _agmsg_safe_poke_draft_read "$id"
        local d_rc="$_AGMSG_SAFE_POKE_DRAFT_RC"
        if [ "$d_rc" -ne 0 ]; then
          # Includes rc 10 ("cannot tell" -- no recognized agent identity,
          # or unreachable): propagated as-is, NEVER a fall-through to the
          # screen (review, #1446: an earlier version of this fell back to
          # the ordinary unstyled two-read screen comparison here, and for
          # a driver whose screen never shows the box's content at all --
          # orca's own -- "the screen looks unchanged" is not evidence of
          # anything; it would have folded a genuine unknown into a
          # confirmed-safe write with nothing actually having been checked.
          # Documenting that gap in the README does not close it -- only
          # refusing to write on it does). A caller sees this exactly like
          # any other driver-level failure: not retried (only 14/15 are),
          # reported as-is.
          rc="$d_rc"
        else
          sleep "$settle_seconds"
          _agmsg_safe_poke_draft_read "$id"
          d_rc="$_AGMSG_SAFE_POKE_DRAFT_RC"
          case "$d_rc" in
            0) rc=0 ;;
            # A second read landing on "unknown" (identity lost mid-check)
            # is treated the same as content, not folded into a fresh
            # fallback attempt mid-poke: never read "cannot tell" as safe.
            10) rc=14 ;;
            *) rc="$d_rc" ;;
          esac
        fi
        # No #1384/#1395 recovery for a draft-capable-only driver (#1443
        # continuation): that recovery needs terminal_peek_styled, a located
        # styled region, terminal_input_clear, and terminal_input_type --
        # orca has none of them today. rc=14 here just refuses, same as any
        # other driver with no focus signal at all.
      else
        _agmsg_safe_poke_screen_check "$id" "$marker" "$boxed" "$styled" "$settle_seconds"
        rc="$_AGMSG_SAFE_POKE_IB_RC"
        ib_region="$_AGMSG_SAFE_POKE_IB_REGION"
      fi

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
    # Retries exist to wait out a transient input-box condition -- someone
    # still actively typing (RC=14), or the box's structure not confirmable
    # on one read (RC=15, #1391/#1402: e.g. mid-redraw) -- never a
    # driver-level failure propagated above, or from terminal_poke's own
    # attempt, which waiting does not fix.
    [ "$rc" -eq 14 ] || [ "$rc" -eq 15 ] || return "$rc"
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
