#!/usr/bin/env bash
set -euo pipefail

# poke.sh — type text into a named member's pane and submit it.
#
# Usage:
#   poke.sh <team> <name> --body-file <path>   # body read from a file (preferred)
#   poke.sh <team> <name> --body -             # body read from stdin
#   poke.sh <team> <name> <text>               # body as ONE quoted argument
#
# --body-file is the form the type templates teach, and the reason is #507's
# lesson: a positional <text> passes through the CALLER's shell first, where a
# backtick or $( ) in the body executes and its span silently vanishes from
# what arrives. A file (or stdin) never crosses that shell, so there is no
# quoting rule to teach and none to get wrong. The positional form stays for
# compatibility and for humans typing short plain text; it refuses extra
# arguments rather than silently dropping words. Trailing newlines are
# stripped from a file/stdin body (command-substitution semantics): the
# submission itself is the driver's job, not a trailing byte's.
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

TEAM="${1:-}"; NAME="${2:-}"
USAGE="Usage: poke.sh <team> <name> --body-file <path> | --body - | <text>"
[ -n "$TEAM" ] && [ -n "$NAME" ] || die "$USAGE"
shift 2

TEXT=""
case "${1:-}" in
  --body-file)
    [ $# -eq 2 ] || die "--body-file takes exactly one path"
    [ -r "${2:-}" ] || die "cannot read body file: ${2:-<missing>}"
    TEXT="$(cat -- "$2")"
    ;;
  --body)
    [ $# -eq 2 ] && [ "${2:-}" = "-" ] \
      || die "--body accepts only '-' (read stdin); for a file use --body-file <path>"
    TEXT="$(cat)"
    ;;
  '')
    die "$USAGE"
    ;;
  *)
    [ $# -le 1 ] || die "got $(($# + 2)) arguments — quote the text as one argument, or use --body-file <path>"
    TEXT="$1"
    ;;
esac
[ -n "$TEXT" ] || die "the body is empty — nothing to poke"

REC="$(agmsg_spawn_path "$TEAM" "$NAME")"
[ -f "$REC" ] || die "no placement record for '$TEAM/$NAME' — nothing here knows which pane is theirs (spawn writes it at launch; a hand-joined member gets one when a terminal-aware session names its pane)"

IFS=$'\t' read -r REF _PROJ _TYPE < "$REC" || true
[ -n "$REF" ] || die "placement record for '$TEAM/$NAME' has no pane id — a record with no id is not a placement (a bug in whatever wrote it)"

# The ref parser fails CLOSED (non-zero) on a corrupt/unknown-scheme ref. Under
# `set -e` a bare `VAR="$(...)"` would take the shell down AT the assignment, so
# the die below — the contract for an unresolvable ref — is never reached. Guard
# each assignment with `|| VAR=""` (a condition, errexit-safe on bash 3.2) so the
# failure lands in the emptiness check and reaches its message.
TERMINAL=""; BARE_ID=""
TERMINAL="$(agmsg_terminal_ref_terminal "$REF")" || TERMINAL=""
BARE_ID="$(agmsg_terminal_ref_id "$REF")" || BARE_ID=""
[ -n "$TERMINAL" ] && [ -n "$BARE_ID" ] \
  || die "placement record for '$TEAM/$NAME' did not resolve to a terminal and pane id (ref: '$REF')"

agmsg_terminal_load "$TERMINAL" \
  || die "cannot load terminal driver '$TERMINAL' recorded for '$TEAM/$NAME'"

# Control-op convention: ok/runtime_error on stdout, reasons on stderr. The
# driver's stdout is protocol, not for the operator — swallow it, keep the
# driver's exit status (plain's unsupported 13 included), and put a one-line
# human answer on each side.
RC=0
terminal_poke "$BARE_ID" "$TEXT" >/dev/null || RC=$?
if [ "$RC" -ne 0 ]; then
  # 13 is the driver's "unsupported" — it has already printed a precise reason to
  # stderr AND, for poke, a pointer to the type's native channel ("not a dead end").
  # A generic "could not poke" added AFTER it is the last line the operator reads and
  # would CANCEL that guidance. So on 13, let the driver's reason stand as the
  # final word; only a reachability/delivery failure (10/12) or an unexpected code —
  # a genuine "it should have worked" — gets the entry's summary line.
  if [ "$RC" -ne 13 ]; then
    echo "poke: could not poke '$TEAM/$NAME' (terminal '$TERMINAL', pane '$BARE_ID')" >&2
  fi
  exit "$RC"
fi
echo "poked '$TEAM/$NAME' via $TERMINAL"
