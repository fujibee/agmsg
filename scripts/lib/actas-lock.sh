#!/usr/bin/env bash
# actas-lock.sh — per-(team, agent) exclusivity locks.
#
# Background: agmsg supports a project being registered with multiple agent
# identities of the same type (claude-code/codex/...). Without ownership
# tracking, every concurrent CC session in that project would subscribe to
# every registered identity's messages — duplicate delivery, confused mark-
# read semantics, and the `actas` "exclusive role" model breaking down.
#
# This file implements a small filesystem-based ownership protocol:
#
#   Lock file: $SKILL_DIR/run/actas.<team>__<agent>.session
#   Content  : one line — the owner session_id.
#
# A session_id is alive iff some $SKILL_DIR/run/cc-instance.<pid> file
# currently contains it AND that PID is alive. The same primitive used by
# session-start.sh's orphan-watcher cleanup. Stale locks (owner is no
# longer alive) are reclaimable.
#
# Atomic claim is implemented via `ln` of a per-call tmp file. POSIX
# guarantees the link target either appears or doesn't, even under
# concurrent claim attempts.
#
# Required caller-set variable:
#   SKILL_DIR — agmsg skill root.

: "${SKILL_DIR:?actas-lock.sh requires SKILL_DIR}"

# Owner tokens are per-process instance ids (see instance-id.sh), not bare
# session_ids — this is what keeps parallel --continue/--resume sessions that
# share a session_id from each appearing to own the other's locks (#93). The
# liveness check (actas_lock_sid_alive) delegates to agmsg_instance_alive.
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/instance-id.sh"
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/actas-reclaim-mutex.sh"

_actas_lock_dir() { printf '%s/run' "$SKILL_DIR"; }

# Encode a team or agent name into a filesystem-safe form. Anything outside
# [A-Za-z0-9._-] is percent-encoded byte-by-byte (UTF-8 safe, reversible).
# An earlier underscore-replacement scheme was lossy: "foo bar" and "foo_bar"
# collided on the same lock file, as did every Japanese team name (every
# non-ASCII byte mapped to "_"). #65 review, finding 2.
_actas_lock_encode() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (n = 0; n < 256; n++) ord[sprintf("%c", n)] = n }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._\-]/) printf "%s", c
        else printf "%%%02X", ord[c]
      }
    }
  '
}

# Compute the lock file path for (team, agent).
actas_lock_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$t" "$a"
}

# Readiness sentinel path for (team, agent). watch.sh creates this when an
# exclusive (actas) watcher attaches and removes it on exit, so the file is
# present iff a live watcher is currently receiving for that role. `spawn`
# uses it to block until a freshly launched agent is actually listening,
# instead of racing the agent's first push. Same encoding as the lock path so
# both scripts agree without env plumbing. See #108.
agmsg_ready_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/ready.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Placement record path for a spawned (team, agent). `spawn` writes the
# member's tmux target id + project + type here at launch time so that
# `despawn --force` can tear the member down (kill its pane/window, drop its
# registration) even when the member's own watcher is dead and can't respond
# to a ctrl:despawn. Same encoding as the lock path. See #109.
agmsg_spawn_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/spawn.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Read the complete first-line lock record. Empty if no lock or unreadable.
# The baseline record is the existing one-line owner. Keeping the delete helper
# comparison against this complete snapshot leaves an explicit seam for #519's
# future generation-bearing record without changing the #68 wire format.
actas_lock_record() {
  local lock; lock="$(actas_lock_path "$1" "$2")"
  [ -f "$lock" ] || { printf ''; return 0; }
  head -1 "$lock" 2>/dev/null
}

# Read only the owner field for the existing public callers.
actas_lock_owner() {
  local record
  record="$(actas_lock_record "$1" "$2")"
  printf '%s' "${record%%$'\t'*}"
}

# Return 0 if the given owner token is alive. The token is a per-process
# instance id (composite "<sid>.<pid>" or bare "<sid>" fallback); liveness is
# delegated to agmsg_instance_alive (composite → kill -0 the embedded pid; bare
# → live cc-instance.<pid> scan, with upgrade compat). Kept as a thin wrapper
# so existing callers (gc_stale, watch.sh subscription, session-start GC) need
# no change. Empty token → not alive.
actas_lock_sid_alive() {
  agmsg_instance_alive "$1"
}

# Isolated so tests can deterministically prove a failed record write is checked
# before ln(1). Production remains the single printf used by the wire format.
_actas_lock_write_temp_record() {
  printf '%s\n' "$1" > "$2"
}

# Internal: attempt one atomic claim. Always emits exactly one result token:
# "ok", "held:<sid>", "stale", "retry", or "error:<reason>". The public
# wrapper below owns the exit-code contract; keeping this probe token-based
# avoids `set -e` callers losing an internal failure inside command substitution.
_actas_lock_try_claim() {
  local team="$1" agent="$2" sid="$3"
  local lock dir tmp existing
  lock="$(actas_lock_path "$team" "$agent")"
  dir="$(_actas_lock_dir)"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "error:claim-io"
    return 0
  fi

  if ! tmp="$(mktemp "$dir/.actas-claim.XXXXXX" 2>/dev/null)"; then
    echo "error:claim-io"
    return 0
  fi
  # Never link an empty/partial record after a failed write. The temp pathname
  # is private to this call, so cleanup is safe and must happen on every branch.
  if ! _actas_lock_write_temp_record "$sid" "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "error:claim-io"
    return 0
  fi

  if ln "$tmp" "$lock" 2>/dev/null; then
    if ! rm -f "$tmp" 2>/dev/null; then
      # The lock link was installed, but the private temp name leaked. Surface
      # an error so the caller aborts instead of subscribing on degraded I/O.
      echo "error:claim-temp-cleanup"
      return 0
    fi
    echo "ok"
    return 0
  fi
  if ! rm -f "$tmp" 2>/dev/null; then
    echo "error:claim-io"
    return 0
  fi

  # EEXIST is the normal ln failure. If the contender disappeared before the
  # read, retry the atomic claim. A non-regular or unreadable contender is an
  # I/O error, never a stale lock authorization.
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    echo "retry"
    return 0
  fi
  if [ ! -f "$lock" ] || ! existing="$(head -1 "$lock" 2>/dev/null)"; then
    echo "error:lock-io"
    return 0
  fi
  existing="${existing%%$'\t'*}"
  if [ "$existing" = "$sid" ]; then
    echo "ok"
    return 0
  fi
  if [ -z "$existing" ] || ! actas_lock_sid_alive "$existing"; then
    echo "stale"
    return 0
  fi
  printf 'held:%s\n' "$existing"
  return 0
}

# Claim (team, agent) for session_id.
# Exit codes:
#   0  — claimed (now owned by this sid, was already ours, or stale-replaced).
#   1  — held by another live session. Stdout: "held:<other_sid>".
#   2  — internal/I/O/reclaim failure. Stdout: "error:<reason>".
# Every non-zero return emits one structured line; callers must preserve both
# the status and token rather than appending `|| true` to command substitution.
actas_lock_claim() {
  local team="$1" agent="$2" sid="$3"
  local attempts=0 result lock_path delete_status
  lock_path="$(actas_lock_path "$team" "$agent")"
  while [ "$attempts" -lt 3 ]; do
    result="$(_actas_lock_try_claim "$team" "$agent" "$sid")"
    case "$result" in
      ok) return 0 ;;
      stale)
        # The fixed helper owns a generation-qualified SQLite mutex row,
        # re-checks liveness, then becomes the final rm process via exec.  A
        # paused live helper is never timed out; a killed helper cannot leave
        # an orphan rm child that later deletes a replacement pathname.
        if _actas_lock_delete_stale "$lock_path" >/dev/null 2>&1; then
          delete_status=0
        else
          delete_status=$?
        fi
        case "$delete_status" in
          0|3|7)
            # 7 means a peer removed the stale pathname while this helper
            # waited for the mutex. It is the same bounded claim race as a
            # failed ln followed by a vanished contender, not lock I/O.
            attempts=$((attempts + 1))
            continue
            ;;
          4) echo "error:legacy-reclaim-marker"; return 2 ;;
          5) echo "error:reclaim-unavailable"; return 2 ;;
          6) echo "error:lock-io"; return 2 ;;
          2) echo "error:reclaim-invalid-path"; return 2 ;;
          *) echo "error:reclaim-io"; return 2 ;;
        esac
        ;;
      retry)
        attempts=$((attempts + 1))
        continue
        ;;
      held:*)
        printf '%s\n' "$result"
        return 1
        ;;
      error:*)
        printf '%s\n' "$result"
        return 2
        ;;
    esac
    echo "error:claim-internal"
    return 2
  done
  echo "error:claim-retry-exhausted"
  return 2
}

_actas_lock_delete_exact() {
  bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" exact "$1" "$2"
}

_actas_lock_delete_stale() {
  bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" stale "$1"
}

# Checked read of an exact lock path. Return 0 for a readable regular file, 1
# for absence, and 2 for a present but unreadable/non-regular path. The record
# is returned in AGMSG_ACTAS_LOCK_READ_RECORD so a readable zero-byte file stays
# distinguishable from absence.
AGMSG_ACTAS_LOCK_READ_RECORD=""
_actas_lock_read_path_checked() {
  local lock="$1" record
  AGMSG_ACTAS_LOCK_READ_RECORD=""
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    return 1
  fi
  [ -f "$lock" ] || return 2
  if ! record="$(head -1 "$lock" 2>/dev/null)"; then
    return 2
  fi
  AGMSG_ACTAS_LOCK_READ_RECORD="$record"
  return 0
}

# Attempt one mutex-protected exact release. Success proves the path is absent
# or its readable current owner is no longer `sid`. If the helper fails, re-read
# instead of assuming failure means retention: a peer may already have removed
# or replaced the exact snapshot. An unreadable state cannot prove release and
# therefore fails closed.
_actas_lock_release_path_checked() {
  local lock="$1" sid="$2" read_status record owner
  if _actas_lock_read_path_checked "$lock"; then
    read_status=0
  else
    read_status=$?
  fi
  case "$read_status" in
    1) return 0 ;;
    2) return 1 ;;
  esac
  record="$AGMSG_ACTAS_LOCK_READ_RECORD"
  owner="${record%%$'\t'*}"
  [ "$owner" = "$sid" ] || return 0

  if _actas_lock_delete_exact "$lock" "$record" >/dev/null 2>&1; then
    return 0
  fi

  if _actas_lock_read_path_checked "$lock"; then
    read_status=0
  else
    read_status=$?
  fi
  case "$read_status" in
    1) return 0 ;;
    2) return 1 ;;
  esac
  owner="${AGMSG_ACTAS_LOCK_READ_RECORD%%$'\t'*}"
  [ "$owner" != "$sid" ]
}

actas_lock_release_checked() {
  local team="$1" agent="$2" sid="$3" lock
  lock="$(actas_lock_path "$team" "$agent")"
  _actas_lock_release_path_checked "$lock" "$sid"
}

# Best-effort compatibility wrapper used by cleanup paths that historically
# treated release as idempotent. Transactional callers use the checked form or
# actas_lock_rollback_pairs below so incomplete cleanup is diagnosed.
actas_lock_release() {
  actas_lock_release_checked "$1" "$2" "$3" >/dev/null 2>&1 || true
  return 0
}

# Best-effort rollback for a tab-separated set of team/agent pairs. Destructive
# work always goes through the checked exact-release primitive. On incomplete
# cleanup, prints the retained pairs as comma-separated, percent-encoded
# `team/agent` labels and returns 1; complete cleanup prints nothing and returns
# 0. Group rollback is not atomic: infrastructure recovery (and ultimately
# #519 generation-bearing records) is required before retained locks can be
# released safely.
actas_lock_rollback_pairs() {
  local pairs="$1" sid="$2" team agent label retained="" failed=0
  while IFS=$'\t' read -r team agent; do
    [ -z "$team" ] && continue
    if actas_lock_release_checked "$team" "$agent" "$sid"; then
      continue
    fi
    label="$(_actas_lock_encode "$team")/$(_actas_lock_encode "$agent")"
    retained="${retained:+$retained,}$label"
    failed=1
  done <<< "$pairs"
  printf '%s' "$retained"
  [ "$failed" -eq 0 ]
}

# Release every lock currently owned by the given session_id. Used by
# session-end.sh when a CC session exits.
actas_lock_release_all() {
  local sid="$1"
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    _actas_lock_release_path_checked "$f" "$sid" >/dev/null 2>&1 || true
  done
  return 0
}

# Garbage-collect locks whose owner session_id is no longer alive.
# Returns the number of locks reclaimed on stdout (for observability).
actas_lock_gc_stale() {
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f count=0
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    if _actas_lock_delete_stale "$f" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Classify a (team, agent) pair relative to the calling session.
# Echoes one of: free | mine | other:<sid>
actas_lock_state() {
  local team="$1" agent="$2" sid="$3"
  local owner
  owner="$(actas_lock_owner "$team" "$agent")"
  if [ -z "$owner" ]; then
    echo "free"; return 0
  fi
  if [ "$owner" = "$sid" ]; then
    echo "mine"; return 0
  fi
  if actas_lock_sid_alive "$owner"; then
    printf 'other:%s\n' "$owner"
  else
    echo "free"  # stale owner — effectively free, GC will remove it later
  fi
}
