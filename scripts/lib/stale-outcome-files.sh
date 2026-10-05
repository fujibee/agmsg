#!/usr/bin/env bash
# Finding and removing the storage sync driver's leaked outcome files
# (#1572: storage_sync_apply_pull and storage_sync_apply_read_state each
# used to overwrite storage-sync-driver.sh's own EXIT trap without
# restoring it, so AGMSG_SQLITE_OUTCOME_FILE -- a bare `mktemp`, default
# name -- was never removed on an ordinary successful "apply" or
# "read-apply" call. Fixed there; this is the one-time cleanup for
# whatever already accumulated before that fix, on an install made before
# it. Not sourced into every script: only install.sh's --update and
# doctor.sh need it.
#
# Only a file matching ALL FOUR of these is ever removed -- another tool
# could, in principle, happen to create a file matching every one of them
# too (nothing here can rule that out by construction), but it is these
# four conditions together, not an attempt to recognize this driver's
# files specifically, that decide what goes:
#   - location: directly under the install's own temp directory
#     (${TMPDIR:-/tmp}), never a subdirectory.
#   - name: exactly `tmp.` followed by 10 characters from [A-Za-z0-9] --
#     mktemp(1)'s default template (coreutils and BSD/macOS agree on this
#     one, confirmed on both).
#   - size: exactly 3, 5, or 7 bytes -- the length of "ok\n", "busy\n", or
#     "failed\n", checked by `find -size` BEFORE any content is read, so a
#     same-named file that is merely similar in size and starts the same
#     way (e.g. "ok\n" plus a trailing NUL -- 4 bytes, which `read` alone
#     would not have told apart from 3, since it drops a trailing NUL the
#     same way it drops a trailing newline) is excluded before that point.
#   - content: byte-exact "ok", "busy", or "failed" given the exact size
#     already pinned above (the only three values _agmsg_sqlite_recording
#     in lib/storage.sh ever writes there).
#   - age: older than AGMSG_STALE_OUTCOME_MIN_AGE_S (default 600s/10min),
#     so a driver that is still mid-call right now and has not reached its
#     own cleanup yet is never mistaken for one of these.
#
# No external command runs per candidate: `find` alone decides location,
# name, size and age (its own -name/-size/-mmin, no -exec), and the
# content check is a plain `read` redirection -- a shell builtin, not a
# fork. Only the removal batches into chunks of external `rm` calls (and
# one `comm`/`sort` pair for the re-check -- see
# agmsg_remove_stale_outcome_files), not one call per file, because an
# install can be cleaning up several hundred thousand of these.

_agmsg_stale_outcome_dir() {
  printf '%s\n' "${TMPDIR:-/tmp}"
}

# One path per line, oldest-mtime-unordered. Caller decides what to do with
# them (print examples, count, remove). Never fails outright: a temp
# directory this cannot read yields no candidates, not an error, since
# finding none of these is the common and correct case on a fixed install.
agmsg_stale_outcome_candidates() {
  local dir min_age f base line extra
  dir="$(_agmsg_stale_outcome_dir)"
  [ -d "$dir" ] || return 0
  min_age="${AGMSG_STALE_OUTCOME_MIN_AGE_S:-600}"
  case "$min_age" in ''|*[!0-9]*) min_age=600 ;; esac
  # `find -mmin` only resolves whole minutes; a sub-minute override (tests
  # use 0, to tell an artificially backdated sample from one just created
  # without a real wait) rounds down to the whole minute it is less than,
  # never up to one it is not -- 0 therefore reaches find as +0 (anything
  # with a completed minute of age), not +1 (which a file made moments ago
  # has not reached and never incorrectly would).
  local min_minutes=$((min_age / 60))
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    [[ "$base" =~ ^tmp\.[A-Za-z0-9]{10}$ ]] || continue
    # Size is already exactly 3, 5, or 7 (find's -size above), so a plain
    # `read -r line` capturing one line and a second `read` confirming
    # nothing follows it is enough to pin the content byte-for-byte --
    # no NUL-vs-newline ambiguity is reachable once the size is this exact.
    line="" extra=""
    { IFS= read -r line && ! IFS= read -r extra; } < "$f" 2>/dev/null || continue
    [ -z "$extra" ] || continue
    case "$line" in
      ok|busy|failed) printf '%s\n' "$f" ;;
    esac
  done < <(find "$dir" -maxdepth 1 -type f -name 'tmp.??????????' \
    \( -size 3c -o -size 5c -o -size 7c \) -mmin "+$min_minutes" 2>/dev/null)
}

# Removes the paths given on stdin (one per line, as
# agmsg_stale_outcome_candidates printed them to whoever is calling this --
# doctor.sh's --fix prints them for confirmation first, install.sh pipes
# them straight through). Between that scan and this call a real amount of
# time can pass (doctor.sh waits on a y/n prompt), so every path is
# re-checked against a FRESH scan right here rather than removed on the
# strength of the original one: re-runs agmsg_stale_outcome_candidates (one
# process, the same `find` as above, not one stat/read per path) and only
# removes paths that are in BOTH that fresh result and what was passed in,
# via one `sort`+`comm` pair rather than a per-file check. A path whose
# content, size, or age no longer matches -- or that is simply gone -- drops
# out of the fresh scan and is left alone; a path that appeared after the
# original scan (so was never shown to, or approved by, whoever is calling
# this) is never in the input and is equally left alone.
#
# Prints the removed count on one line, as the caller's own last act -- not
# a running tally, so a huge count never slows down by printing one line
# per file.
agmsg_remove_stale_outcome_files() {
  local approved fresh intersection removed=0 chunk=() path
  approved="$(mktemp)" || { printf '0\n'; return 1; }
  fresh="$(mktemp)" || { rm -f "$approved"; printf '0\n'; return 1; }
  intersection="$(mktemp)" || { rm -f "$approved" "$fresh"; printf '0\n'; return 1; }
  cat > "$approved"
  agmsg_stale_outcome_candidates > "$fresh"
  LC_ALL=C sort -o "$approved" "$approved"
  LC_ALL=C sort -o "$fresh" "$fresh"
  LC_ALL=C comm -12 "$approved" "$fresh" > "$intersection"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    chunk+=("$path")
    if [ "${#chunk[@]}" -ge 500 ]; then
      rm -f "${chunk[@]}" 2>/dev/null
      removed=$((removed + ${#chunk[@]}))
      chunk=()
    fi
  done < "$intersection"
  if [ "${#chunk[@]}" -gt 0 ]; then
    rm -f "${chunk[@]}" 2>/dev/null
    removed=$((removed + ${#chunk[@]}))
  fi
  rm -f "$approved" "$fresh" "$intersection"
  printf '%s\n' "$removed"
}
