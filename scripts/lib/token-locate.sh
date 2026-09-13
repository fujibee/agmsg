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

# The wiring #1157's fix entry calls when #1154 (process ancestry) could not
# establish this seat's location: emit a token, look for it across every pane
# the fleet census (#1155's agmsg_terminal_enumerate) can reach, and say
# where it landed. Requires agmsg_terminal_enumerate / agmsg_terminal_load /
# terminal_peek / agmsg_locator_compose (terminal-registry.sh) to already be
# sourced by the caller; this file does not source them itself so it stays
# testable against fakes without pulling in a real terminal driver.
#
# Same four-state SHAPE as agmsg_self_proof (self-proof.sh) -- one line,
# "state<TAB>payload", exit status carrying the same thing -- so a caller
# that composes the two never reads a different answer from one than the
# other. But this route can only ever ESTABLISH or FAIL TO ESTABLISH, never
# DISPROVE: an emitted token not found in the panes this pass could reach is
# not evidence the seat is nowhere -- render lag, an unreadable pane, or a
# scan depth the token scrolled past are all still open per #1124's own
# measurements, and only a completed ancestry walk gets to claim a real
# negative. So `disproved` (rc 1) is never printed here.
#
#   rc 0  proved<TAB><locator>       the token matched exactly one pane's
#                                    text; <locator> is kind:instance:pane,
#                                    from agmsg_locator_compose
#   rc 2  undetermined<TAB><reason>  census_enumerate_failed / no_panes_observed
#                                    / no_panes_readable / not_found / ambiguous
#   rc 3  unsupported<TAB><reason>   this build has no census primitive at all
#                                    (agmsg_terminal_enumerate is not defined)
#
# Side effects: writes exactly one line to THIS process's own stdout (the
# token, prefixed so it is not mistaken for anything else) and nothing else.
# Every other pane reached here is only READ (terminal_peek), looking for
# this seat's own just-emitted token -- never targeted by name, never
# written to. One pass, no polling: called once, synchronous, costs one
# terminal_peek per live pane the census reports.
agmsg_token_locate_self() {   # <team> <agent>
  local team="$1" agent="$2"
  declare -F agmsg_terminal_enumerate >/dev/null 2>&1 \
    || { printf 'unsupported\tcensus_primitive_unavailable\n'; return 3; }

  local token; token="$(agmsg_token_locate_generate)"
  printf 'AGMSG_LOCATE_TOKEN(%s/%s): %s\n' "$team" "$agent" "$token"

  local census
  if ! census="$(agmsg_terminal_enumerate)"; then
    printf 'undetermined\tcensus_enumerate_failed\n'; return 2
  fi
  [ -n "$census" ] || { printf 'undetermined\tno_panes_observed\n'; return 2; }

  local was="${_AGMSG_TERMINAL_LOADED:-}"
  local a b c kind inst pane id text locator saw_pane=0
  local pane_args=()
  while IFS="$(printf '\t')" read -r a b c; do
    case "$a" in
      '?'|'!!'|'!') continue ;;   # that kind/instance could not be read at all
      *) kind="$a"; inst="$b"; pane="$c" ;;
    esac
    [ -n "$kind" ] && [ -n "$inst" ] && [ -n "$pane" ] || continue
    agmsg_terminal_load "$kind" >/dev/null 2>&1 || continue
    id="$inst:$pane"
    # 200 lines: this pass's own token is at most a few lines back in its own
    # pane (nothing else runs between emitting it and this scan), and other
    # seats' panes need only enough depth to plausibly still hold their own
    # recent output -- an arbitrary, stated bound (#1124 left the general
    # case open), not a claim that it is always enough.
    if text="$(terminal_peek "$id" --lines 200 2>/dev/null)"; then
      if locator="$(agmsg_locator_compose "$kind" "$inst" "$pane" 2>/dev/null)"; then
        saw_pane=1
        pane_args+=("$locator" "$text")
      fi
    fi
  done <<< "$census"
  if [ -n "$was" ]; then
    agmsg_terminal_load "$was" >/dev/null 2>&1 || true
  elif declare -F _agmsg_terminal_unset_ops >/dev/null 2>&1; then
    _agmsg_terminal_unset_ops
    _AGMSG_TERMINAL_LOADED=""
  fi

  [ "$saw_pane" -eq 1 ] || { printf 'undetermined\tno_panes_readable\n'; return 2; }

  local result
  result="$(agmsg_token_locate_classify "$token" "${pane_args[@]}")"
  case "$result" in
    found*)      printf 'proved\t%s\n' "${result#found$'\t'}"; return 0 ;;
    ambiguous*)  printf 'undetermined\tambiguous\n'; return 2 ;;
    *)           printf 'undetermined\tnot_found\n'; return 2 ;;
  esac
}
