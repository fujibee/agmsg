#!/usr/bin/env bash
# codex-session-index.sh — look up a Codex thread's current name in the CLI's
# own session_index.jsonl, instead of scraping the TUI's "Thread name:" header
# (which only ever prints once at the top of the screen and scrolls away).
#
# Takes the thread id as an ARGUMENT rather than reading $CODEX_THREAD_ID
# itself (#1386 continuation): the only place that env var
# names THIS process's own thread is self-observation (self-rename.sh, run as
# code the seat executes on itself); an outside observer checking a DIFFERENT
# seat's pane has no business reading its own $CODEX_THREAD_ID and calling
# that the other seat's thread. Keeping the id an argument means a future
# caller with a thread id from elsewhere (e.g. the role-session record's own
# `session=` field) can reuse this same lookup unchanged — team.sh's own
# outside-observation path is exactly that future caller, and wiring it in is
# explicitly left for a separate change, not this one.
#
# File location matches #1380's own CODEX_HOME handling: $CODEX_HOME if set,
# else ~/.codex — measured live (2026-09-23) that every agmsg-spawned Codex
# seat on this machine takes the fallback branch today (spawn.sh does not
# propagate a launching shell's CODEX_HOME into the spawned process; filed
# separately, not fixed here), but the env-first order is kept for whichever
# launch path DOES see it set.
#
# session_index.jsonl is append-only: a `/rename` (or any auto-title change)
# adds a NEW line for the same id rather than editing the old one in place
# (measured live: two successive /rename calls on one throwaway seat each
# produced their own line, ~instantly). So more than one line can share an
# id, and the one with the greatest updated_at is the current name — also
# measured, not assumed, via a controlled before/after rename sequence.

[ -n "${_AGMSG_CODEX_SESSION_INDEX_SH:-}" ] && return 0
_AGMSG_CODEX_SESSION_INDEX_SH=1

_agmsg_codex_session_index_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SKILL_DIR:=$(cd "$_agmsg_codex_session_index_dir/.." && pwd)}"
export SKILL_DIR
if ! declare -F agmsg_sqlite_mem >/dev/null 2>&1 || ! declare -F agmsg_sqlesc >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/storage.sh" 2>/dev/null || true
fi

# Prints the thread's current name, or a namespaced `unknown:<reason>` —
# never guesses, never falls back to any other source. Always returns 0.
#   <thread-id>
agmsg_codex_session_index_name() {   # <thread-id>
  local tid="$1" home path tmp line esc id ts name best_ts="" best_name=""
  [ -n "$tid" ] || { printf 'unknown:no_thread_id\n'; return 0; }
  if ! declare -F agmsg_sqlite_mem >/dev/null 2>&1 || ! declare -F agmsg_sqlesc >/dev/null 2>&1; then
    printf 'unknown:session_index_reader_unavailable\n'; return 0
  fi
  home="${CODEX_HOME:-${HOME:-}/.codex}"
  path="$home/session_index.jsonl"
  [ -n "$home" ] && [ -r "$path" ] || { printf 'unknown:session_index_unreadable\n'; return 0; }

  # A candidate-lines temp file, not a piped/captured while-loop: bash 3.2
  # cannot parse a while loop containing its own $(...) substitutions when the
  # whole loop is itself wrapped in an outer $(...) (the same shape
  # codex-record-session.sh's own thread-matching loop works around).
  tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg-codexsidx.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp" ] || { printf 'unknown:session_index_unreadable\n'; return 0; }
  # grep -F is a cheap pre-filter only (a line without this id's literal text
  # cannot match); every candidate still gets its `id` field compared exactly
  # below, so a coincidental substring match elsewhere in a line is harmless.
  # `--` keeps a $tid that happened to start with `-` from being read as an
  # option rather than the pattern (review).
  grep -F -- "$tid" "$path" 2>/dev/null > "$tmp" || true

  # An append in progress can leave the file's own last line truncated
  # mid-write; a malformed candidate must be SKIPPED, never let a failed
  # json_extract abort this whole function before `rm -f "$tmp"` below runs
  # (review: every substitution here was unguarded, so a caller running under
  # `set -e`+pipefail would have the malformed line's sqlite failure exit the
  # function immediately, mid-loop, cleanup and all). `|| continue` on each
  # one keeps a bad line as just another non-matching candidate.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    esc="$(agmsg_sqlesc "$line")"
    id="$(agmsg_sqlite_mem "SELECT COALESCE(json_extract('$esc','\$.id'),'')" 2>/dev/null)" || continue
    [ "$id" = "$tid" ] || continue
    ts="$(agmsg_sqlite_mem "SELECT COALESCE(json_extract('$esc','\$.updated_at'),'')" 2>/dev/null)" || continue
    name="$(agmsg_sqlite_mem "SELECT COALESCE(json_extract('$esc','\$.thread_name'),'')" 2>/dev/null)" || continue
    [ -n "$ts" ] && [ -n "$name" ] || continue
    # ISO-8601 UTC timestamps, fixed width, sort correctly as plain strings —
    # measured on this machine's own real index ("2026-09-23T20:05:43.254047Z"
    # style throughout), so a string comparison is exact, not an approximation.
    if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; then
      best_ts="$ts"
      best_name="$name"
    fi
  done < "$tmp"
  rm -f "$tmp"

  [ -n "$best_name" ] || { printf 'unknown:thread_not_in_index\n'; return 0; }
  # Same malformed-name guard as agmsg_cli_session_observed's screen path
  # (team-status.sh): a session name is short with no control bytes; anything
  # else cannot be trusted into a TAB-separated record or compared for a
  # rename decision.
  case "$best_name" in *[[:cntrl:]]*) printf 'unknown:name_malformed\n'; return 0 ;; esac
  [ "${#best_name}" -le 128 ] || { printf 'unknown:name_malformed\n'; return 0; }
  printf '%s\n' "$best_name"
}
