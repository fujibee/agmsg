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
# A candidate must satisfy ALL FOUR, so this never touches another tool's
# temp file:
#   - location: directly under the install's own temp directory
#     (${TMPDIR:-/tmp}), never a subdirectory -- other tools' own scratch
#     dirs under the same root are left alone.
#   - name: exactly `tmp.` followed by 10 characters from [A-Za-z0-9] --
#     both mktemp(1)'s default template (coreutils and BSD/macOS agree on
#     this one, confirmed on both).
#   - content: byte-exact "ok", "busy", or "failed" (the three values
#     _agmsg_sqlite_recording in lib/storage.sh ever writes there) -- one
#     line, nothing else, checked by length first since that rules out
#     all but a handful of candidates before any content read.
#   - age: older than AGMSG_STALE_OUTCOME_MIN_AGE_S (default 600s/10min),
#     so a driver that is still mid-call right now and has not reached its
#     own cleanup yet is never mistaken for one of these.
#
# No external command runs per candidate: `find` alone decides location,
# name and age (its own -name/-mmin, no -exec), and the content check
# below is a plain `read` redirection -- a shell builtin, not a fork. Only
# the removal batches into chunks of external `rm` calls, not one per file,
# because an install can be cleaning up several hundred thousand of these.

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
    # The content check below is read/[[ (shell builtins), no fork per
    # candidate -- `wc`/`stat` would each be one. A plain `read -r line`
    # already rules out length: it strips the one trailing newline these
    # files hold, so matching the three exact words below also rules out
    # anything longer. A SECOND read confirms there is no second line (a
    # genuine one-line "ok"/"busy"/"failed" file has nothing left to read).
    line="" extra=""
    { IFS= read -r line && ! IFS= read -r extra; } < "$f" 2>/dev/null || continue
    [ -z "$extra" ] || continue
    case "$line" in
      ok|busy|failed) printf '%s\n' "$f" ;;
    esac
  done < <(find "$dir" -maxdepth 1 -type f -name 'tmp.??????????' -mmin "+$min_minutes" 2>/dev/null)
}

# Removes exactly the paths given on stdin (one per line, as
# agmsg_stale_outcome_candidates prints them), in chunks rather than one
# `rm` per file or one `rm` for all of them (argv would not hold several
# hundred thousand paths). Prints the removed count on one line, as the
# caller's own last act -- not a running tally, so a huge count never
# slows down by printing one line per file.
agmsg_remove_stale_outcome_files() {
  local chunk=() removed=0 path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    chunk+=("$path")
    if [ "${#chunk[@]}" -ge 500 ]; then
      rm -f "${chunk[@]}" 2>/dev/null
      removed=$((removed + ${#chunk[@]}))
      chunk=()
    fi
  done
  if [ "${#chunk[@]}" -gt 0 ]; then
    rm -f "${chunk[@]}" 2>/dev/null
    removed=$((removed + ${#chunk[@]}))
  fi
  printf '%s\n' "$removed"
}
