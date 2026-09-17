#!/usr/bin/env bash
set -euo pipefail

# --- usage ---
# Usage: export.sh --team <team> [--agent <agent>] [--limit N] [--out <file>]
#
# Exports a team's message history as JSONL — one `message_sent` record per line,
# in chronological order (oldest first). Default output is stdout (pipeable to
# the next tool); --out <file> writes to a file instead. --agent limits to one
# agent's messages (sender or recipient); omitted = the whole team. --limit N
# keeps the most recent N; omitted = everything retained.
# --- end usage ---
#
# "Full" means everything CURRENTLY RETAINED — the sync/retention window for the
# team's plan — not necessarily everything ever sent. Because export is the
# "give me all of it" command, the history is STREAMED to stdout/the file (never
# collected into a shell variable first), so an export stays O(1) in memory even
# for a team with a large retention window.
#
# Output is plaintext. agmsg's end-to-end encryption is transport-only: messages
# are sealed on the wire and the server holds only ciphertext, but each of your
# machines unseals into a plaintext local store. Export reads that local store,
# so it needs no key and produces plaintext. (A server-side ciphertext archive,
# if ever offered, is a separate feature — not this command.)

# usage() reads the marker-delimited block above, not fixed line numbers, so
# adding a comment elsewhere in the header can't silently misalign --help.
usage() {
  sed -n '/^# --- usage ---$/,/^# --- end usage ---$/p' "$0" \
    | sed -e '/^# --- /d' -e 's/^# \{0,1\}//'
}

TEAM=""; AGENT=""; LIMIT=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team)  TEAM="${2:?Missing value for --team}"; shift 2 ;;
    --agent) AGENT="${2:?Missing value for --agent}"; shift 2 ;;
    --limit) LIMIT="${2:?Missing value for --limit}"; shift 2 ;;
    --out)   OUT="${2:?Missing value for --out}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'export.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$TEAM" ] || { printf 'export.sh: --team is required\n' >&2; usage >&2; exit 2; }
# A non-numeric --limit is treated as unset (full export) rather than passed
# through, mirroring history.sh's guard; the driver also revalidates.
case "$LIMIT" in ''|*[!0-9]*) LIMIT="" ;; esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load

# <agent> optional (omitted = team-wide); --limit optional (omitted = all).
args=("$TEAM")
[ -n "$AGENT" ] && args+=("$AGENT")
[ -n "$LIMIT" ] && args+=(--limit "$LIMIT")

# emit streams the export to the current stdout. A read must NOT create a missing
# store (storage_history would storage_init one), so a team never written to
# reads out as an empty export — return 0, not the falsy storage_store_exists.
# Driver-level, so it holds for jsonl too.
emit() {
  if storage_store_exists "$TEAM"; then
    storage_history "${args[@]}"
  else
    return 0
  fi
}

if [ -n "$OUT" ]; then
  # Stream to a same-directory temp, then rename on success. Two properties, both
  # load-bearing (mirrors scripts/key.sh's _key_write_identity_atomic):
  #  - Atomic: a driver failure mid-export never truncates or corrupts an
  #    existing out file (the old file survives), and the full history is never
  #    held in memory.
  #  - Safe: the temp is created by mktemp (O_EXCL + an UNPREDICTABLE name), so a
  #    process sharing the out directory cannot pre-plant a symlink at a guessable
  #    temp path and redirect our plaintext onto an arbitrary file. A predictable
  #    "$OUT.tmp.$$" opened with plain `>` would make the atomicity fix itself a
  #    write primitive against any file the caller can write.
  out_dir="$(cd "$(dirname "$OUT")" && pwd)"
  tmp="$(mktemp "$out_dir/.export-XXXXXX")" || {
    printf 'export.sh: cannot create a temp file in %s\n' "$out_dir" >&2; exit 1
  }
  chmod 600 "$tmp"
  # A signal between mktemp and the rename would otherwise leave a 0600-but-never-
  # renamed plaintext temp behind; clean it on any exit path, then drop the trap
  # once the rename has happened (an empty export still yields an empty file).
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  if emit > "$tmp"; then
    mv -f "$tmp" "$OUT"
    trap - EXIT HUP INT TERM
  else
    rc=$?
    exit "$rc"
  fi
else
  # Default: stream to stdout, so it pipes to the next tool. When stdout is a
  # terminal the plaintext message contents would print straight to the screen —
  # note it on stderr FIRST (data still goes to stdout), the same care as the
  # key-reveal screens.
  if [ -t 1 ]; then
    printf 'export.sh: writing plaintext message contents to the terminal; use --out <file> to save to a file.\n' >&2
  fi
  emit
fi
