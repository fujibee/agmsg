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
#   - size paired to content: exactly 3 bytes and "ok", exactly 5 and
#     "busy", or exactly 7 and "failed" -- never any of the three words
#     at any OTHER of the three sizes. A bash variable cannot hold a NUL
#     byte at all (read into one drops it, the same way it drops a
#     trailing newline), so content alone can never tell "busy\n" (5
#     bytes) apart from "ok\n" plus two trailing NULs (also 5 bytes) --
#     `read` on either yields the same two-character string. Pairing each
#     size to the one word that size could ever legitimately hold closes
#     that: the second example above is checked only against "busy" (its
#     actual size's word), not "ok", and is correctly refused.
#   - age: older than AGMSG_STALE_OUTCOME_MIN_AGE_S (default 600s/10min),
#     so a driver that is still mid-call right now and has not reached its
#     own cleanup yet is never mistaken for one of these.
#
# No external command runs per candidate: `find` alone decides location,
# name, size and age (its own -name/-size/-mmin, no -exec, one call per
# size/word pair -- three total, not one per file), and the content check
# is a plain `read` redirection -- a shell builtin, not a fork. Only the
# removal batches into chunks of external `rm` calls (and one `comm`/
# `sort` pair for the re-check -- see agmsg_remove_stale_outcome_files),
# not one call per file, because an install can be cleaning up several
# hundred thousand of these.
#
# Both entry points are safe to call from a `set -e`/`pipefail` caller
# (install.sh, doctor.sh both run under it) and never abort one: a failure
# inside either -- an unreadable temp directory, a mktemp that cannot
# create a scratch file (the same condition this whole cleanup exists
# for: a full temp filesystem) -- is reported on stderr and otherwise
# treated as "found/removed nothing this time", never as a reason to stop
# whatever called this.

_agmsg_stale_outcome_dir() {
  printf '%s\n' "${TMPDIR:-/tmp}"
}

# One path per line, oldest-mtime-unordered. Caller decides what to do with
# them (print examples, count, remove).
agmsg_stale_outcome_candidates() {
  local dir min_age min_minutes size word f base line extra
  dir="$(_agmsg_stale_outcome_dir)" || return 0
  [ -d "$dir" ] || return 0
  min_age="${AGMSG_STALE_OUTCOME_MIN_AGE_S:-600}"
  case "$min_age" in ''|*[!0-9]*) min_age=600 ;; esac
  # `find -mmin` only resolves whole minutes; a sub-minute override (tests
  # use 0, to tell an artificially backdated sample from one just created
  # without a real wait) rounds down to the whole minute it is less than,
  # never up to one it is not -- 0 therefore reaches find as +0 (anything
  # with a completed minute of age), not +1 (which a file made moments ago
  # has not reached and never incorrectly would).
  min_minutes=$((min_age / 60))
  for size in 3:ok 5:busy 7:failed; do
    word="${size#*:}"; size="${size%%:*}"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base="${f##*/}"
      [[ "$base" =~ ^tmp\.[A-Za-z0-9]{10}$ ]] || continue
      # Size is already pinned to exactly $size bytes (find -size below),
      # and that is paired to exactly one word -- see the header comment
      # for why content alone, at any size, is not enough on its own.
      line="" extra=""
      { IFS= read -r line && ! IFS= read -r extra; } < "$f" 2>/dev/null || continue
      [ -z "$extra" ] || continue
      [ "$line" = "$word" ] && printf '%s\n' "$f"
    done < <(find "$dir" -maxdepth 1 -type f -name 'tmp.??????????' \
      -size "${size}c" -mmin "+$min_minutes" 2>/dev/null)
  done
  return 0
}

# Removes the paths given on stdin (one per line, as
# agmsg_stale_outcome_candidates printed them to whoever is calling this --
# doctor.sh's --fix prints them for confirmation first, install.sh pipes
# them straight through). Between that scan and this call a real amount of
# time can pass (doctor.sh waits on a y/n prompt), so every path is
# re-checked against a FRESH scan right here rather than removed on the
# strength of the original one: re-runs agmsg_stale_outcome_candidates (a
# handful of `find` calls total, not one stat/read per path) and only
# removes paths present in BOTH that fresh result and what was passed in,
# via one `sort`+`comm` pair rather than a per-file check. A path whose
# content, size, or age no longer matches -- or that is simply gone -- drops
# out of the fresh scan and is left alone; a path that appeared only after
# the original scan (so was never shown to, or approved by, whoever called
# this) is never in the input and is equally left alone.
#
# Always prints a count and returns 0, even when nothing could be removed
# for a reason that is itself an error (a scratch file could not be made --
# see the header comment): the caller treats that the same as "removed
# none", not as its own reason to stop.
agmsg_remove_stale_outcome_files() {
  local approved fresh intersection removed=0 chunk=() path
  approved="$(mktemp 2>/dev/null)" || {
    echo "agmsg: stale-outcome-files: could not create a scratch file; removed nothing" >&2
    printf '0\n'; return 0
  }
  fresh="$(mktemp 2>/dev/null)" || {
    echo "agmsg: stale-outcome-files: could not create a scratch file; removed nothing" >&2
    rm -f "$approved"; printf '0\n'; return 0
  }
  intersection="$(mktemp 2>/dev/null)" || {
    echo "agmsg: stale-outcome-files: could not create a scratch file; removed nothing" >&2
    rm -f "$approved" "$fresh"; printf '0\n'; return 0
  }
  cat > "$approved" 2>/dev/null
  agmsg_stale_outcome_candidates > "$fresh" 2>/dev/null
  LC_ALL=C sort -o "$approved" "$approved" 2>/dev/null
  LC_ALL=C sort -o "$fresh" "$fresh" 2>/dev/null
  LC_ALL=C comm -12 "$approved" "$fresh" > "$intersection" 2>/dev/null
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
  return 0
}
