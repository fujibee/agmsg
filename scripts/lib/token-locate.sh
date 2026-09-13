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
