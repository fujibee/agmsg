#!/usr/bin/env bash
set -euo pipefail

# poke.sh — type text into a named member's pane and submit it.
#
# Usage:
#   poke.sh <team> <name> <text>
#
#   <text> is ONE argument — quote it. Extra arguments are refused rather than
#   silently dropped, because "poke team name hello world" losing 'world' would
#   submit a different prompt than the operator wrote.
#
# The member's placement record names the terminal and pane id; that driver's
# terminal_poke does the submission. The terminal comes from the RECORD, never
# from this caller's environment (v1 scope ruling — an exported override must
# not reinterpret an already-placed pane id).
#
# How the submission happens is the DRIVER's contract, not this script's:
# tmux sends the text (send-keys -l) and then, in a separate later burst, an
# arrow key + Enter — same-burst text+Enter is classified as a paste by Codex
# and the Enter becomes a newline instead of submitting (#619). herdr's
# `agent prompt` submits by itself and needs no Enter dance. plain refuses
# with "unsupported: <why>" on stderr, non-zero — never a silent 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"          # agmsg_spawn_path
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/terminal-registry.sh"   # record scheme + driver load

die() { echo "poke: $*" >&2; exit 1; }

TEAM="${1:-}"; NAME="${2:-}"; TEXT="${3:-}"
[ -n "$TEAM" ] && [ -n "$NAME" ] && [ -n "$TEXT" ] \
  || die "Usage: poke.sh <team> <name> <text>"
[ $# -le 3 ] || die "got $# arguments — quote the text as one argument: poke.sh <team> <name> \"<text>\""

REC="$(agmsg_spawn_path "$TEAM" "$NAME")"
[ -f "$REC" ] || die "no placement record for '$TEAM/$NAME' — nothing here knows which pane is theirs (spawn writes it at launch; a hand-joined member gets one when a terminal-aware session names its pane)"

IFS=$'\t' read -r REF _PROJ _TYPE < "$REC" || true
[ -n "$REF" ] || die "placement record for '$TEAM/$NAME' has no pane id — a record with no id is not a placement (a bug in whatever wrote it)"

TERMINAL="$(agmsg_terminal_ref_terminal "$REF")"
BARE_ID="$(agmsg_terminal_ref_id "$REF")"

agmsg_terminal_load "$TERMINAL" \
  || die "cannot load terminal driver '$TERMINAL' recorded for '$TEAM/$NAME'"

# Control-op convention: ok/runtime_error on stdout, reasons on stderr. The
# driver's stdout is protocol, not for the operator — swallow it, keep the
# driver's exit status (plain's unsupported 13 included), and put a one-line
# human answer on each side.
RC=0
terminal_poke "$BARE_ID" "$TEXT" >/dev/null || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "poke: could not poke '$TEAM/$NAME' (terminal '$TERMINAL', pane '$BARE_ID')" >&2
  exit "$RC"
fi
echo "poked '$TEAM/$NAME' via $TERMINAL"
