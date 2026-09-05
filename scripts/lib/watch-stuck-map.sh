# watch-stuck-map.sh -- per-pair "stuck cursor" tracker for the delivery watcher
# (#1045 fix 2). Kept in its own file so the map operations can be unit-tested
# directly: watch.sh runs on source, so its inline helpers could only ever be
# exercised through a timing-dependent end-to-end test, and on a shared host a
# poll-cycle count cannot be hit deterministically (see #1045 review notes).
#
# Data structure: one record per tracked pair, records separated by NEWLINE,
# fields within a record separated by US (\x1f): "<pair><US><cursor><US><count>".
# The record separator must be a byte that cannot occur inside a field. A newline
# is one we already rely on -- the watcher reads its subscription set one
# tab-separated pair per LINE, so a team or agent name cannot contain a newline;
# US is a control byte names never carry. An earlier version joined records with
# a SPACE and scanned them with `for e in $STUCK_MAP`, which word-splits a name
# like "team a" across two words so its record never matches -- the count then
# resets every cycle and the guard this exists to provide NEVER fires. Records
# are therefore read a whole line at a time and fields split on US only, never by
# shell word splitting. The functions operate on the caller's STUCK_MAP global in
# place (no subshell) so they add no fork to the watcher's poll loop.

_AGMSG_NL='
'

# "<cursor><US><count>" for PAIR, or empty when PAIR is not tracked.
_stuck_get() {
  [ -n "$STUCK_MAP" ] || return 0
  while IFS= read -r _sm_rec; do
    [ -n "$_sm_rec" ] || continue
    IFS=$'\x1f' read -r _sm_p _sm_c _sm_n <<< "$_sm_rec"
    if [ "$_sm_p" = "$1" ]; then printf '%s\x1f%s' "$_sm_c" "$_sm_n"; return 0; fi
  done <<< "$STUCK_MAP"
  return 0
}

# Remove PAIR's record from STUCK_MAP (a no-op if it has none). Called on every
# branch that STOPS observing a pair -- held by another session, or no store yet
# -- so a resumed pair starts a fresh count instead of inheriting a stale one and
# tripping the guard on a healthy watcher.
_stuck_drop() {
  [ -n "$STUCK_MAP" ] || return 0
  _sm_out=""
  while IFS= read -r _sm_rec; do
    [ -n "$_sm_rec" ] || continue
    IFS=$'\x1f' read -r _sm_p _sm_rest <<< "$_sm_rec"
    [ "$_sm_p" = "$1" ] && continue
    _sm_out="${_sm_out:+$_sm_out$_AGMSG_NL}$_sm_rec"
  done <<< "$STUCK_MAP"
  STUCK_MAP="$_sm_out"
}

# Set PAIR's record to cursor $2, count $3 (replacing any existing record).
_stuck_set() {
  _stuck_drop "$1"
  STUCK_MAP="${STUCK_MAP:+$STUCK_MAP$_AGMSG_NL}$(printf '%s\x1f%s\x1f%s' "$1" "$2" "$3")"
}
