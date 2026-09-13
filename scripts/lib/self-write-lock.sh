#!/usr/bin/env bash
# self-write-lock.sh -- a seat's own single-flight lock around its self-writes.
#
# WHAT IT EXCLUDES. One seat, several processes that may all try to write the
# seat's identity cells (placement record, pane label, agent key, session name)
# at the same moment: a watcher that restarted while its predecessor was still
# mid-write, two watchers on one seat (measured), a request re-issued before the
# first one finished. Two writers interleaving on one seat queue two CLI commands
# into one pane and leave the cells half from each; the once-only property of a
# session rename (#1081) does not vanish when its stored mark goes, it moves to
# whoever writes -- and that is this lock.
#
# WHAT IT IS NOT. It is NOT the leader/seat exchange lock (run/self-fix.*). That
# one guards a protocol between two parties and may disappear with the protocol;
# this one guards one party against itself and stays. They share no name, no
# path and no API on purpose: deleting one must not delete the other, and a
# design that finds "a lock already exists" must not borrow this one for the
# other job.
#
#   Lock file: $SKILL_DIR/run/self-write.<team>__<agent>.lock
#   Content  : one line -- the owner token, the writer's composite instance id
#              (<sid>.<pid>) as agmsg_instance_alive judges it.
#
# WHAT IT REUSES. The publish and reclaim are actas-lock.sh's, addressed by path
# (_agmsg_lock_try_claim_at / agmsg_lock_claim_at / agmsg_lock_release_at): the
# owner is written to a temp file, read back, and hard-linked into place, so a
# claimant that dies before the link leaves an orphan temp and NO lock -- the
# next claim links into the gap without any reclaim. A lock whose owner is
# POSITIVELY dead is reclaimed under a per-lock mutex after re-reading the owner;
# "could not read" and "could not tell" are never reclaimed and never treated as
# free. There is no time-based reclaim: a lock is held until released or until
# its owner is proven dead.
#
# WHAT A CALLER SEES. Three answers, never silence:
#   agmsg_self_write_lock_acquire  -> rc 0 "ok"
#                                     rc 1 "busy:<owner>"      someone alive holds it
#                                     rc 2 "unknown:<reason>"  could not establish who
# "busy" is a fact the caller must surface (the self-fix header's `none:busy`),
# because a dropped attempt and an attempt in progress look identical from the
# outside -- the shape that cost the most on 2026-09-11.

# shellcheck disable=SC1091
. "${SKILL_DIR:?SKILL_DIR must be set}/scripts/lib/actas-lock.sh"

agmsg_self_write_lock_path() {   # <team> <agent>
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/self-write.%s__%s.lock' "$(_actas_lock_dir)" "$t" "$a"
}

# Acquire for <owner>. Prints exactly one verdict line (see header). Re-acquiring
# a lock this owner already holds is "ok" (the shared core answers `mine`).
agmsg_self_write_lock_acquire() {   # <team> <agent> <owner>
  local team="$1" agent="$2" owner="$3" result
  [ -n "$owner" ] || { echo "unknown:owner_empty"; return 2; }
  # The verdict LINE decides, not the exit status: the shared core prints one on
  # every path (a silent failure there once read as success, #983), so the
  # status is deliberately not consulted here.
  result="$(agmsg_lock_claim_at "$(agmsg_self_write_lock_path "$team" "$agent")" "$owner" || true)"
  case "$result" in
    ok)        echo ok; return 0 ;;
    held:*)    printf 'busy:%s\n' "${result#held:}"; return 1 ;;
    unknown:*) printf '%s\n' "$result"; return 2 ;;
    *)         printf 'unknown:unclassified:%s\n' "$result"; return 2 ;;
  esac
}

# Release if, and only if, <owner> is the recorded owner. Idempotent; never
# touches a lock that is unreadable, empty, or held by another owner.
agmsg_self_write_lock_release() {   # <team> <agent> <owner>
  agmsg_lock_release_at "$(agmsg_self_write_lock_path "$1" "$2")" "$3"
}

# Is <owner> the recorded owner right now? rc 0 yes; rc 1 no (free, someone
# else, or empty); rc 2 could not read. Prints the verdict from the shared
# three-valued reader so a caller can show WHY, not only whether.
agmsg_self_write_lock_held_by() {   # <team> <agent> <owner>
  local lock _r _v verdict
  lock="$(agmsg_self_write_lock_path "$1" "$2")"
  _r="$(_actas_lock_read_path "$lock")"
  _v="$(_actas_lock_verdict "$3" "${_r%%$'\t'*}" "${_r#*$'\t'}")"
  verdict="${_v%%$'\t'*}"
  printf '%s\n' "$verdict"
  case "$verdict" in
    mine)      return 0 ;;
    unknown:*) return 2 ;;
    *)         return 1 ;;
  esac
}
