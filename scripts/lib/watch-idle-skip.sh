# watch-idle-skip.sh -- per-pair "did the local store change" checkpoint for
# the delivery watcher (#1842). Kept in its own file, same reasoning as
# lib/watch-stuck-map.sh: watch.sh runs on source, so its inline helpers could
# only ever be exercised through a timing-dependent end-to-end test, and the
# correctness properties here (per-pair isolation, pre-read vs. post-read
# fingerprint timing, same-second writes) are exactly the kind of thing that
# needs a direct, deterministic unit test rather than a real poll loop.
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
# rather than assumed).
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

# --- batched, subsecond fingerprinting (#1846 review round 2/3) ------------
#
# Defects found against earlier versions of this file:
#
# 1. `stat -f '%m'` (macOS) / `stat -c '%Y'` (GNU) truncate to whole SECONDS.
#    A same-second, same-size overwrite is then INDISTINGUISHABLE from no
#    write at all -- reproduced independently against a real store. Fixed
#    by asking for subsecond precision (`%Fm` / `%.9Y`, confirmed to
#    actually return it on both dialects) -- but a filesystem that
#    genuinely only has second resolution would still collide. Round 2
#    tracked "has subsecond precision ever been seen" as a single process-
#    lifetime flag; round 3 found that wrong twice over: (a) it is a
#    property of ONE path/filesystem, not the whole process -- a single
#    fractional reading from an unrelated path on a different volume
#    wrongly vouched for every store, including a genuinely coarse one; and
#    (b) only the DB's own mtime was checked for "too recent to trust", so
#    a WAL-mode write that lands only in the `-wal` file (the main db
#    staying untouched) on a coarse filesystem went unnoticed. Fixed by
#    judging each mtime VALUE on its own fractional part (see
#    _watch_mtime_has_subsecond), and checking BOTH the db's and, when it
#    exists, the wal's mtime for recency before arming.
#
# 2. `date +%s` was forked once per PAIR to get "now" for that recency
#    check. Hoisted to the caller (watch.sh calls it once per CYCLE and
#    passes the result into every pair's check this file makes) -- the
#    value does not need to be fresher than once a cycle for a check whose
#    whole tolerance is "within one second".
#
# 3. One `stat` invocation per PAIR per cycle still scales with how many
#    pairs a broad watcher serves, which is most of what a real report's
#    gap from this measurement turned out to be. `_watch_fingerprint_batch`
#    asks for every distinct path ACROSS EVERY PAIR this cycle serves in
#    ONE call; `_watch_fingerprint_lookup`/`_watch_pair_fingerprint` then
#    read back out of that single result with no further subprocess.

# <path> -> "<mtime> <size>", rebuilt fresh every cycle by
# _watch_fingerprint_batch (never carried over -- a stale entry would be
# exactly the kind of "looks unchanged" false negative this feature exists
# to avoid).
_AGMSG_WATCH_PATH_FP=""

_watch_fingerprint_batch() {   # <path> [<path> ...] -- one `stat` call
  _AGMSG_WATCH_PATH_FP=""
  [ $# -gt 0 ] || return 0
  _agmsg_detect_platform
  local out rc=0
  case "$_agmsg_platform" in
    macos) out="$(stat -f '%Fm %z %N' "$@" 2>/dev/null)" ;;
    *)     out="$(stat -c '%.9Y %s %n' "$@" 2>/dev/null)" ;;
  esac
  rc=$?
  local line mt rest sz
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mt="${line%% *}"; rest="${line#* }"
    sz="${rest%% *}"; rest="${rest#* }"
    # rest is now the path (may itself contain spaces; everything after the
    # first two fields belongs to it, per the `%N`/`%n` format above).
    _AGMSG_WATCH_PATH_FP="${_AGMSG_WATCH_PATH_FP:+$_AGMSG_WATCH_PATH_FP$'\n'}${rest}${_WATCH_TAB}${mt} ${sz}"
  done <<< "$out"
  return "$rc"
}

_watch_fingerprint_lookup() {   # <path> -- sets $_WATCH_PATH_FP, rc 1 if absent from the last batch
  local want="$1" k v
  [ -n "$_AGMSG_WATCH_PATH_FP" ] || return 1
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$want" ] || continue
    _WATCH_PATH_FP="$v"
    return 0
  done <<< "$_AGMSG_WATCH_PATH_FP"
  return 1
}

# <db_path> <wal_path> -- sets $_WATCH_FP from the current batch, plus
# $_WATCH_FP_DB_MTIME and $_WATCH_FP_WAL_MTIME (the latter empty when the
# wal does not exist) for _watch_fp_unsafe_to_arm to judge each on its own.
# rc 1 (unknown -- never skip, never arm) when the db's own line is missing
# (a real stat failure: permission, a vanished file past the caller's own
# existence check) or when the wal path EXISTS on disk but its line is
# missing too (exists-but-unreadable, never confused with the ordinary
# "no -wal sibling" case, which this checks with `[ -e ]` -- a builtin, no
# fork -- rather than trusting an absent stat line to mean "absent").
_watch_pair_fingerprint() {
  local db="$1" wal="$2" db_fp wal_fp
  _watch_fingerprint_lookup "$db" || return 1
  db_fp="$_WATCH_PATH_FP"
  _WATCH_FP_DB_MTIME="${db_fp%% *}"
  if [ -e "$wal" ]; then
    _watch_fingerprint_lookup "$wal" || return 1
    wal_fp="$_WATCH_PATH_FP"
    _WATCH_FP_WAL_MTIME="${wal_fp%% *}"
  else
    wal_fp="absent"
    _WATCH_FP_WAL_MTIME=""
  fi
  _WATCH_FP="${db_fp}|${wal_fp}"
  return 0
}

# True (rc 0) when <mtime> (as stat printed it: "<secs>.<frac>") carries no
# confirmed subsecond precision -- an all-zero or absent fractional part.
# Judged on THIS value alone, never latched process-wide (review round 3: a
# single fractional reading from one path/filesystem does not vouch for a
# different path that may sit on a genuinely coarser one).
_watch_mtime_has_subsecond() {   # <mtime>
  case "$1" in *.*[1-9]*) return 0 ;; *) return 1 ;; esac
}

# True (rc 0) when <mtime>'s whole-second component is within one second of
# <now_epoch> -- both plain integers, no fork: <now_epoch> is computed ONCE
# per CYCLE by the caller (watch.sh), not once per pair/path (review round
# 3), since this check's whole tolerance is "within one second" and a
# value at most one cycle stale cannot change that.
_watch_mtime_too_recent() {   # <mtime> <now_epoch>
  local mt="${1%%.*}" now="$2"
  case "$mt" in ''|*[!0-9]*) return 0 ;; esac
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ $((now - mt)) -le 1 ]
}

# True (rc 0, "unsafe to arm") when ANY of the given mtimes both lacks
# confirmed subsecond precision AND reads as within one second of
# <now_epoch> -- a value with real subsecond precision is trusted outright
# regardless of how recent it is; one without it is trusted only once it is
# old enough that a same-second collision is no longer possible. Checked
# over every mtime a pair's fingerprint actually carries (review round 3:
# checking only the db's own mtime missed a WAL-mode write that lands only
# in the `-wal` file, leaving the main db's mtime untouched).
_watch_fp_unsafe_to_arm() {   # <now_epoch> <mtime> [<mtime> ...]
  local now="$1" mt; shift
  for mt in "$@"; do
    [ -n "$mt" ] || continue
    if ! _watch_mtime_has_subsecond "$mt" && _watch_mtime_too_recent "$mt" "$now"; then
      return 0
    fi
  done
  return 1
}

# <team:agent> -> the fingerprint (see _watch_pair_fingerprint) this pair's
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
