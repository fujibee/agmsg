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
#
# Before typing, a type that opted in (input_prompt_marker set in its
# manifest) has its input box checked for someone actively typing — see
# scripts/lib/input-box.sh and the comment above the check below (#1322):
# two snapshots ~1s apart, refusing only if they differ, not by judging
# whatever the box currently holds. That check narrows the window a poke can
# corrupt a draft; it does NOT close it: a person can start typing in the
# instant between the second snapshot and the actual keystroke below, and
# that keystroke can still land mixed with theirs (maintainer-accepted
# residual risk, #1321 review). "poke checked first" is not "poke cannot
# ever type over someone still typing".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"          # agmsg_spawn_path
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/terminal-registry.sh"   # record scheme + driver load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"       # required by detect-cli-type.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"              # required by detect-cli-type.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/detect-cli-type.sh"     # agmsg_detect_cli_type (#1229 plain fallback)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/input-box.sh"           # agmsg_input_box_locate/is_real_draft/normalize (#1321, #1322)

die() { echo "poke: $*" >&2; exit 1; }

TEAM="${1:-}"; NAME="${2:-}"
USAGE="Usage: poke.sh <team> <name> [--retries N] [--retry-delay SECONDS] [--backoff fixed|exponential] --body-file <path> | --body - | <text>"
[ -n "$TEAM" ] && [ -n "$NAME" ] || die "$USAGE"
shift 2

# Retry options, default off (RETRIES=0 means the loop near the bottom of
# this script runs exactly once, same as before this existed). Pulled out
# of the remaining args first, in any position, so they never disturb the
# body-spec parsing below. Retries exist only for the input-box refusal
# (#1321) — a transient condition (someone is actively typing right now,
# per #1322's two-snapshot comparison, and may finish) — never for a
# driver-level failure (unreachable pane, no placement record, and so on),
# which retrying would not fix.
RETRIES=0
RETRY_DELAY=2
BACKOFF=exponential
_REMAINING=()
while [ $# -gt 0 ]; do
  case "$1" in
    --retries)
      [ $# -ge 2 ] || die "--retries needs a number"
      case "$2" in ''|*[!0-9]*) die "--retries must be a non-negative integer, got: $2" ;; esac
      RETRIES="$2"; shift 2 ;;
    --retry-delay)
      [ $# -ge 2 ] || die "--retry-delay needs a number of seconds"
      case "$2" in ''|*[!0-9]*) die "--retry-delay must be a non-negative integer, got: $2" ;; esac
      RETRY_DELAY="$2"; shift 2 ;;
    --backoff)
      [ $# -ge 2 ] || die "--backoff must be 'fixed' or 'exponential'"
      case "$2" in
        fixed|exponential) BACKOFF="$2" ;;
        *) die "--backoff must be 'fixed' or 'exponential', got: $2" ;;
      esac
      shift 2 ;;
    *) _REMAINING+=("$1"); shift ;;
  esac
done
set -- "${_REMAINING[@]+"${_REMAINING[@]}"}"

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

IFS=$'\t' read -r REF _PROJ TYPE _FENCE < "$REC" || true
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
#
# Input-box check (#1321), immediately before EVERY attempt including
# retries — never once up front, since the box's own state is exactly what
# each retry exists to wait out. INPUT_MARKER empty (this type set none in
# its manifest) skips the check entirely: unconditional single terminal_poke
# call, the same as before this existed.
#
# Also skipped outright for the plain terminal (review): plain has no
# addressable screen to read at all (terminal_peek always fails there, by
# contract), so treating that failure as "could not confirm empty" would
# refuse EVERY plain poke with exit 14 and never reach the existing
# plain-specific fallback below (an agmsg message, when the caller can
# resolve one) — a real regression, not a safety win, since plain never had
# a screen for a draft to corrupt in the first place.
INPUT_MARKER="$(agmsg_type_get "$TYPE" input_prompt_marker)"
INPUT_BOXED="$(agmsg_type_get "$TYPE" input_prompt_boxed)"
[ "$TERMINAL" = plain ] && INPUT_MARKER=""

# #1322 round 2: round 1 (compare two snapshots ~1s apart, refuse only if
# they differ) correctly let Claude Code's candidate text and Codex's
# placeholder through, but a REAL, STALLED draft (someone typed something
# and paused) is just as stationary as those, so it also let poke type over
# a real draft -- measured live, 2026-09-22: a maintainer's stalled draft
# and a poke's own body landed as one submitted message, no separator.
#
# Fix: a real draft's characters are NOT drawn dim; Claude Code's candidate
# text and Codex's placeholder both ARE (SGR faint, code 2 -- measured live
# on all three, 2026-09-21/22). _poke_read_input_box below reads styled
# (ANSI) when the driver offers one and refuses outright on ANY visible
# non-dim content, before ever reaching the two-snapshot comparison -- see
# scripts/lib/input-box.sh's own comment for the full reasoning, including
# why Codex's decorative Braille animation has to be stripped first (it is
# drawn in a plain color, not dim, so left in place it reads as a real
# draft and defeats this exactly the way it defeated round 1's plain-text
# comparison).
#
# The two-snapshot check itself is KEPT, not replaced: style classification
# alone cannot catch someone who starts typing in the window between the
# two reads -- that is what comparing them still does.
#
# The interval is fixed, not a flag: making it configurable would leave
# "how long is long enough" an open question nobody has actually measured,
# with the value drifting per caller. 1 second was chosen because ordinary
# interactive typing — including a Japanese IME updating its pre-conversion
# buffer per kana — changes the box well under a second between keystrokes,
# so a 1s window reliably catches an in-progress edit; measured (2026-09-21,
# read-only) against three real idle panes over a full 8s span (five reads,
# 2s apart), the STATIONARY case — Claude Code candidate text on two panes,
# Codex's placeholder (with its own decorative Braille animation, see
# scripts/lib/input-box.sh) on a third — never changed at all, so 1s carries
# no false-positive risk against exactly the content this fix exists for.
AGMSG_POKE_INPUT_BOX_SETTLE_SECONDS=1

# Reads the pane once and classifies its input box, setting the caller's
# own _POKE_IB_RC / _POKE_IB_SNAPSHOT (plain-statement call, never
# `x="$(...)"`  -- a command substitution runs in a subshell, and these are
# side-channel globals, the same reason _slack_read_token's own comment
# documents in the Slack ext-tool adapter).
#   _POKE_IB_RC        0 = box confirmed & safe to compare; 14 = a real
#                       draft (styled read only) or the box's own structure
#                       could not be confirmed; anything else = a
#                       driver-level terminal_peek failure, propagate as-is
#   _POKE_IB_SNAPSHOT  normalized comparison key, meaningful only when
#                       _POKE_IB_RC = 0
#
# <styled> is 1 when the driver offers terminal_peek_styled (checked once,
# outside this function, via `declare -F`) -- a driver without it only gets
# round 1's protection (narrower: won't catch a STALLED real draft), never
# a regression from what 1.4.1 shipped, since that is exactly what shipped.
_poke_read_input_box() {
  local styled="$1" screen="" peek_rc=0 region="" region_rc=0
  if [ "$styled" -eq 1 ]; then
    # No 2>/dev/null here (unlike before): on failure this is
    # terminal_peek_styled's own diagnosis, not an "input in progress"
    # refusal, and it must reach the operator verbatim -- the same message
    # terminal_poke would have printed for the same underlying cause (#1321
    # review round 2).
    screen="$(terminal_peek_styled "$BARE_ID")" || peek_rc=$?
  else
    screen="$(terminal_peek "$BARE_ID")" || peek_rc=$?
  fi
  if [ "$peek_rc" -ne 0 ]; then
    _POKE_IB_RC="$peek_rc"
    return 0
  fi
  region="$(agmsg_input_box_locate "$INPUT_MARKER" "$INPUT_BOXED" "$screen")" || region_rc=$?
  if [ "$region_rc" -ne 0 ]; then
    # Cannot confirm where the box even is (transient redraw, alternate
    # screen) -- fails toward refusing, never toward typing (unchanged bias
    # from #1321).
    _POKE_IB_RC=14
    return 0
  fi
  if [ "$styled" -eq 1 ] && agmsg_input_box_is_real_draft "$INPUT_MARKER" "$region"; then
    _POKE_IB_RC=14
    return 0
  fi
  _POKE_IB_RC=0
  _POKE_IB_SNAPSHOT="$(agmsg_input_box_normalize "$region")"
}

RC=0
ATTEMPT=0
while :; do
  RC=0
  if [ -n "$INPUT_MARKER" ]; then
    STYLED=0
    declare -F terminal_peek_styled >/dev/null 2>&1 && STYLED=1

    _POKE_IB_RC=0 _POKE_IB_SNAPSHOT=""
    _poke_read_input_box "$STYLED"
    if [ "$_POKE_IB_RC" -ne 0 ]; then
      RC="$_POKE_IB_RC"
    else
      SNAP1="$_POKE_IB_SNAPSHOT"
      sleep "$AGMSG_POKE_INPUT_BOX_SETTLE_SECONDS"
      _POKE_IB_RC=0 _POKE_IB_SNAPSHOT=""
      _poke_read_input_box "$STYLED"
      if [ "$_POKE_IB_RC" -ne 0 ]; then
        RC="$_POKE_IB_RC"
      else
        SNAP2="$_POKE_IB_SNAPSHOT"
        [ "$SNAP1" = "$SNAP2" ] || RC=14
      fi
    fi
  fi
  if [ "$RC" -eq 0 ]; then
    terminal_poke "$BARE_ID" "$TEXT" >/dev/null || RC=$?
    break
  fi
  # Retries exist to wait out someone still actively typing (RC=14) — a
  # driver-level failure propagated above, or from terminal_poke's own
  # attempt, would not be fixed by waiting and must not be retried. Each
  # retry re-runs the full two-snapshot comparison above (its own internal
  # ~1s wait is separate from, and in addition to, --retry-delay's wait
  # between attempts).
  [ "$RC" -eq 14 ] || break
  [ "$ATTEMPT" -lt "$RETRIES" ] || break
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$BACKOFF" = exponential ]; then
    WAIT=$((RETRY_DELAY * (1 << (ATTEMPT - 1))))
    [ "$WAIT" -le 60 ] || WAIT=60
  else
    WAIT="$RETRY_DELAY"
  fi
  sleep "$WAIT"
done

if [ "$RC" -eq 14 ]; then
  echo "poke: '$TEAM/$NAME' has a changing input box — refusing to type over it (input in progress)" >&2
  exit 14
fi

# #1229: a bare plain:- target (id '-') has no pane at all — not a
# reachability failure worth retrying, a structural absence. See
# scripts/drivers/terminals/plain/README.md's poke section, which this
# points at because that file is surfaced by the TARGET's own terminal on
# ITS session start, not the caller's — a herdr/tmux caller poking a plain
# target never reads it otherwise.
if [ "$RC" -eq 13 ] && [ "$TERMINAL" = plain ] && [ "$BARE_ID" = '-' ]; then
  README_POINTER="see scripts/drivers/terminals/plain/README.md's poke section"
  CALLER_TYPE="$(agmsg_detect_cli_type 2>/dev/null || true)"

  if [ "$TYPE" = claude-code ] && [ "$CALLER_TYPE" = claude-code ]; then
    # Claude Code's own local session messaging (ListAgents/SendMessage) is a
    # strictly better substitute than anything this script can do here
    # (immediate, native, no dependency on the target's agmsg delivery
    # config) — but this script has no shell path to that message channel
    # (#1229 review: reverse-engineering its undocumented socket protocol
    # was explicitly rejected). Name the route and stop rather than
    # silently falling back to something worse.
    echo "poke: '$TEAM/$NAME' is a claude-code session with no addressable pane (plain terminal) — do not retry poke.sh for this pair. Use your own Claude Code session messaging instead: ListAgents to find the session named '$TEAM-$NAME', then SendMessage to it ($README_POINTER)." >&2
    exit 13
  fi

  # Otherwise (the caller is not Claude Code, or the target's type has no
  # native channel of its own): fall back to delivering the body as an
  # ordinary agmsg message — the same store send.sh writes to — instead of
  # typing it. Worse than a typed poke (it reaches the target on ITS OWN
  # delivery terms, not synchronously), but strictly better than a bare
  # refusal. `from` is resolved the same way whoami.sh/send.sh already
  # resolve identity -- identities.sh's (project, type) -> registered
  # (team, agent) lookup -- restricted to THIS target's own team.
  FROM_MATCHES="$("$SCRIPT_DIR/identities.sh" "$(pwd)" "$CALLER_TYPE" 2>/dev/null | awk -F'\t' -v t="$TEAM" '$1==t{print $2}')"
  FROM_N=0
  [ -n "$FROM_MATCHES" ] && FROM_N="$(printf '%s\n' "$FROM_MATCHES" | grep -c .)"
  FROM_AGENT=""
  if [ "$FROM_N" -eq 1 ]; then
    FROM_AGENT="$FROM_MATCHES"
  elif [ "$FROM_N" -gt 1 ]; then
    # #1229 review: identities.sh alone cannot disambiguate several same-
    # (project, type) registrations in team '$TEAM' -- this fleet's own real
    # shape, many same-type seats sharing one project checkout. Narrow using
    # THIS session's own actas lock: of the few already-ambiguous
    # candidates, which one (if any) does this specific running session
    # currently hold? Checked per candidate via actas_lock_read (forward
    # team+agent -> lock, always correct) -- never by scanning run/ and
    # reverse-parsing lock filenames back into a team/agent, which breaks
    # for an id-keyed lock (#1023) and is not fixed here (see the filed
    # issue this PR's body links).
    CALLER_SID="${AGMSG_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-}}}"
    if [ -n "$CALLER_SID" ]; then
      CALLER_BARE="$(agmsg_instance_bare_sid "$CALLER_SID")"
      OWNED_N=0
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        LOCK_RD="$(actas_lock_read "$TEAM" "$cand")"
        LOCK_KIND="${LOCK_RD%%$'\t'*}"; LOCK_OWNER="${LOCK_RD#*$'\t'}"
        [ "$LOCK_KIND" = ok ] && [ -n "$LOCK_OWNER" ] || continue
        [ "$(agmsg_instance_bare_sid "$LOCK_OWNER")" = "$CALLER_BARE" ] || continue
        FROM_AGENT="$cand"
        OWNED_N=$((OWNED_N + 1))
      done <<<"$FROM_MATCHES"
      [ "$OWNED_N" -eq 1 ] || FROM_AGENT=""
    fi
  fi
  if [ -z "$FROM_AGENT" ]; then
    echo "poke: '$TEAM/$NAME' has no addressable pane (plain terminal, unsupported) — cannot fall back to an agmsg message either: this session's own agmsg identity in team '$TEAM' could not be resolved to exactly one ($FROM_N registration(s) found for type '$CALLER_TYPE' at this project path, and this session's own actas lock did not narrow it to exactly one either), so 'from' cannot be resolved without guessing. Join or actas first, then retry ($README_POINTER)." >&2
    exit 13
  fi
  BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/agmsg-poke-fallback.XXXXXX")" \
    || die "could not create a temp file for the message-fallback body"
  printf '%s' "$TEXT" > "$BODY_FILE"
  SEND_RC=0
  "$SCRIPT_DIR/send.sh" "$TEAM" "$FROM_AGENT" "$NAME" --body-file "$BODY_FILE" >/dev/null || SEND_RC=$?
  rm -f "$BODY_FILE"
  if [ "$SEND_RC" -ne 0 ]; then
    echo "poke: '$TEAM/$NAME' has no addressable pane (plain terminal, unsupported); the agmsg-message fallback (from '$FROM_AGENT') also failed (rc $SEND_RC)" >&2
    exit 13
  fi
  echo "poked '$TEAM/$NAME' via an agmsg message from '$FROM_AGENT' (plain has no addressable pane to type into — delivered as a message, not typed into a screen; reaches '$NAME' on their own delivery terms, not synchronously)"
  exit 0
fi

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
