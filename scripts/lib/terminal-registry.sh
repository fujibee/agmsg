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
#   terminal_peek <id> [--lines N]      RECORD op: print pane text verbatim (NOT parsed).
#                                       With --lines, request scrollback depth N; shipped
#                                       pane drivers pass N unchanged to their backend.
#                                       unsupported -> exit 13, reason on stderr.
#   terminal_poke <id> <text>           control op: send text and submit. unsupported -> 13.
#   terminal_pane_state <id>            READ ONLY: is that pane still there?
#                                       Prints gone / present / unknown and
#                                       returns 0 for a settled answer, 13 when
#                                       this terminal has no addressable pane to
#                                       ask about, 10 when it could not be
#                                       reached. "Could not ask" never returns 0:
#                                       a caller deletes the placement record on
#                                       `gone` alone, and `terminal_despawn`
#                                       cannot answer this (it collapses "already
#                                       closed" and "could not close" into 13).
#   terminal_where <id>                 READ op: print the id's container (tmux window /
#                                       herdr tab). Existence is not answered here;
#                                       a missing id is unknown/10, never `gone`.
#   terminal_arrange <source-id> <intent> <target-id>
#                                       control op: declaratively place source below/right
#                                       of target. Prints moved / unchanged. It reads layout
#                                       before mutating because the native moves are not
#                                       idempotent. Ambiguous layout -> token + non-zero.
#   terminal_name <id> <team> <name> [mode]
#                                       control op: set the pane's names; idempotent.
#                                       Two names, not one: the label a person
#                                       reads and the key the TERMINAL addresses
#                                       the agent by in its own namespace. This
#                                       repo's peek/poke resolve through the
#                                       placement record, not the key.
#                                       `mode=key` sets only the key
#                                       (AGMSG_TERMINAL_NAMING=off); absent sets
#                                       both. A driver that has only one name
#                                       treats it as the key.
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

# Placement records are the ONLY authority peek/poke/despawn have over a member,
# so writing one must never truncate a correct existing record on a failed write.
# agmsg_write_atomic (registry-lock.sh) writes to a temp and renames — a failure
# leaves the old record whole. Pull it in if a caller has not (guarded, like the
# registry above); the same helper six other scripts already use, not a 7th copy.
if ! declare -F agmsg_write_atomic >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [ -n "$_AGMSG_TERMINAL_LIB_DIR" ] && . "$_AGMSG_TERMINAL_LIB_DIR/registry-lock.sh"
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
_AGMSG_TERMINAL_REQUIRED="terminal_check terminal_describe terminal_detect terminal_spawn terminal_despawn terminal_pane_state terminal_peek terminal_poke terminal_where terminal_arrange terminal_name"
_AGMSG_TERMINAL_OPTIONAL="terminal_team_observe terminal_team_input_ready terminal_find_by_label terminal_label_of terminal_id_ok"

# A driver's observation fields carry EITHER an observed value or one of these
# prefixes, which say why there is no value. They are listed here, once, because
# two sides need the same list and neither owns it: the drivers emit them, and
# anything judging an observation ("is this a key I can trust?") has to recognise
# every one. A judge that enumerates them by hand goes stale the moment a driver
# gains a case — which is exactly what happened between the spawn-side read-back
# and this file's `absent:` (the judge tested a BARE `absent`, so a prefixed value
# read as a usable key and a nameless pane was reported as named).
#
# The prefix form is load-bearing: a value is disqualified by its PREFIX, never by
# equality with a whole token, so a driver may make a reason more specific without
# any judge changing. Do not mix bare sentinels into this set.
#
#   unknown:  the observation could not be made           (nothing was learned)
#   n/a:      this terminal has no such thing to observe  (nothing to learn)
#   absent:   it was observed, and there is nothing there (a decided fact)
#
# The three are NOT interchangeable further up: `agmsg_identity_cell` passes
# `unknown:`/`n/a:` through as skip markers and turns `absent:` into a mismatch a
# repair can act on. They are alike only in the one respect this set is for —
# none of them is an observed value.
_AGMSG_OBSERVATION_NON_VALUE_PREFIXES="unknown: n/a: absent:"

# 0 when the field carries a real observed value, 1 when it carries a reason (or
# nothing). The single question a read-back judge should be asking.
agmsg_observation_has_value() {   # <field>
  local v="$1" p
  [ -n "$v" ] || return 1
  for p in $_AGMSG_OBSERVATION_NON_VALUE_PREFIXES; do
    case "$v" in "$p"*) return 1 ;; esac
  done
  return 0
}

# Wipe every terminal_* ABI function from the current shell. Called before each
# source so a driver that is switched to cannot inherit the previous driver's ops
# — the clobber flagged in review: "no function" fails loudly (command not found), but a
# LEFTOVER function of a different driver succeeds and runs the wrong backend.
_agmsg_terminal_unset_ops() {
  local fn
  for fn in $_AGMSG_TERMINAL_REQUIRED $_AGMSG_TERMINAL_OPTIONAL; do
    unset -f "$fn" 2>/dev/null || true
  done
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
  #
  # Lift errexit around the source and read its status separately (the codebase's
  # two-line `set +e … set -e` pattern; cf. check-inbox.sh). On bash 3.2 (macOS
  # /bin/bash) a failing command at the top of a sourced file fires the CALLER's
  # `set -e` even though this source sits on the left of a guard — measured, the
  # source-failure trace escaped the caller's `|| rc=$?`. The lift makes 3.2 and 5
  # agree; it is restored immediately.
  local _src_rc=0 _restore_e=0
  case $- in *e*) _restore_e=1 ;; esac   # only re-enable errexit if it was on
  set +e
  # shellcheck disable=SC1090
  . "$dir/ops.sh"
  _src_rc=$?
  [ "$_restore_e" = 1 ] && set -e
  if [ "$_src_rc" -ne 0 ]; then
    echo "agmsg: failed to source terminal driver '$name'" >&2
    _agmsg_terminal_unset_ops
    return 1
  fi
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
  local name="$1" sid="${2:-}" errf="${3:-/dev/null}" dir
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
    # detect reports two facts: exit code = PRESENCE (are we this terminal), stdout
    # = self-id (may be empty = "could not resolve"), stderr = the reason for an
    # empty id. We forward the id on stdout and capture the reason to <errf>.
    terminal_detect "$sid" 2>"$errf"
  )
}

# Detection has TWO callers with different needs (2026-08-31); detect itself
# decides nothing — these do.
#
# Precedence for both: an explicit override (AGMSG_TERMINAL_DRIVER, or arg 2) wins
# over detection; else detection runs herdr > tmux > plain. This ends the historic
# $TMUX-vs-HERDR_* dual system; callers RECORD the resolved terminal rather than
# re-deciding later from an inherited env (a nested herdr-in-tmux lies — measured
# 2026-08-21). The override is a SPAWN/NAME preference only: ops on an EXISTING
# member (despawn/peek/poke) read the terminal from the placement record, never
# the env. The override env is AGMSG_TERMINAL_DRIVER (flag --terminal-driver,
# wired in spawn's arg parsing) — a NEW name, because --terminal / AGMSG_TERMINAL
# are the OS-terminal command template and stay unchanged (2026-08-31).

# resolve-for-PLACEMENT (spawn): which terminal are we under? Prints the terminal
# NAME, exit 0. Uses PRESENCE only — it does NOT need the caller's own pane id
# (spawn records the id of the pane it CREATES, from terminal_spawn's result), so
# an empty self-id never blocks placement. herdr with a live HERDR_PANE_ID but an
# unresolvable session still places in herdr.
#   $1 = session_id (may be empty)   $2 = optional override terminal name
agmsg_terminal_resolve_placement() {
  local sid="${1:-}" override="${2:-${AGMSG_TERMINAL_DRIVER:-}}" name
  if [ -n "$override" ]; then
    agmsg_terminal_dir "$override" >/dev/null 2>&1 || {
      echo "agmsg: unknown terminal driver '$override' (AGMSG_TERMINAL_DRIVER)" >&2
      return 1
    }
    printf '%s\n' "$override"
    return 0
  fi
  for name in herdr tmux plain; do
    if _agmsg_terminal_detect_one "$name" "$sid" >/dev/null 2>&1; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

# resolve-for-NAME (terminal_name / SessionStart): prints "<terminal>\t<self-id>"
# and exit 0. ORDER (2026-09-01, from the nested-herdr measurement): prefer a
# candidate that PRODUCED A PANE ID over one that only claimed PRESENCE; the
# declaration order (herdr > tmux > plain) is the tiebreak AMONG id-producers.
#
# Why not "first present wins": a nested herdr-in-tmux inherits HERDR_* into a tmux
# server it spawned, so herdr answers "present" though tmux is the real terminal. If
# present-but-no-id were fatal at the FIRST candidate, herdr's dead-end would mask
# tmux's live '%0'. Preferring the id-producer records `tmux:<pane>`, which is
# CORRECT — that pane really is a tmux pane, and peek/poke read the record.
#
# FATAL only when NO candidate produced a nameable id AND some non-plain candidate
# was present-but-unresolved — then EVERY such candidate's reason is printed (not
# one). This is the load-bearing case: when herdr is genuinely broken (the
# agent_session-object lookup bug) and tmux cannot answer either, we must fail
# LOUDLY rather than let plain's '-' fallback succeed silently ("noisy wrong" beats
# "silent wrong"). plain's '-' is the "no addressable pane" sentinel: it never wins
# naming and is not a reason; it is only the fallback when NOTHING nameable was
# present-but-unresolved (a genuinely plain OS-terminal member — herdr/tmux absent),
# for which the caller (name_self) decides "skipped" by plain's missing `name`
# capability.
#   $1 = session_id (may be empty)   $2 = optional override terminal name
agmsg_terminal_resolve_name() {
  local sid="${1:-}" override="${2:-${AGMSG_TERMINAL_DRIVER:-}}" name id rc errf reason
  local reasons="" saw_present_unnamed=0 plain_present=0 plain_name=""
  errf="$(mktemp "${TMPDIR:-/tmp}/agmsg-detect.XXXXXX")" || errf=/dev/null
  local names="herdr tmux plain"
  if [ -n "$override" ]; then
    agmsg_terminal_dir "$override" >/dev/null 2>&1 || {
      echo "agmsg: unknown terminal driver '$override' (AGMSG_TERMINAL_DRIVER)" >&2
      [ "$errf" = /dev/null ] || rm -f "$errf"; return 1
    }
    names="$override"
  fi
  for name in $names; do
    # `|| rc=$?` (not `; rc=$?`): a bare command-substitution assignment fires the
    # caller's set -e the instant _detect_one returns non-zero (the common
    # not-this-terminal case), so `; rc=$?` never runs and resolve_name dies before
    # trying the next candidate. The conditional context suppresses errexit; rc=0
    # init covers the success path where `||` does not run. Same fix as herdr.
    rc=0; id="$(_agmsg_terminal_detect_one "$name" "$sid" "$errf")" || rc=$?
    [ "$rc" -eq 0 ] || continue          # not this terminal at all — try the next
    if [ "$id" = '-' ]; then             # present, but no addressable pane (plain sentinel)
      plain_present=1; plain_name="$name"; continue
    fi
    if [ -n "$id" ]; then                # produced a nameable id — this candidate wins
      printf '%s\t%s\n' "$name" "$id"
      [ "$errf" = /dev/null ] || rm -f "$errf"; return 0
    fi
    # Present but produced no id: remember the reason and KEEP LOOKING for a
    # candidate that can. Read the reason without leaving a bare failing status on
    # the line — under errexit a `reason=$([ -f x ] && ...)` that short-circuits
    # (e.g. errf is /dev/null after an mktemp failure) exits the caller before we
    # report. Guard with an `if` (a guard's non-zero does not propagate).
    reason=""
    if [ "$errf" != /dev/null ] && [ -f "$errf" ]; then
      reason="$(cat "$errf" 2>/dev/null || true)"
    fi
    reasons="${reasons:+$reasons; }$name: ${reason:-present but could not identify this pane}"
    saw_present_unnamed=1
  done
  [ "$errf" = /dev/null ] || rm -f "$errf"
  # A non-plain candidate was present but could not be named: fail LOUDLY with every
  # such reason, rather than let plain mask it.
  if [ "$saw_present_unnamed" = 1 ]; then
    echo "agmsg: under a terminal but cannot identify this pane to name it — $reasons" >&2
    return 1
  fi
  # Nothing nameable was present-but-unresolved: fall back to plain if it matched
  # (genuinely-plain member) so name_self can report "skipped" by capability.
  if [ "$plain_present" = 1 ]; then
    printf '%s\t%s\n' "$plain_name" '-'
    return 0
  fi
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

# The terminal server's generation, as the ENVIRONMENT shows it -- no call to
# the terminal. This is what lets a naming mark (role-session named_epoch)
# notice that the server it was made against has been restarted, the case in
# which the pane reference can survive unchanged while the name it carried is
# gone. Empty when the terminal offers nothing of the kind.
#
#   tmux   the server pid, the middle field of $TMUX ("socket,pid,index")
#   herdr  inode and ctime of the socket at $HERDR_SOCKET_PATH: the server
#          creates that file when it starts (measured: its ctime is the last
#          server start), so a restart recreates it. stat's flags differ
#          between BSD and GNU; both are tried, and no stat at all is "".
#          Resolution is one second, and a filesystem may hand the freed
#          inode straight back (ext4 does; measured on a Linux runner), so a
#          recreation inside the same second is not visible -- a real restart
#          takes longer than that, and the case falls into the stated blind
#          spot rather than into a false detection.
#   plain  nothing to observe
agmsg_terminal_epoch() {   # <terminal>
  case "$1" in
    tmux)
      [ -n "${TMUX:-}" ] || return 0
      local rest="${TMUX#*,}"
      printf 'pid=%s\n' "${rest%%,*}" ;;
    herdr)
      [ -n "${HERDR_SOCKET_PATH:-}" ] || return 0
      local s=""
      s="$(stat -f '%i:%c' "$HERDR_SOCKET_PATH" 2>/dev/null)" \
        || s="$(stat -c '%i:%Z' "$HERDR_SOCKET_PATH" 2>/dev/null)" \
        || s=""
      [ -z "$s" ] || printf 'sock=%s\n' "$s" ;;
  esac
  return 0
}

# The pane this process is in, from the ENVIRONMENT alone: no driver loaded, no
# terminal called. Prints "<terminal>\t<id>\t<epoch>" or nothing. This is the
# fast half of self-naming on action: a seat that finds its mark equal to this
# never touches the terminal (measured 0.22 ms for the file read). It answers
# the same question as agmsg_terminal_resolve_name("") for tmux and herdr --
# tmux from $TMUX/$TMUX_PANE (the driver's terminal_detect reads exactly those),
# herdr from HERDR_PANE_ID (the driver's terminal_detect now prefers it too).
# Under neither, nothing: plain has no pane to name.
agmsg_terminal_self_env() {
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux\t%s:%s\t%s\n' "${TMUX%%,*}" "$TMUX_PANE" "$(agmsg_terminal_epoch tmux)"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr\t%s\t%s\n' "$HERDR_PANE_ID" "$(agmsg_terminal_epoch herdr)"
    return 0
  fi
  return 0
}

# Print the terminal name of a record ref (stdout). Handles legacy bare ids.
# Is <id> a well-formed id for <terminal>? Answered by the DRIVER's terminal_id_ok
# (the grammar lives in each ops.sh, and the herdr driver's _herdr_pane_id_ok is
# that same function under its local name), so the emitter and every reader --
# agmsg_terminal_ref_terminal below, the label resolver -- cannot drift. The id
# is handed to a terminal as a TARGET, so this is the line between a value we may
# pass and one we must refuse:
#   tmux   %<n> / @<n>, n decimal   (rejects tmux:alice -> a real session; %9;kill)
#   herdr  w<n>:p<x>, one ':', alnum+':' only   (rejects a newline / '|' / junk)
#   plain  exactly '-'              (no addressable pane; any other value is corrupt)
_agmsg_terminal_id_ok() {   # <terminal> <id>
  local name="$1" id="$2"
  [ -n "$name" ] && [ -n "$id" ] || return 1
  # The driver NAME is validated before anything is loaded by it. This function
  # now reaches the filesystem (a driver directory, resolved through the driver
  # bases), and a name that is not a plain word -- "../../../plugins/terminals/x"
  # -- would traverse from the builtin base into a plugin directory and read as
  # builtin, past the trust gate (review warning, measured on a prototype). No
  # caller hands this a name from an untrusted reference today; a generic scheme
  # parser composed later could, so the line is drawn here as well as wherever
  # discovery draws it.
  case "$name" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  # The id grammar is a property of the DRIVER, so the driver is asked
  # (`terminal_id_ok <id>` in its ops.sh); this registry no longer holds a case
  # over three names. It did until the #1141 review composed it with #1143
  # (trusted external drivers joining every chooser): a case that knew only
  # herdr/tmux/plain answered "malformed" for every row an external driver
  # emitted, and the label resolver -- which now validates each row before
  # counting -- silently dropped that driver's correct pane. The same shape
  # #1133 removes from the choosers, added back one layer down.
  #
  # Three answers, and the fallback is stated so nobody has to guess it:
  #   the driver defines terminal_id_ok  -> its verdict (the built-in three do)
  #   the driver exists but has no hook   -> ACCEPTED. A trusted external driver
  #                                          is the only authority on its own ids;
  #                                          refusing here would unmake #1143.
  #                                          The cost is that malformed-row
  #                                          filtering for such a driver is only
  #                                          as good as its own emitter.
  #   no such driver                      -> refused, as before
  #
  # Asked without disturbing the caller: when the driver is the one already
  # loaded, call it directly (no fork -- this runs per scanned row); otherwise
  # load it in a SUBSHELL, so the caller's driver functions are not replaced
  # under it (a ref of terminal X is validated while driver Y is in use, e.g.
  # the placement scan reading another seat's record).
  if [ "$name" = "${_AGMSG_TERMINAL_LOADED:-}" ]; then
    if declare -F terminal_id_ok >/dev/null 2>&1; then
      terminal_id_ok "$id"; return $?
    fi
    return 0
  fi
  (
    agmsg_terminal_load "$name" >/dev/null 2>&1 || exit 1
    declare -F terminal_id_ok >/dev/null 2>&1 || exit 0
    terminal_id_ok "$id"
  )
}

agmsg_terminal_ref_terminal() {
  local ref="$1" term id
  case "$ref" in
    tmux:*)  term=tmux;  id="${ref#tmux:}" ;;
    herdr:*) term=herdr; id="${ref#herdr:}" ;;
    plain:*) term=plain; id="${ref#plain:}" ;;
    %*|@*)   term=tmux;  id="$ref" ;;    # legacy pre-axis bare tmux id
    *)       return 1 ;;                 # unknown scheme -> no terminal
  esac
  # A KNOWN scheme is not enough: the id after it is still handed to the terminal as a
  # TARGET, so a corrupt id (tmux:%9;kill, tmux:alice, herdr:<newline>, plain:any)
  # must not fall through. Validate it against the terminal's grammar; fail closed
  # otherwise (the container is not the contents).
  _agmsg_terminal_id_ok "$term" "$id" || return 1
  printf '%s\n' "$term"
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

# --- name THIS pane, and record where it is ---------------------------------
#
# The step that makes peek/poke reach a member nobody spawned: join, actas and
# SessionStart all call it, so a pane a human opened by hand is as addressable as
# a spawned one. Limiting peek/poke to spawned members was refused (fujibee,
# 2026-08-28); this is what lifts the limit. SessionStart is not optional — herdr
# drops an agent's name when the agent exits, so a resume must re-apply it.
#
# Three outcomes, deliberately kept apart:
#
#   named    the terminal can name a pane AND this pane was identified, so the
#            driver names it. A "<terminal>:<id>" placement record -- the same one
#            spawn writes -- follows ONLY when the caller asked for one; see the
#            6th argument.
#   skipped  the terminal has no `name` capability (plain has no addressable
#            pane). QUIET, 0, and NO record: a permanent property of the terminal
#            is not news on every join, and a record whose id cannot be acted on
#            is not a placement -- writing one is a bug in the writer (ruling,
#            2026-08-31).
#   unnamed  the terminal CAN name, A SESSION ID WAS GIVEN, and this pane still
#            could not be identified. non-zero, reason already on stderr from the
#            resolver: saying "cannot name this pane" beats naming nothing.
#
# The session id qualifies `unnamed` on purpose. Called WITHOUT one -- join has
# none to give, there being no per-type datum saying which env var carries it --
# a terminal that needs it is `skipped`, not `unnamed`. No input is a different
# fact from a failed lookup, and reporting the first as the second would warn on
# every join under herdr about a condition nobody can act on.
#
# Callers treat non-zero as a WARNING, never as a failure of the join/claim/
# session-start they are performing. Naming is additive; it must not change what
# those commands do or return.
#
# The 6th argument decides whether a PLACEMENT RECORD is written, and it defaults
# to NOT writing one. Naming a pane and being the authoritative placement for a
# seat are different claims: `join` names a pane but proves nothing about who
# holds the seat -- the same identity can be joined from a second session while a
# first one holds it through actas -- so a record written there would redirect
# peek/poke/despawn at a pane that does not have the seat. Only a caller with
# positive evidence of ownership passes `record`: actas (it went through the
# claim) and SessionStart (the seat is resolved). The default is the safe half, so
# a caller added later that has not thought about it cannot silently take a
# placement over.
#
#   agmsg_terminal_name_self <session_id> <team> <agent> <project> <type> [record]
# Which OTHER seat's placement record already claims this pane reference, if any.
# Prints "<team>__<agent>" as the record file spells it (percent-encoded, the form
# on disk) and nothing when the pane is unclaimed.
#
# PLACEMENT GUARD (#1114, guarding the regression #1111 exposed). Written as a
# stop-gap for #1112; #1112 has landed and this stays as the SECOND line: label-
# first resolution makes a wrong answer less likely, not impossible (a label can
# be duplicated, cleared, or stale, and the environment fallback is still the
# shared daemon's for codex), so a pane another seat's record already claims is
# still refused here. Removing it is a separate decision, taken only when label
# resolution is made authoritative; the seam tests pin the two mechanisms
# together until then.
#
# "Other seat" means a record that is not THIS agent's in any existing team.
# run/ is flat and one seat registered in two teams has two records
# (spawn.<team1>__<x>, spawn.<team2>__<x>) for the same pane; the second must not
# be blocked by the first, or a seat that acts in its second team can never be
# recorded there (measured on this host, where every seat is in two teams).
# "This agent's" is decided by building the record path for each team on disk
# with the same encoder and comparing whole file names -- "__" is legal inside
# a name, so the file name cannot be cut at a separator. The one state this
# cannot resolve: this agent's own record under a team that has since vanished
# from teams/ -- no path can be built for it, so it reads as a rival and blocks
# this seat (fail-closed). The refusal message says so and names the file to
# remove; a team that is dropped with its run/ records left behind is that state.
#
# Since #1111 a seat records its own placement when it acts, resolving the pane
# from its OWN environment. For codex that environment is not its own: those
# seats arrive through one shared app-server daemon, so every seat under it
# inherits the daemon's pane (measured: three codex seats all resolve
# herdr:w1:p2, while they actually sit at w1:p2, w1:pN and w1:pP). Their records
# are correct today only because spawn wrote them from outside; the next action
# each one takes overwrites its own record with the daemon's pane, one seat at a
# time.
#
# So until the environment is fixed, a seat does not take a pane another seat's
# record already claims. This is first-writer-wins, which is NOT always right --
# a stale record from a dead seat will squat a pane that a live seat has taken
# over. #1112 (label-first resolution) is the fix for the shared environment,
# and this guard is not replaced by it: a label makes a wrong answer less likely,
# not impossible, so the arbitration stays. The cost of the squat is one action
# and a message naming the file; the cost of no guard is another seat's pane.
# Split a placement ref into terminal / pane id / socket, so two refs can be
# compared as PANES rather than as strings. Sets _AGMSG_PS_TERM, _AGMSG_PS_ID and
# _AGMSG_PS_SOCK (empty when the ref carries no socket); non-zero for a ref it
# cannot parse.
#
# String equality is not enough: the record format still accepts the legacy
# socket-less tmux forms (`%N`, `@N`) alongside `tmux:<socket>:%N` (see the
# scheme comment above and agmsg_terminal_ref_terminal), so a peer record holding
# `%1` never matches a freshly composed `tmux:/tmp/x:%1` -- and the guard waves
# the write through for exactly the records most likely to be OLD, which are the
# ones most likely to belong to somebody else.
#
# The scheme table below mirrors agmsg_terminal_ref_terminal / agmsg_terminal_ref_id
# (inline, so the scan forks nothing per record); a test pins that the two agree
# on every form the record format accepts.
_agmsg_placement_split() {   # <ref>
  local ref="$1" term id
  _AGMSG_PS_TERM=""; _AGMSG_PS_ID=""; _AGMSG_PS_SOCK=""
  case "$ref" in
    tmux:*)  term=tmux;  id="${ref#tmux:}" ;;
    herdr:*) term=herdr; id="${ref#herdr:}" ;;
    plain:*) term=plain; id="${ref#plain:}" ;;
    %*|@*)   term=tmux;  id="$ref" ;;        # legacy pre-axis bare tmux id
    *)       return 1 ;;
  esac
  if [ "$term" = tmux ]; then
    case "$id" in
      *:*) _AGMSG_PS_SOCK="${id%:*}"; id="${id##*:}" ;;   # split on the LAST colon
    esac
  fi
  [ -n "$id" ] || return 1
  _AGMSG_PS_TERM="$term"; _AGMSG_PS_ID="$id"
  return 0
}

# <ref> <team> <agent>
#   Prints the claimant as its record file spells it ("<team>__<agent>", encoded)
#   when ANOTHER seat's record claims this pane; prints nothing when the pane is
#   unclaimed. Returns 1 when this seat's OWN ref cannot be parsed: ownership is
#   then undecidable and the caller must not name or record (fail-closed).
_agmsg_placement_claimed_by() {
  local ref="$1" team="$2" agent="$3" dir f first mine enc_agent t is_mine
  local want_term want_id want_sock
  _agmsg_placement_split "$ref" || return 1          # undecidable, not "unclaimed"
  want_term="$_AGMSG_PS_TERM"; want_id="$_AGMSG_PS_ID"; want_sock="$_AGMSG_PS_SOCK"
  mine="$(agmsg_spawn_path "$team" "$agent")" || return 1
  dir="$(dirname "$mine")"
  [ -d "$dir" ] || return 0
  enc_agent="$(_actas_lock_encode "$agent")"
  for f in "$dir"/spawn.*; do
    [ -f "$f" ] || continue
    [ "$f" = "$mine" ] && continue
    # This seat under another team is not a rival. "This seat" is decided
    # EXACTLY: the file equals this agent's record path for a team that exists
    # on disk, spelled by the same encoder -- never by cutting the file name at
    # a separator, because "__" is legal inside a name and cutting there made a
    # peer called "foo__bar" look like "bar". The suffix test is only a cheap
    # pre-filter before the exact comparison.
    is_mine=0
    case "$f" in
      *"__$enc_agent")
        for t in "$(dirname "$dir")"/teams/*/; do
          [ -d "$t" ] || continue
          t="${t%/}"; t="${t##*/}"
          [ "$f" = "$(agmsg_spawn_path "$t" "$agent")" ] && { is_mine=1; break; }
        done ;;
    esac
    [ "$is_mine" -eq 1 ] && continue
    IFS="$(printf '\t')" read -r first _ < "$f" 2>/dev/null || first=""
    # A record whose ref cannot be read as a pane -- empty, unreadable, or an
    # unknown spelling -- cannot be ruled out as THIS pane, so it claims. Naming
    # it lets a person drop it; waving it through is the fail-open this guard
    # exists to close.
    if [ -z "$first" ] || ! _agmsg_placement_split "$first"; then
      printf '%s' "${f##*/spawn.}"
      return 0
    fi
    [ "$_AGMSG_PS_TERM" = "$want_term" ] || continue
    [ "$_AGMSG_PS_ID" = "$want_id" ] || continue
    # Same terminal, same pane id. The sockets decide whether that is the same
    # PANE: a pane id is not unique across tmux servers (#1051). A record may be
    # the legacy socket-less form, and an unknown server cannot be shown to be a
    # DIFFERENT one -- so an unknown socket on either side counts as a claim.
    # Refusing there costs one action; taking a pane that turns out to be
    # someone's is the damage this guard exists to prevent.
    if [ -n "$_AGMSG_PS_SOCK" ] && [ -n "$want_sock" ] \
       && [ "$_AGMSG_PS_SOCK" != "$want_sock" ]; then
      continue                                # different servers, different panes
    fi
    printf '%s' "${f##*/spawn.}"
    return 0
  done
  return 0
}

# Resolve this seat's pane by its LABEL, when the label answers unambiguously.
# Prints "<terminal>\t<id>" and returns 0; returns 1 for "the label did not
# settle it", which is not a failure -- the caller falls through to the paths
# that were here before.
#
# WHY this goes first (#1112). The two existing ways to answer "which pane am I"
# both read something that is not the seat:
#
#   the environment    HERDR_PANE_ID / TMUX_PANE, inherited. A codex seat's
#                      commands run under one shared app-server, not in its pane,
#                      so all of them inherit the pane that started the daemon --
#                      measured: three seats resolving one pane while sitting in
#                      three.
#   the session id     herdr's agent_session for those panes does not match the
#                      thread actually running there -- measured on the same
#                      three seats, and it returns the SAME wrong pane.
#
# Two independent roads to one wrong answer is not a coincidence; both read the
# process tree, and for these seats the process tree is not where they live. The
# label is not read from the process tree: it was written on one pane at a time.
#
# That is the whole of the claim, and it is deliberately smaller than "the label
# is correct". The label is written by `spawn`, repaired by `team --fix` and
# written by seats naming themselves -- the same machinery whose wrong answers
# this exists to route around. So a wrong label is possible, and preferring it
# is a bet that a per-pane write is wrong less often than a value inherited by
# every process under one daemon. Not authority: a more recent observation, from
# a source that at least distinguishes one pane from another.
#
# EXACTLY ONE, or nothing. The label is not unique by construction -- it is
# usable only WHEN it is unique, which is a different claim and the one the code
# makes.
#
# Zero matches is the ordinary bootstrap state (nothing has named this seat yet).
# Two or more is not hypothetical: measured on a real tmux server, two panes
# carried the same `@agmsg_agent`, both alive, one running a CLI and one a bare
# shell -- and splitting a labelled pane does NOT copy the option (measured on a
# dedicated server), so a duplicate is something agmsg itself wrote. Picking the
# first would choose silently between panes, one of which is someone else's --
# the failure this whole change exists to stop, re-introduced one layer up. Both
# fall through.
_agmsg_terminal_resolve_by_label() {   # <team> <agent>
  local team="$1" agent="$2" label name ids id line found="" count=0 tab
  [ -n "$team" ] && [ -n "$agent" ] || return 1
  label="$team:$agent"
  tab="$(printf '\t')"
  local names="herdr tmux plain"
  [ -n "${AGMSG_TERMINAL_DRIVER:-}" ] && names="$AGMSG_TERMINAL_DRIVER"
  for name in $names; do
    agmsg_terminal_load "$name" >/dev/null 2>&1 || continue
    declare -F terminal_find_by_label >/dev/null 2>&1 || continue
    ids="$(terminal_find_by_label "$label" 2>/dev/null)" || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # READER HALF (#1134): count only rows that are a pane in this driver's own
      # grammar. A malformed row is not a candidate, so it must not count as one:
      # counting it made one driver's garbage plus another driver's correct
      # pane look like two candidates, and the correct pane was refused with the
      # garbage. What this half guarantees is exactly that -- a driver that speaks
      # badly cannot suppress a driver that speaks well. It does NOT rely on the
      # drivers filtering their own output (the herdr emitter does, separately,
      # and that is a courtesy, not a contract this loop leans on), and it does
      # NOT decide whether a well-formed candidate is the right pane -- the
      # confirmation below does that. Two well-formed candidates still refuse.
      _agmsg_terminal_id_ok "$name" "$line" || continue
      count=$((count + 1))
      found="$name$tab$line"
    done <<EOF
$ids
EOF
  done
  [ "$count" -eq 1 ] || return 1
  # The count says one; this says it is the RIGHT one. The driver did the
  # filtering, and a driver whose filter is loose would hand back somebody else's
  # pane with no way for the count to notice. Ask the pane what label it carries,
  # through the op that reads a single pane, and require the answer.
  #
  # Through `terminal_label_of`, NOT a field of `terminal_team_observe`: the pair
  # does not sit in the same observation field for every driver. tmux has no
  # pane-label field of its own, so it publishes the pair as the KEY and its
  # label field is the constant `n/a:no_independent_field`; herdr's label field
  # is a real label and its key is a hash. Reading a fixed position asks the two
  # drivers different questions -- and asked of tmux, one whose answer can never
  # be the label, so on tmux the confirmation failed every single time and the
  # label path never once resolved. It shipped that way and every test stayed
  # green, because every test that reached a SUCCESS was a herdr test (#1122
  # review). The driver knows where its own label lives; ask it by name.
  #
  # REQUIRED, not "if it is there". A driver that found a pane by label but
  # cannot read that label back has not confirmed anything, and an unconfirmed
  # pane is exactly the thing this whole change refuses to take.
  #
  # AND WHAT IT DOES NOT CATCH, so that nobody reads more into it later: a label
  # that is simply WRONG. Asking the pane again returns the same wrong label,
  # because the pane is where the wrong value was written. This catches a driver
  # whose FILTER is loose -- a listing that answers with a pane it should not
  # have matched -- and nothing about whether the label on that pane belongs to
  # this seat. Deciding that needs evidence from outside the naming machinery
  # entirely (asking the seat to emit something and seeing which pane it lands
  # in); that is not this function and not this change.
  id="${found#*$tab}"
  name="${found%%$tab*}"
  agmsg_terminal_load "$name" >/dev/null 2>&1 || return 1
  declare -F terminal_label_of >/dev/null 2>&1 || return 1
  local seen
  seen="$(terminal_label_of "$id" 2>/dev/null)" || return 1
  [ "$seen" = "$label" ] || return 1
  printf '%s\n' "$found"
  return 0
}

agmsg_terminal_name_self() {
  local sid="${1:-}" team="${2:-}" agent="${3:-}" project="${4:-}" type="${5:-}"
  local write_record="${6:-}"
  [ -n "$team" ] && [ -n "$agent" ] || {
    echo "agmsg: terminal_name_self needs <team> and <agent>" >&2; return 1
  }

  # AGMSG_SELF_NAME=off: this process must NOT name its pane, whatever pair it
  # is handed. Checked HERE, in the one function every self-naming path ends in
  # (join at boot, actas, the action hook), not only in the action hook -- a
  # switch honoured by one path out of several is not a switch. The case that
  # needs it (#1096): spawn runs join.sh in the CALLER's process on behalf of
  # the new member; "self" below resolves through the caller's environment
  # (HERDR_PANE_ID, $TMUX/$TMUX_PANE), so without this the caller's pane is
  # renamed to the new member's label and key. spawn sets it on that one
  # subprocess; a seat joining by hand keeps naming itself.
  [ "${AGMSG_SELF_NAME:-on}" != off ] || return 0

  # The BARE sid, whatever the caller had. A terminal knows the id the CLI
  # published; the composite "<sid>.<pid>" exists only inside agmsg, and handing
  # it over asks a question no terminal can answer -- the answer comes back as
  # "this session cannot identify its own pane", which reads as a resolution
  # problem and is an identifier mismatch. That was a real defect at the actas
  # call site, and watch.sh had it before that. Normalising HERE instead of at
  # each caller is what stops the next entry point from repeating it: the
  # conversion is idempotent (bare -> bare, composite -> bare, empty -> empty),
  # so a caller cannot get it wrong by passing either form.
  if [ -n "$sid" ] && declare -F agmsg_instance_bare_sid >/dev/null 2>&1; then
    sid="$(agmsg_instance_bare_sid "$sid")"
  fi

  # No bare `x=$(cmd)` past this point. Under `set -e` a non-zero inside a command
  # substitution ends the CALLER before the status can be read -- the shape review
  # caught four times in this branch -- so every capture carries `|| rc=$?`.
  local resolved="" rc=0
  # #1112: the label first, when it settles the question. Falls through silently
  # when it does not -- zero matches is the ordinary state before anything has
  # named this seat, and more than one means the label is not identifying here.
  resolved="$(_agmsg_terminal_resolve_by_label "$team" "$agent" 2>/dev/null)" || resolved=""
  if [ -n "$resolved" ]; then
    :                                        # the label answered; skip the rest
  elif [ -n "$sid" ]; then
    resolved="$(agmsg_terminal_resolve_name "$sid")" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"        # unnamed: resolver printed the reason
  else
    # NO SID GIVEN is not "resolution failed" -- it is "there was no input to
    # resolve with", and folding the two into one value is the mistake this
    # branch keeps finding elsewhere. A terminal that needs no session id (tmux
    # reads $TMUX_PANE) still names the pane; one that needs it (herdr looks the
    # pane up BY agent session id) is SKIPPED, quietly, because nothing was asked
    # of it. The resolver's reason is dropped on purpose: it would report a
    # missing input as a failure, on every join, forever.
    resolved="$(agmsg_terminal_resolve_name "" 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || return 0            # skipped
  fi

  local tab terminal="" id=""
  tab="$(printf '\t')"
  terminal="${resolved%%$tab*}"
  id="${resolved#*$tab}"
  [ -n "$terminal" ] && [ -n "$id" ] && [ "$id" != "$resolved" ] || {
    echo "agmsg: terminal resolution returned no pane to name" >&2; return 1
  }

  # Capability is DATA (terminal.conf), not a test on the driver's name: a
  # terminal that cannot name a pane is skipped without a word, and a terminal
  # that grows the ability later needs no change here.
  local caps=""
  caps="$(agmsg_terminal_get "$terminal" capabilities 2>/dev/null)" || caps=""
  case " $caps " in *" name "*) ;; *) return 0 ;; esac

  agmsg_terminal_load "$terminal" || return 1

  # PLACEMENT GUARD (#1114, kept alongside #1112's label-first resolution): a
  # pane another seat's record already claims is not this seat's to NAME, MARK,
  # or RECORD, whichever path resolved it. The check sits here,
  # BEFORE the rename, because the rename is the act it exists to prevent: with
  # the shared-daemon environment #1112 describes, three codex seats resolve one
  # pane, and a check placed after the rename let each of them relabel and rekey
  # that pane (another seat's) and mark itself as named there, sparing only the
  # record. The resolved reference is known now, so the decision is made now.
  #
  # The claim scan needs agmsg_spawn_path (actas-lock.sh). When it cannot be
  # loaded the scan is skipped -- a caller that asked for `record` fails on that
  # below, with its own message; a caller that did not is not blocked by a
  # library it never needed.
  if ! declare -F agmsg_spawn_path >/dev/null 2>&1 \
     && [ -n "${SKILL_DIR:-}" ] && [ -r "$SKILL_DIR/scripts/lib/actas-lock.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$SKILL_DIR/scripts/lib/actas-lock.sh" 2>/dev/null || true
  fi
  if declare -F agmsg_spawn_path >/dev/null 2>&1; then
    local _claim_ref="" _claimed_by="" _claim_rc=0
    _claim_ref="$(agmsg_terminal_ref "$terminal" "$id" 2>/dev/null)" || _claim_ref=""
    # Undecidable (this seat's own ref cannot be parsed, or its record path
    # cannot be built) is not "unclaimed": neither name nor record then.
    _claimed_by="$(_agmsg_placement_claimed_by "$_claim_ref" "$team" "$agent")" || _claim_rc=$?
    if [ "$_claim_rc" -ne 0 ]; then
      echo "agmsg: did not name or record this pane: this seat's own reference ('$_claim_ref') cannot be read as a pane, so whether another seat holds it cannot be decided. (#1114 placement guard, kept alongside #1112's label-first resolution.)" >&2
      return 0
    fi
    if [ -n "$_claimed_by" ]; then
      # A claimant whose name ends in THIS seat's name may be this seat under a
      # team no longer on disk (the exact rule cannot tell, and stays closed);
      # the way out is then the file, not a seat.
      local _self_hint=""
      case "$_claimed_by" in
        *"__$(_actas_lock_encode "$agent")")
          _self_hint=" If '$_claimed_by' is this seat under a team that no longer exists, remove run/spawn.$_claimed_by." ;;
      esac
      echo "agmsg: did not name or record this pane: this seat resolved $_claim_ref, and that pane is already recorded as $_claimed_by's. Keeping that seat's name and record. If that seat is gone, drop or despawn it and act again.$_self_hint (#1114 placement guard, kept alongside #1112's label-first resolution.)" >&2
      return 0
    fi
  fi

  # AGMSG_TERMINAL_NAMING=off suppresses the VISIBLE label and nothing else. The
  # key stays, always, because it is addressing rather than decoration — the name
  # the TERMINAL knows the agent by, in its own namespace.
  #
  # Narrower than an earlier revision of this comment claimed, and the difference
  # matters: `peek`, `poke` and `despawn` in THIS repo resolve through the
  # placement record's pane id, and `_herdr_internal_key` is read nowhere outside
  # its own driver (counted). So dropping the key does not make a member
  # unreachable to agmsg. Saying it did pointed at the wrong thing to protect.
  # A caller that genuinely wants no terminal writes at all is describing the
  # `plain` terminal.
  #
  # The env var is read HERE and handed to the driver as a mode, so the policy
  # has one home and each driver only carries it out. Read at call time, not
  # cached: a value cached at source time is a value nobody can change.
  local name_mode=""
  case "${AGMSG_TERMINAL_NAMING:-}" in
    off) name_mode=key ;;
  esac

  local out=""
  rc=0
  out="$(terminal_name "$id" "$team" "$agent" "$name_mode")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "agmsg: could not name this $terminal pane for $team:$agent${out:+ ($out)}" >&2
    return "$rc"
  fi

  # Named. Leave the mark that says so -- "agmsg named pane <ref> of server
  # generation <epoch> for this seat" -- in the seat's role-session record, so
  # the next action reads one file instead of calling the terminal (see
  # agmsg_self_name_on_action). Every path that names writes the same mark
  # here, which is what makes "whichever path runs first" produce the same
  # state. Best-effort: a mark that cannot be written costs one round trip on
  # the next action, nothing else, and must never turn a successful naming
  # into a failure.
  if ! declare -F agmsg_role_session_mark_named >/dev/null 2>&1 \
     && [ -n "${SKILL_DIR:-}" ] && [ -r "$SKILL_DIR/scripts/lib/role-session.sh" ]; then
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/role-session.sh" 2>/dev/null || true
  fi
  if declare -F agmsg_role_session_mark_named >/dev/null 2>&1; then
    agmsg_role_session_mark_named "$team" "$agent" \
      "$(agmsg_terminal_ref "$terminal" "$id")" "$(agmsg_terminal_epoch "$terminal")" \
      "$project" "$type" || true
  fi

  # Whether that ALSO makes this pane the seat's recorded placement is the
  # caller's claim to make, not this function's. The claim is legitimate because
  # this function only ever names the CALLER'S OWN pane -- resolved from the
  # caller's session id or, with an empty sid, its environment (above) -- so
  # `record` asserts "the pane I just resolved as mine is where I live". The
  # callers that pass it are exactly the self-locating ones: SessionStart and
  # actas name the seat as it starts, and the action hook (self-name.sh) does the
  # same on every action for a hand-started seat that was never recorded (#1109).
  # A future path that names a pane it was HANDED -- batch relabeling of someone
  # else's pane -- must NOT pass record: it is not that seat and cannot speak for
  # its placement. (spawn records too, but writes the record itself for the CHILD
  # pane it created; it does not reach this line.)
  [ "$write_record" = record ] || return 0

  # The record is what despawn/peek/poke resolve through, so it is written only
  # after the driver has actually named the pane.
  if ! declare -F agmsg_spawn_path >/dev/null 2>&1; then
    [ -n "${SKILL_DIR:-}" ] && [ -r "$SKILL_DIR/scripts/lib/actas-lock.sh" ] || {
      echo "agmsg: named the pane but cannot record it (no actas-lock.sh)" >&2; return 1
    }
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/actas-lock.sh" || {
      echo "agmsg: named the pane but cannot record it" >&2; return 1
    }
  fi

  local rec="" ref=""
  rec="$(agmsg_spawn_path "$team" "$agent")" || rc=$?
  ref="$(agmsg_terminal_ref "$terminal" "$id")" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$rec" ] && [ -n "$ref" ] || {
    echo "agmsg: named the pane but could not build its record path" >&2; return 1
  }
  # The claim check that used to sit here now sits BEFORE the rename (above):
  # a claimed pane is neither named nor marked nor recorded.

  mkdir -p "$(dirname "$rec")" 2>/dev/null || true
  # Atomic (temp + rename): a failed write must not truncate a correct existing
  # record. agmsg_write_atomic adds the trailing newline, so pass the row without.
  agmsg_write_atomic "$rec" "$(printf '%s\t%s\t%s' "$ref" "$project" "$type")" 2>/dev/null || {
    echo "agmsg: named the pane but could not write its record ($rec)" >&2; return 1
  }
  return 0
}

# Load the terminal registry from a caller running under `set -e`, and name this
# pane -- the whole of what join / actas / SessionStart need, in one line each.
#
# The source is wrapped in the errexit lift for the reason measured on 2026-08-31:
# on bash 3.2 (macOS /bin/bash) a failure inside a sourced file fires the CALLER's
# `set -e` even when the source sits on the left of `||`, so the guard arm is not
# merely skipped, it is UNREACHABLE. join and actas must never die because a
# terminal could not be named, so the lift is the difference between a warning and
# a broken command on macOS.
#
# Sourced BY the registry, so this function exists only once the registry is
# loaded; callers that cannot source it at all simply never name a pane, which is
# the same outcome as a terminal without the capability.
#
#   agmsg_terminal_name_self_safe <session_id> <team> <agent> <project> <type>
agmsg_terminal_name_self_safe() {
  local _rc=0 _restore_e=0
  case $- in *e*) _restore_e=1 ;; esac
  set +e
  agmsg_terminal_name_self "$@"
  _rc=$?
  [ "$_restore_e" = 1 ] && set -e
  return "$_rc"
}
