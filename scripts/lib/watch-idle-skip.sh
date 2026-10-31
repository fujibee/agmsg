# watch-idle-skip.sh -- per-pair "did the local store change" checkpoint for
# the delivery watcher (#1842). Kept in its own file, same reasoning as
# lib/watch-stuck-map.sh: watch.sh runs on source, so its inline helpers could
# only ever be exercised through a timing-dependent end-to-end test, and the
# correctness properties here (per-pair isolation, pre-read vs. post-read
# fingerprint timing) are exactly the kind of thing that needs a direct,
# deterministic unit test rather than a real poll loop.
#
# What this buys: skipping storage_read_cursor_get/storage_watch_after on a
# cycle where the local store provably has not changed since the PAIR's own
# last real check found nothing pending and delivered cleanly. Each of those
# two calls forks a real sqlite3 process (plus a `tr` pipeline), and this is
# the single largest source of this watcher's idle process spawns.
#
# Per PAIR (team:agent), not per team (review, #1846 round 1: a team-wide
# checkpoint let one pair's clean read arm the WHOLE team, so a second pair's
# own unread backlog in the same broad-subscription watcher was silently
# taken as "unchanged" and never read again). Every map here is keyed by the
# full "team:agent" pair; nothing may generalize across the agents of one
# team.
#
# The checkpoint is a FINGERPRINT (mtime+size) of {db, db-wal}, taken BEFORE
# the real read it backs, held in a plain variable -- not a stamp file
# compared by mtime (review, same round: a stamp touched AFTER the read
# leaves the exact window a concurrent writer needs -- during the read
# itself, or between the read finishing and the stamp being written -- open
# for a write that lands there to be silently treated as "already seen" on
# the very next cycle, never re-read). Capturing it first instead means ANY
# write from that moment on, including one landing mid-read, changes the
# fingerprint a LATER cycle's own fresh stat will see -- it is picked up
# then, one cycle later than it could be in the best case, which is the
# accepted cost (same shape as #1837's own pending/confirm trade). A
# checkpoint only ever arms when that read found NOTHING pending and nothing
# stuck (review: an unread backlog or a delivery failure must never let the
# checkpoint arm just because the store's bytes happened not to move that
# cycle) -- callers decide that and call _watch_armed_fp_set/_drop
# accordingly; this file has no opinion of its own on when a read "succeeded".
#
# Watched: the db file AND its '-wal' sibling, not just the former -- WAL-mode
# writes land in the -wal file and are not folded back into the main db's own
# mtime until a checkpoint, so watching only the main file would never notice
# a write that stays in the WAL (the #1836/#1837 lesson, reproduced here
# rather than assumed). A non-sqlite driver has no '-wal' file; `stat` simply
# reports that one path as absent and still prints the rest, so the
# fingerprint still reflects the main file's own mtime+size.
#
# Safety net: a real check is forced at least once every
# AGMSG_WATCH_SKIP_SAFETY_NET_SECONDS regardless of how long a pair has
# looked unchanged, bounding exposure to anything this fingerprint cannot see
# (a plugin or partition change, a clock oddity). $SECONDS, not `date`: no
# subprocess, with the same wall-clock (non-monotonic) caveat watch.sh's own
# _INSTALL_INCOMPLETE_SINCE already accepts.
AGMSG_WATCH_SKIP_SAFETY_NET_SECONDS=60

# A literal tab, for building the maps below. `$'\t'` only expands inside an
# otherwise-double-quoted string when it sits directly inside a `${var:+...}`
# alternate-value word (bash gives that word its own expansion pass); typed
# bare between two other expansions in the SAME double-quoted string, as a
# per-field separator naturally ends up, it is not special at all and stays
# the four literal characters `$`, `'`, `\`, `t`. A plain variable expansion
# has no such special case, so holding the real byte here and expanding
# "$_WATCH_TAB" is correct in every position. (Caught by this feature's own
# first run: it silently forced every cycle, because the map it read back
# never actually contained a tab to split on.)
_WATCH_TAB=$'\t'

# <team> -> db_path, resolved once per team (a pure static path, not a
# liveness fact -- safe to share across every agent in that team) and reused
# with no subprocess for the rest of this process's life. Re-resolved only
# when the safety net below forces a real check for some pair of that team,
# so a store migrated mid-run (see lib/storage.sh's own epoch-cache comment
# for the same concern) is noticed within one safety-net window, not never.
_AGMSG_WATCH_DB_PATH_MAP=""

_watch_db_path_for() {   # <team> -- sets $_WATCH_DB_PATH
  local want="$1" k v
  if [ -n "$_AGMSG_WATCH_DB_PATH_MAP" ]; then
    while IFS=$'\t' read -r k v; do
      [ "$k" = "$want" ] || continue
      _WATCH_DB_PATH="$v"
      return 0
    done <<< "$_AGMSG_WATCH_DB_PATH_MAP"
  fi
  _WATCH_DB_PATH="$(agmsg_db_path "$want" 2>/dev/null)" || return 1
  [ -n "$_WATCH_DB_PATH" ] || return 1
  _AGMSG_WATCH_DB_PATH_MAP="${_AGMSG_WATCH_DB_PATH_MAP:+$_AGMSG_WATCH_DB_PATH_MAP$'\n'}${want}${_WATCH_TAB}${_WATCH_DB_PATH}"
  return 0
}

_watch_db_path_forget() {   # <team> -- drop the cached entry so it is re-resolved
  local drop="$1" k v out=""
  [ -n "$_AGMSG_WATCH_DB_PATH_MAP" ] || return 0
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] && continue
    [ "$k" = "$drop" ] && continue
    out="${out:+$out$'\n'}$k${_WATCH_TAB}$v"
  done <<< "$_AGMSG_WATCH_DB_PATH_MAP"
  _AGMSG_WATCH_DB_PATH_MAP="$out"
}

# One `stat` call, covering every path given, regardless of count -- the
# platform split mirrors lib/compat.sh's own compat_file_mtime/
# compat_file_size (mtime+size together, in one invocation, is not one of
# their existing forms). A path that does not exist (a non-WAL driver's
# missing '-wal' sibling, or a store not yet created) makes `stat` exit
# nonzero and say so on stderr, suppressed here, but it still PRINTS every
# surviving path's line first -- confirmed against both `stat` dialects --
# so the fingerprint still reflects whichever paths are actually there.
#
# Flattened to one line (internal newlines -> '|', a pure bash parameter
# expansion, no extra fork): every map in this file separates its records by
# newline, so a multi-path fingerprint's own newlines -- one per stat'd
# path -- would otherwise be indistinguishable from a second map record and
# silently truncate this value to its first line (caught by this feature's
# own first run: the '-wal' path's line vanished from the armed value,
# comparing clean against a fingerprint that never carried it).
_watch_fingerprint() {   # <path> [<path> ...] -- prints the fingerprint
  _agmsg_detect_platform
  local out
  case "$_agmsg_platform" in
    macos) out="$(stat -f '%m %z %N' "$@" 2>/dev/null)" ;;
    *)     out="$(stat -c '%Y %s %n' "$@" 2>/dev/null)" ;;
  esac
  printf '%s' "${out//$'\n'/|}"
  return 0
}

# <team:agent> -> the fingerprint (see _watch_fingerprint) this pair's
# checkpoint was armed with.
_AGMSG_WATCH_ARMED_FP=""

_watch_armed_fp_get() {   # <pair> -- sets $_WATCH_ARMED_FP, rc 1 if none
  local want="$1" k v
  [ -n "$_AGMSG_WATCH_ARMED_FP" ] || return 1
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$want" ] || continue
    _WATCH_ARMED_FP="$v"
    return 0
  done <<< "$_AGMSG_WATCH_ARMED_FP"
  return 1
}

_watch_armed_fp_set() {   # <pair> <fingerprint>
  local want="$1" fp="$2" k v out=""
  if [ -n "$_AGMSG_WATCH_ARMED_FP" ]; then
    while IFS=$'\t' read -r k v; do
      [ -z "$k" ] && continue
      [ "$k" = "$want" ] && continue
      out="${out:+$out$'\n'}$k${_WATCH_TAB}$v"
    done <<< "$_AGMSG_WATCH_ARMED_FP"
  fi
  _AGMSG_WATCH_ARMED_FP="${out:+$out$'\n'}$want${_WATCH_TAB}$fp"
}

_watch_armed_fp_drop() {   # <pair>
  local drop="$1" k v out=""
  [ -n "$_AGMSG_WATCH_ARMED_FP" ] || return 0
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] && continue
    [ "$k" = "$drop" ] && continue
    out="${out:+$out$'\n'}$k${_WATCH_TAB}$v"
  done <<< "$_AGMSG_WATCH_ARMED_FP"
  _AGMSG_WATCH_ARMED_FP="$out"
}

# <team:agent> -> seconds (from $SECONDS) of that pair's last real check, so
# the safety net above can tell how long it has been since one actually ran
# FOR THIS PAIR -- never shared across the agents of one team (review, same
# round as the fingerprint fix above: a team-wide clock let one pair's real
# check reset the whole team's safety net too).
_AGMSG_WATCH_FORCE_AT_MAP=""

_watch_safety_due() {   # <pair> -- 0 (true) if a real check is due
  local want="$1" k v
  [ -n "$_AGMSG_WATCH_FORCE_AT_MAP" ] || return 0
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$want" ] || continue
    [ $((SECONDS - v)) -ge "$AGMSG_WATCH_SKIP_SAFETY_NET_SECONDS" ]
    return $?
  done <<< "$_AGMSG_WATCH_FORCE_AT_MAP"
  return 0
}

_watch_safety_mark() {   # <pair> -- record that a real check just ran
  local want="$1" k v out=""
  if [ -n "$_AGMSG_WATCH_FORCE_AT_MAP" ]; then
    while IFS=$'\t' read -r k v; do
      [ -z "$k" ] && continue
      [ "$k" = "$want" ] && continue
      out="${out:+$out$'\n'}$k${_WATCH_TAB}$v"
    done <<< "$_AGMSG_WATCH_FORCE_AT_MAP"
  fi
  _AGMSG_WATCH_FORCE_AT_MAP="${out:+$out$'\n'}$want${_WATCH_TAB}$SECONDS"
}
