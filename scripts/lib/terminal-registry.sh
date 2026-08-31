#!/usr/bin/env bash
# Terminal registry — the "terminals" driver axis facade.
#
# A terminal driver abstracts the ONE terminal multiplexer a member's CLI runs
# under: tmux, herdr, or plain (no addressable pane). It absorbs the terminal
# operations that were scattered as inline `$TMUX`/`HERDR_*` branches across
# spawn.sh / despawn.sh / watch.sh, behind one contract, and adds peek/poke.
#
# Layout mirrors the types axis (ADR 0002, docs/spec/driver-interface.md):
#   scripts/drivers/terminals/<name>/terminal.conf   read-only key=value DATA
#   scripts/drivers/terminals/<name>/ops.sh          sourced bash, terminal_* fns
# Discovery + trust come from driver-registry.sh (built-ins always trusted,
# externals opt-in). This facade only knows the terminals-axis layout.
#
# Contract (per docs/spec/driver-interface.md §1). Every driver's ops.sh exposes:
#   terminal_check                      control op: deps -> ok|missing_deps(+DIRECTIVE)
#   terminal_describe [project]         exit 0, key=value only (name/backend/capabilities)
#   terminal_detect <session_id>        RECORD op: print this session's own pane id and
#                                       exit 0 IFF we are running under this terminal now;
#                                       non-zero (no stdout) otherwise. herdr resolves the
#                                       pane from the session id (NOT inherited env);
#                                       tmux uses $TMUX_PANE; plain is the exit-0 fallback
#                                       printing '-' (no addressable pane).
#   terminal_spawn <name> <project> <target> <boot...>   RECORD op: create a pane/window,
#                                       launch boot, print the new bare pane id.
#   terminal_despawn <id>               control op: kill the pane/window named by bare <id>.
#   terminal_peek <id> [--lines N]      RECORD op: print visible pane text verbatim (NOT
#                                       parsed). unsupported -> exit 13, reason on stderr.
#   terminal_poke <id> <text>           control op: send text and submit. unsupported -> 13.
#   terminal_name <id> <team> <name>    control op: set the human pane name; idempotent
#                                       (safe to re-apply on SessionStart).
#
# Detection is a driver FUNCTION (not a manifest datum like the types axis's
# detect=) because herdr's "which pane am I" is logic, not a set of env vars. The
# resolver sources each candidate's ops.sh in a SUBSHELL so its terminal_*
# definitions never leak or clobber across candidates; only the resolved driver
# is sourced into the caller.

# Source-time lib dir (robust to later subshell/relative cwd).
_AGMSG_TERMINAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Pull in the axis-generic registry (bases + trust) if not already sourced.
if ! declare -F agmsg_driver_bases >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [ -n "$_AGMSG_TERMINAL_LIB_DIR" ] && . "$_AGMSG_TERMINAL_LIB_DIR/driver-registry.sh"
fi

# Absolute dir of terminal driver <name>, honoring built-in vs opted-in external
# (later eligible base wins). Requires a terminal.conf. Returns 1 if none.
agmsg_terminal_dir() {
  local want="$1" kind base dir chosen=""
  while IFS=$'\t' read -r kind base; do
    dir="$base/terminals/$want"
    [ -f "$dir/terminal.conf" ] || continue
    if [ "$kind" = builtin ] || agmsg_driver_is_trusted terminals "$want" "$dir"; then
      chosen="$dir"
    fi
  done <<EOF
$(agmsg_driver_bases)
EOF
  [ -n "$chosen" ] && { printf '%s\n' "$chosen"; return 0; }
  return 1
}

# Read one key from <name>/terminal.conf. Usage: agmsg_terminal_get <name> <key> [default].
# Reads (never sources) the manifest; strips surrounding whitespace and one pair
# of double quotes. Absent dir/key -> the default. (Clone of agmsg_type_get so
# the two manifest axes parse identically.)
agmsg_terminal_get() {
  local name="$1" key="$2" def="${3:-}" dir line val
  dir="$(agmsg_terminal_dir "$name")" || { printf '%s\n' "$def"; return 0; }
  line="$( { grep -E "^[[:space:]]*${key}[[:space:]]*=" "$dir/terminal.conf" 2>/dev/null || true; } | head -1)"
  if [ -z "$line" ]; then
    printf '%s\n' "$def"
    return 0
  fi
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
  esac
  printf '%s\n' "$val"
}

# 0 if <want> is in the space-separated value of <name>'s <key> (e.g. capabilities).
agmsg_terminal_has() {
  local name="$1" key="$2" want="$3" tok
  for tok in $(agmsg_terminal_get "$name" "$key"); do
    [ "$tok" = "$want" ] && return 0
  done
  return 1
}

# The full terminal ABI. EVERY driver must define EVERY one of these; the loader
# verifies it. Naming the set here (not relying on each driver being complete) is
# what makes a missing op FAIL rather than silently borrow the previously loaded
# driver's same-named function.
_AGMSG_TERMINAL_REQUIRED="terminal_check terminal_describe terminal_detect terminal_spawn terminal_despawn terminal_peek terminal_poke terminal_name"

# Wipe every terminal_* ABI function from the current shell. Called before each
# source so a driver that is switched to cannot inherit the previous driver's ops
# — the clobber co1 flagged: "no function" fails loudly (command not found), but a
# LEFTOVER function of a different driver succeeds and runs the wrong backend.
_agmsg_terminal_unset_ops() {
  local fn
  for fn in $_AGMSG_TERMINAL_REQUIRED; do unset -f "$fn" 2>/dev/null || true; done
}

# Source driver <name>'s ops.sh into the CALLER's context, trust-gated, idempotent.
# Structurally clobber-proof: wipe all terminal_* first, then source, then VERIFY
# every required ABI function is now defined (an incomplete driver fails here
# rather than running a leftover from a prior load). Loud on any failure.
_AGMSG_TERMINAL_LOADED="${_AGMSG_TERMINAL_LOADED:-}"
agmsg_terminal_load() {
  local name="$1"
  [ -n "$name" ] || { echo "agmsg: terminal_load needs a driver name" >&2; return 1; }
  [ "$name" = "$_AGMSG_TERMINAL_LOADED" ] && return 0
  local dir
  dir="$(agmsg_terminal_dir "$name")" || {
    echo "agmsg: no terminal driver '$name'" >&2; return 1;
  }
  [ -f "$dir/ops.sh" ] || { echo "agmsg: terminal driver '$name' has no ops.sh" >&2; return 1; }
  _agmsg_terminal_unset_ops
  _AGMSG_TERMINAL_LOADED=""   # a half-loaded driver must not read as loaded
  # EVERY failure past this point routes through the same cleanup so no partial
  # terminal_* (from a failed source OR an incomplete driver) is left to be
  # borrowed, and the loaded marker stays empty for a clean retry.
  # shellcheck disable=SC1090
  . "$dir/ops.sh" || {
    echo "agmsg: failed to source terminal driver '$name'" >&2
    _agmsg_terminal_unset_ops
    return 1
  }
  local fn missing=""
  for fn in $_AGMSG_TERMINAL_REQUIRED; do
    declare -F "$fn" >/dev/null 2>&1 || missing="$missing $fn"
  done
  if [ -n "$missing" ]; then
    echo "agmsg: terminal driver '$name' is missing ABI functions:$missing" >&2
    _agmsg_terminal_unset_ops   # leave no partial driver behind to be borrowed
    return 1
  fi
  _AGMSG_TERMINAL_LOADED="$name"
}

# Run <name>'s terminal_detect for <session_id> in a SUBSHELL so its terminal_*
# functions cannot leak into or clobber the resolver. On success prints the
# driver's self pane id and exits 0; else non-zero (no stdout).
_agmsg_terminal_detect_one() {
  local name="$1" sid="${2:-}" dir
  dir="$(agmsg_terminal_dir "$name")" || return 1
  [ -f "$dir/ops.sh" ] || return 1
  (
    # Wipe any inherited terminal_* (SAME required set as the loader, derived from
    # one place) so a candidate whose ops.sh omits terminal_detect cannot be
    # judged by a terminal_detect left in the caller's env.
    _agmsg_terminal_unset_ops
    # shellcheck disable=SC1090
    . "$dir/ops.sh" || exit 13
    declare -F terminal_detect >/dev/null 2>&1 || exit 13
    terminal_detect "$sid"
  )
}

# Resolve which terminal we are under. Prints "<terminal>\t<self-id>" and exits 0.
# Precedence: an explicit override (AGMSG_TERMINAL_DRIVER, or arg 2) wins over
# detection; otherwise detection runs in order herdr > tmux > plain (plain always
# matches, so resolution never fails). This is the single answer that ends the
# historical $TMUX-vs-HERDR_* dual system; callers record the result rather than
# re-deciding (a nested herdr-in-tmux otherwise lies — measured 2026-08-21).
#
# The override is a SPAWN/NAME resolution PREFERENCE, not current-placement
# detection: it forces which terminal a NEW spawn (or a re-name) uses. Ops on an
# EXISTING member (despawn/peek/poke) never consult it — they read the terminal
# from the placement record, so a shell that exported an override cannot make
# despawn misread a herdr-placed pane as tmux (scope L96-98; tl 2026-08-31). So a
# forced driver whose detect fails still resolves (driver + empty id): "spawn into
# tmux" is valid even when we are not currently under tmux.
#
# NOTE the override env is AGMSG_TERMINAL_DRIVER, NOT AGMSG_TERMINAL: the latter
# is already the OS-terminal COMMAND template read by plain's spawn (pre-axis
# spawn.sh). tl ruled 2026-08-31 that a new axis gets a NEW name — so the driver
# override is AGMSG_TERMINAL_DRIVER / --terminal-driver, and the existing
# --terminal / AGMSG_TERMINAL template surface is left unchanged. The flag
# (--terminal-driver) is wired into spawn's argument parsing in PR2; the env works
# now.
#   $1 = session_id (may be empty)   $2 = optional override terminal name
agmsg_terminal_resolve() {
  local sid="${1:-}" override="${2:-${AGMSG_TERMINAL_DRIVER:-}}" name selfid rc
  if [ -n "$override" ]; then
    # A typo must fail loudly, not resolve to "<typo>\t" (an invalid record).
    agmsg_terminal_dir "$override" >/dev/null 2>&1 || {
      echo "agmsg: unknown terminal driver '$override' (AGMSG_TERMINAL_DRIVER)" >&2
      return 1
    }
    selfid="$(_agmsg_terminal_detect_one "$override" "$sid")" || selfid=""
    printf '%s\t%s\n' "$override" "$selfid"
    return 0
  fi
  for name in herdr tmux plain; do
    selfid="$(_agmsg_terminal_detect_one "$name" "$sid")"; rc=$?
    # A match requires exit 0 AND a non-empty id — a driver that exits 0 with no
    # id (e.g. tmux with $TMUX set but $TMUX_PANE empty) is NOT a valid match.
    if [ "$rc" -eq 0 ] && [ -n "$selfid" ]; then
      printf '%s\t%s\n' "$name" "$selfid"
      return 0
    fi
  done
  return 1
}

# --- placement record: <terminal>:<id> scheme -------------------------------
#
# A member's placement is recorded (by spawn) as a TAB line "<ref>\t<project>\t
# <type>" at run/spawn.<team>__<agent>. The <ref> is "<terminal>:<id>". Reading
# tolerates the pre-axis records: a bare tmux pane/window id (%N / @N) with no
# scheme reads as tmux, and the old "herdr:<id>" form still reads as herdr.

# Compose a record ref from a terminal name and its bare id.
agmsg_terminal_ref() {
  printf '%s:%s\n' "$1" "$2"
}

# Print the terminal name of a record ref (stdout). Handles legacy bare ids.
agmsg_terminal_ref_terminal() {
  local ref="$1"
  case "$ref" in
    tmux:*)  printf 'tmux\n' ;;
    herdr:*) printf 'herdr\n' ;;
    plain:*) printf 'plain\n' ;;
    %*|@*)   printf 'tmux\n' ;;   # legacy bare tmux pane/window id
    *)       printf 'tmux\n' ;;   # unknown/legacy -> tmux (the pre-axis default)
  esac
}

# Print the bare id of a record ref (stdout) — the scheme prefix stripped, or the
# whole value for a legacy bare id. Uses first-colon split so a herdr id that
# itself contains ':' (e.g. wC:pN) survives.
agmsg_terminal_ref_id() {
  local ref="$1"
  case "$ref" in
    tmux:*)  printf '%s\n' "${ref#tmux:}" ;;
    herdr:*) printf '%s\n' "${ref#herdr:}" ;;
    plain:*) printf '%s\n' "${ref#plain:}" ;;
    *)       printf '%s\n' "$ref" ;;         # legacy bare id
  esac
}
