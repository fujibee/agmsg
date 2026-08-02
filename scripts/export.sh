#!/usr/bin/env bash
set -euo pipefail

# Usage: export.sh --team <team> [--agent <agent>] [--limit N] [--out <file>]
#
# Exports a team's message history as JSONL — one `message_sent` record per line,
# in chronological order (oldest first). Default output is stdout (pipeable to
# the next tool); --out <file> writes to a file instead. --agent limits to one
# agent's messages (sender or recipient); omitted = the whole team. --limit N
# keeps the most recent N; omitted = everything retained.
#
# "Full" means everything CURRENTLY RETAINED — the sync/retention window for the
# team's plan — not necessarily everything ever sent.
#
# Output is plaintext. agmsg's end-to-end encryption is transport-only: messages
# are sealed on the wire and the server holds only ciphertext, but each of your
# machines unseals into a plaintext local store. Export reads that local store,
# so it needs no key and produces plaintext. (A server-side ciphertext archive,
# if ever offered, is a separate feature — not this command.)

usage() {
  sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'
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

# storage_history would storage_init (create) a missing store, but an export is
# a read and must not create one. A team never written to reads out as an empty
# export. Driver-level, so it holds for jsonl too.
JSONL=""
if storage_store_exists "$TEAM"; then
  # <agent> optional (omitted = team-wide); --limit optional (omitted = all).
  args=("$TEAM")
  [ -n "$AGENT" ] && args+=("$AGENT")
  [ -n "$LIMIT" ] && args+=(--limit "$LIMIT")
  JSONL="$(storage_history "${args[@]}")"
fi

if [ -n "$OUT" ]; then
  # Empty history writes an empty file (a valid, zero-record export).
  if [ -n "$JSONL" ]; then printf '%s\n' "$JSONL" > "$OUT"; else : > "$OUT"; fi
else
  # Default: stdout, so it pipes to the next tool. When stdout is a terminal the
  # plaintext message contents would print straight to the screen — note it on
  # stderr (data still goes to stdout), the same care as the key-reveal screens.
  # Plain `if` blocks (not `&&`), so an empty export still exits 0 under set -e.
  if [ -t 1 ]; then
    printf 'export.sh: writing plaintext message contents to the terminal; use --out <file> to save to a file.\n' >&2
  fi
  if [ -n "$JSONL" ]; then
    printf '%s\n' "$JSONL"
  fi
fi
exit 0
