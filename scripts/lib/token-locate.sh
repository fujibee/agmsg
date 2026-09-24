# Self-locate-by-token matching core (#1124).
#
# A seat that knows WHO it is but not WHERE it is can find its own pane by
# emitting a short token and finding which pane's text shows it. This file is
# only the MATCHING step: given a token and pane text already collected by
# the caller, decide whether that token identifies exactly one pane.
#
# NOT INCLUDED HERE, and deliberately so -- the issue's own investigation
# left these open, and this file does not invent answers for them:
#
#   - asking the seat to emit the token and waiting for its own completion
#     signal before reading (measured: reading on a timer misses it --
#     roughly 3s after the seat's own execution finished, not separable into
#     model latency vs. render latency with the instruments used)
#   - how many lines of a pane to read (the scan-depth bound); a token can
#     scroll out of a short readable window (measured: 80 lines on one
#     driver) as more output is appended AFTER it, not as elapsed time
#   - serializing probes so two seats are never mid-token at once (measured:
#     one seat's token and a human typing the same string are otherwise
#     indistinguishable in the pane text alone)
#
# Those are the CALLER's responsibility (how many panes to peek, at what
# --lines depth, one seat at a time, only after that seat's own agmsg reply
# confirms it finished emitting). This function only classifies whatever
# pane texts the caller already collected under those disciplines.
#
# agmsg_token_locate_classify <token> <locator1> <text1> [<locator2> <text2> ...]
#
# Prints exactly one of:
#
#   found\t<locator>            the token appears in exactly one pane's text
#   not_found                   the token appears in none of the given panes
#   ambiguous\t<locator1,locator2,...>   the token appears in more than one
#
# "ambiguous" is a real, load-bearing outcome, not an error to average away:
# measured on the live workstation, a token the operator typed by hand into
# their own pane matched the SAME token a seat had just emitted, one
# occurrence in each, textually indistinguishable. A caller must not treat a
# match as proof by itself -- the freshness and the request/reply pairing
# that produced the token are what carry the proof (see the issue), and
# "ambiguous" is exactly the case where a bare match is not enough.
# A short, opaque token for one probe. Short is load-bearing, not cosmetic:
# measured on the live workstation, a ~130-char token physically WRAPPED
# across three terminal lines and an exact-substring match could not find it
# even though it was plainly on screen -- wrapping is a property of pane
# width, which this protocol does not control, so any scheme needing a long
# unique string fails on a narrow pane. The fixed prefix is not a uniqueness
# guarantee (see agmsg_token_locate_classify's "ambiguous" outcome, which
# exists because uniqueness cannot be assumed) -- it only makes an
# accidental match against ordinary pane content less likely to occur at
# all, not something the caller may skip verifying.
agmsg_token_locate_generate() {
  local rand
  rand="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$rand" ] || rand="$$$(date +%s 2>/dev/null)"
  printf 'agmsg-locate-%s\n' "$rand"
}

agmsg_token_locate_classify() {   # <token> <locator1> <text1> [...]
  local token="$1"; shift
  [ -n "$token" ] || { printf 'not_found\n'; return 0; }
  local locator text matches=""
  local n=0
  while [ "$#" -ge 2 ]; do
    locator="$1"; text="$2"; shift 2
    case "$text" in
      *"$token"*) matches="${matches:+$matches,}$locator"; n=$((n + 1)) ;;
    esac
  done
  case "$n" in
    0) printf 'not_found\n' ;;
    1) printf 'found\t%s\n' "$matches" ;;
    *) printf 'ambiguous\t%s\n' "$matches" ;;
  esac
}

# --- emit/observe split (#1386) ----------------------------------------
#
# agmsg_token_locate_self USED to emit a token and immediately scan every
# pane for it, in one call. Measured (#1386): a caller running this from
# inside an agent's own tool call never sees the token it just printed --
# the CLI renders a tool call's output as one block once the call returns,
# not line by line while it runs, so a peek taken before that return always
# reads a screen the token has not reached yet (0 hits mid-call, 1 hit
# after). The fix is not a longer wait; it is two genuinely separate calls,
# so the token's own emitting call has already returned -- and been
# rendered -- before the observing call ever starts.
#
# So the token now outlives a single call: EMIT persists it (team, agent,
# token, timestamp) to a short-lived, best-effort record under run/, and
# OBSERVE reads that record instead of generating its own. Same reasoning
# as role-session.sh's records (advisory, safe to delete anytime, a failed
# write never fails the caller) -- reusing its exact convention (run/,
# _actas_lock_encode, key=value lines) rather than a third one.
#
# Requires SKILL_DIR and _actas_lock_encode / _actas_lock_dir already
# available (actas-lock.sh); sourced conditionally, same guard
# role-session.sh uses, so a caller that already loaded actas-lock.sh
# doesn't re-run it.
: "${SKILL_DIR:?token-locate.sh requires SKILL_DIR}"
if ! command -v _actas_lock_encode >/dev/null 2>&1; then
  # The :- here is redundant with the :? guard just above (SKILL_DIR is
  # already guaranteed set by the time this line runs) -- present only so a
  # bare $SKILL_DIR read a few lines after its own :? check is not ALSO
  # flagged as a second, separate unguarded read (.github/scripts/check-
  # unguarded-env-reads.sh does not track that connection across lines).
  # shellcheck disable=SC1091
  . "${SKILL_DIR:-}/scripts/lib/instance-id.sh"
  # shellcheck disable=SC1091
  . "${SKILL_DIR:-}/scripts/lib/actas-lock.sh"
fi

# 120s: long enough that a genuinely separate follow-up call (a human typing
# `fix` again, a poke, the next loop iteration) has every realistic chance to
# land inside it, short enough that a caller who never follows up does not
# leave a token sitting around to match unrelated later pane content. Not
# measured against a real distribution of follow-up delays (#1386 left this
# open); revisit if a real caller's gap turns out to routinely exceed it.
_AGMSG_TOKEN_LOCATE_TTL=120

_agmsg_token_locate_path() {   # <team> <agent> -- prints the record path
  local t a
  t="$(_actas_lock_encode "$1")"; a="$(_actas_lock_encode "$2")"
  printf '%s/token-locate.%s__%s\n' "$(_actas_lock_dir)" "$t" "$a"
}

# Shared by agmsg_token_locate_pending and agmsg_token_locate_observe, so
# there is exactly one place that decides whether a record is live -- a
# second, separately-maintained copy of the same TTL check is how the two
# would quietly drift (observe honoring a record pending already expired,
# or the reverse). Prints the token on success (exit 0) and returns 1 on
# any other outcome. Removes the record ONLY when it is genuinely stale by
# TIME (absent, unreadable, corrupt/future timestamp, or past TTL) -- never
# merely because THIS caller's witness didn't match (below): a caller that
# is not the record's rightful owner gets treated like "no pending token
# for me", not a license to itself delete a still-live record someone
# else legitimately emitted. This does NOT make that record durable,
# though (review, #1397): in the ordinary `fix` flow, a caller that finds
# no match here calls agmsg_token_locate_emit next, which mv -f's a fresh
# record over this exact same path (keyed only on team/agent, not on
# owner) -- so the rightful owner's record is still overwritten moments
# later by the mismatched caller's own emit. What this function's own
# restraint buys is narrower: it is never the READ itself that destroys a
# live record it does not own.
#
# <owner> is the CALLER's own current actas-lock owner token for this role
# (review, #1397) -- the pending record is only reused when it matches
# the witness the record was written with, so a role restarted, resumed,
# or handed off to a different session inside the TTL window cannot have
# its fresh `fix` call observe a token an earlier, now-superseded claim
# emitted. An empty owner (a caller that has none to give) never matches
# anything, including a record whose own witness is also empty -- there is
# no case where "neither side can name a witness" should read as a match.
_agmsg_token_locate_read() {   # <team> <agent> <owner>
  local path token="" emitted_at="" witness="" now age
  path="$(_agmsg_token_locate_path "$1" "$2")"
  if [ -f "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        token=*) token="${line#token=}" ;;
        emitted_at=*) emitted_at="${line#emitted_at=}" ;;
        witness=*) witness="${line#witness=}" ;;
      esac
    done < "$path" 2>/dev/null
  fi
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in ''|*[!0-9]*) now="" ;; esac
  case "$emitted_at" in ''|*[!0-9]*) emitted_at="" ;; esac

  if [ -z "$token" ] || [ -z "$now" ] || [ -z "$emitted_at" ]; then
    rm -f "$path" 2>/dev/null || true
    return 1
  fi
  age=$((now - emitted_at))
  # >= 0, not just < TTL: a clock that read a value BEFORE emitted_at (a
  # bogus future emitted_at, or the wall clock stepping backward) must
  # never read as "live" -- age negative would otherwise pass "< TTL"
  # forever.
  if [ "$age" -lt 0 ] || [ "$age" -ge "$_AGMSG_TOKEN_LOCATE_TTL" ]; then
    rm -f "$path" 2>/dev/null || true
    return 1
  fi

  [ -n "$witness" ] && [ -n "$3" ] && [ "$witness" = "$3" ] || return 1
  printf '%s\n' "$token"
  return 0
}

# Whether a live (unexpired), witness-matching pending token exists for
# (team, agent, owner). Exit 0 and nothing on stdout when yes; exit 1 when
# no -- a caller does not need to tell absent/unreadable/expired/wrong-
# witness apart, only whether to call emit or observe next.
agmsg_token_locate_pending() {   # <team> <agent> <owner>
  _agmsg_token_locate_read "$1" "$2" "$3" >/dev/null
}

# EMIT half: generate a token, print it where the seat's own pane will show
# it, and persist it for the LATER, separate observe call. Always returns 0
# (best-effort, same as role-session.sh's writer) -- a failed persist just
# means the next call finds no pending token and emits a fresh one instead
# of observing; it does not fail the caller.
#
# The token line goes to STDERR, not stdout, and is the ONLY thing this
# function writes. Two reasons, not one:
#   - a caller that captures this call via $(...) for a return value (every
#     caller in this codebase does, to get emit_observe's PAIRED functions
#     to compose the same way self-proof.sh's four states do) would
#     otherwise capture the token line too instead of it ever reaching the
#     real screen -- the exact bug #1386 found in the OLD combined
#     function's own state= field (a captured token line, not the actual
#     observe result, ends up parsed as the state).
#   - stderr is unbuffered and, on the same tty as stdout, interleaves in
#     write order -- keeping this the FIRST thing the caller's whole
#     invocation writes anywhere keeps it the first line on screen, which
#     matters because a long tool call's output is often folded to its
#     first few lines by the CLI showing it.
# <owner>, stored as the record's witness, is the CALLER's own current
# actas-lock owner token for this role -- see _agmsg_token_locate_read's
# header for why a bare (team, agent) key is not enough on its own.
agmsg_token_locate_emit() {   # <team> <agent> <owner>
  local team="$1" agent="$2" owner="$3" path dir tmp token ts
  token="$(agmsg_token_locate_generate)"
  printf 'AGMSG_LOCATE_TOKEN(%s/%s): %s\n' "$team" "$agent" "$token" >&2
  path="$(_agmsg_token_locate_path "$team" "$agent")"
  dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/.token-locate.XXXXXX" 2>/dev/null)" || return 0
  ts="$(date -u +%s 2>/dev/null || echo 0)"
  {
    printf 'token=%s\n' "$token"
    printf 'emitted_at=%s\n' "$ts"
    printf 'witness=%s\n' "$owner"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# OBSERVE half: read a token a PRIOR, separate agmsg_token_locate_emit call
# already persisted (never generates or emits its own), scan every pane the
# fleet census (#1155's agmsg_terminal_enumerate) can reach, and say where
# it landed. Requires agmsg_terminal_enumerate / agmsg_terminal_load /
# terminal_peek / agmsg_locator_compose (terminal-registry.sh) to already be
# sourced by the caller; this file does not source them itself so it stays
# testable against fakes without pulling in a real terminal driver.
#
# Same four-state SHAPE as agmsg_self_proof (self-proof.sh) -- one line,
# "state<TAB>payload", exit status carrying the same thing -- so a caller
# that composes the two never reads a different answer from one than the
# other. But this route can only ever ESTABLISH or FAIL TO ESTABLISH, never
# DISPROVE: a persisted token not found in the panes this pass could reach is
# not evidence the seat is nowhere -- render lag, an unreadable pane, or a
# scan depth the token scrolled past are all still open per #1124's own
# measurements, and only a completed ancestry walk gets to claim a real
# negative. So `disproved` (rc 1) is never printed here.
#
#   rc 0  proved<TAB><locator>       the token matched exactly one pane's
#                                    text; <locator> is kind:instance:pane,
#                                    from agmsg_locator_compose
#   rc 2  undetermined<TAB><reason>  no_pending_token / census_enumerate_failed
#                                    / no_panes_observed / no_panes_readable /
#                                    not_found / ambiguous
#   rc 3  unsupported<TAB><reason>   this build has no census primitive at all
#                                    (agmsg_terminal_enumerate is not defined)
#
# Side effects: the pending record is consumed -- removed here whether the
# token is found or not, so a stray later call never re-observes the same
# token against a pane state it no longer describes. Writes NOTHING to
# stdout except the one result line (never the token itself -- unlike the
# old combined function, there is no emitting left to do here). Every pane
# reached here is only READ (terminal_peek), looking for this seat's own
# previously-emitted token -- never targeted by name, never written to. One
# pass, no polling: called once, synchronous, costs one terminal_peek per
# live pane the census reports.
agmsg_token_locate_observe() {   # <team> <agent> <owner>
  local team="$1" agent="$2" owner="$3" path token=""
  path="$(_agmsg_token_locate_path "$team" "$agent")"
  # Only remove the record ourselves on a SUCCESSFUL read -- single-use,
  # consumed now that this caller's own witness-matching token was read.
  # _agmsg_token_locate_read already removes a genuinely stale-by-time
  # record on its own; a live record that did not match THIS caller's
  # witness is left untouched here too (#1397), same restraint and same
  # caveat as _agmsg_token_locate_read's own header (an emit that follows
  # a mismatch here still overwrites it moments later) -- an observe
  # called directly, bypassing the pending precheck, by whoever does not
  # own the record must at least not be the thing that destroys it.
  if token="$(_agmsg_token_locate_read "$team" "$agent" "$owner")"; then
    rm -f "$path" 2>/dev/null || true
  fi
  [ -n "$token" ] || { printf 'undetermined\tno_pending_token\n'; return 2; }

  declare -F agmsg_terminal_enumerate >/dev/null 2>&1 \
    || { printf 'unsupported\tcensus_primitive_unavailable\n'; return 3; }

  local census
  if ! census="$(agmsg_terminal_enumerate)"; then
    printf 'undetermined\tcensus_enumerate_failed\n'; return 2
  fi
  [ -n "$census" ] || { printf 'undetermined\tno_panes_observed\n'; return 2; }

  local was="${_AGMSG_TERMINAL_LOADED:-}"
  local a b c kind inst pane id text locator saw_pane=0
  local pane_args=()
  # Every peek's stderr is inspected, not discarded, so a sandbox that denies
  # socket access can be told apart from an ordinary "no panes exist" --
  # herdr's own driver already forwards the OS-level diagnostic verbatim
  # (drivers/terminals/herdr/ops.sh, "PermissionDenied (Operation not
  # permitted)" from a sandbox that denies socket operations, #1158) but this
  # loop used to throw it away with `2>/dev/null`, collapsing every distinct
  # cause into the same generic reason below (review, #1457).
  local peek_err_tmp any_peek_attempted=0 any_non_permission_fail=0 peek_rc peek_err
  peek_err_tmp="$(mktemp 2>/dev/null)" || peek_err_tmp=""
  while IFS="$(printf '\t')" read -r a b c; do
    case "$a" in
      # That kind/instance could not be read at all -- a failure of its
      # own, never the sandbox's permission specifically, so it counts
      # against the strict "every failure was permission" requirement
      # below the same way a mixed non-permission peek failure does
      # (review, #1457 round 2: one pane denied by the sandbox and another
      # failing for an unrelated reason must not still read as "the
      # sandbox").
      '?'|'!!'|'!') any_non_permission_fail=1; continue ;;
      *) kind="$a"; inst="$b"; pane="$c" ;;
    esac
    if [ -z "$kind" ] || [ -z "$inst" ] || [ -z "$pane" ]; then
      any_non_permission_fail=1
      continue
    fi
    if ! agmsg_terminal_load "$kind" >/dev/null 2>&1; then
      any_non_permission_fail=1
      continue
    fi
    id="$inst:$pane"
    # 200 lines: this seat's own token is somewhere in the pane's recent
    # scrollback (the emitting call already returned and was rendered before
    # this call started -- that ordering is the whole point of the split),
    # and other seats' panes need only enough depth to plausibly still hold
    # their own recent output -- an arbitrary, stated bound (#1124 left the
    # general case open), not a claim that it is always enough.
    peek_rc=0
    if [ -n "$peek_err_tmp" ]; then
      text="$(terminal_peek "$id" --lines 200 2>"$peek_err_tmp")" || peek_rc=$?
    else
      text="$(terminal_peek "$id" --lines 200 2>/dev/null)" || peek_rc=$?
    fi
    if [ "$peek_rc" -eq 0 ]; then
      if locator="$(agmsg_locator_compose "$kind" "$inst" "$pane" 2>/dev/null)"; then
        saw_pane=1
        pane_args+=("$locator" "$text")
      fi
    else
      any_peek_attempted=1
      peek_err=""
      [ -n "$peek_err_tmp" ] && peek_err="$(cat "$peek_err_tmp" 2>/dev/null)"
      case "$peek_err" in
        *[Pp]ermission*[Dd]enied*|*[Oo]peration*not*permitted*) : ;;
        *) any_non_permission_fail=1 ;;
      esac
    fi
  done <<< "$census"
  [ -n "$peek_err_tmp" ] && rm -f "$peek_err_tmp"
  if [ -n "$was" ]; then
    agmsg_terminal_load "$was" >/dev/null 2>&1 || true
  elif declare -F _agmsg_terminal_unset_ops >/dev/null 2>&1; then
    _agmsg_terminal_unset_ops
    _AGMSG_TERMINAL_LOADED=""
  fi

  if [ "$saw_pane" -ne 1 ]; then
    if [ "$any_peek_attempted" -eq 1 ] && [ "$any_non_permission_fail" -eq 0 ]; then
      printf 'undetermined\tno_panes_readable_sandbox_permission\n'; return 2
    fi
    printf 'undetermined\tno_panes_readable\n'; return 2
  fi

  local result
  result="$(agmsg_token_locate_classify "$token" "${pane_args[@]}")"
  case "$result" in
    found*)      printf 'proved\t%s\n' "${result#found$'\t'}"; return 0 ;;
    ambiguous*)  printf 'undetermined\tambiguous\n'; return 2 ;;
    *)           printf 'undetermined\tnot_found\n'; return 2 ;;
  esac
}
