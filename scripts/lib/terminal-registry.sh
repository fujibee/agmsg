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
_AGMSG_TERMINAL_REQUIRED="terminal_check terminal_describe terminal_detect terminal_spawn terminal_despawn terminal_peek terminal_poke terminal_where terminal_arrange terminal_name"

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

# Detection has TWO callers with different needs (tl 2026-08-31); detect itself
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
# are the OS-terminal command template and stay unchanged (tl 2026-08-31).

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
# and exit 0. ORDER (tl 2026-09-01, from cc1's nested measurement): prefer a
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

# Print the terminal name of a record ref (stdout). Handles legacy bare ids.
# Is <id> a well-formed id for <terminal>? The SINGLE authority for the per-terminal
# bare-id grammar, shared by agmsg_terminal_ref_terminal (below) and the herdr
# driver's _herdr_pane_id_ok (which delegates here), so the two cannot drift. The id
# is handed to a terminal as a TARGET, so this is the line between a value we may
# pass and one we must refuse:
#   tmux   %<n> / @<n>, n decimal   (rejects tmux:alice -> a real session; %9;kill)
#   herdr  w<n>:p<x>, one ':', alnum+':' only   (rejects a newline / '|' / junk)
#   plain  exactly '-'              (no addressable pane; any other value is corrupt)
_agmsg_terminal_id_ok() {   # <terminal> <id>
  local id="$2" rest
  case "$1" in
    tmux)
      case "$id" in %*|@*) : ;; *) return 1 ;; esac
      rest="${id#?}"
      case "$rest" in ''|*[!0-9]*) return 1 ;; esac
      return 0 ;;
    herdr)
      case "$id" in w[0-9A-Za-z]*:p[0-9A-Za-z]*) : ;; *) return 1 ;; esac
      case "$id" in *:*:*) return 1 ;; esac
      case "$id" in *[!0-9A-Za-z:]*) return 1 ;; esac
      return 0 ;;
    plain)
      [ "$id" = '-' ] || return 1
      return 0 ;;
    *) return 1 ;;
  esac
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
  # otherwise (co1: the container is not the contents).
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
agmsg_terminal_name_self() {
  local sid="${1:-}" team="${2:-}" agent="${3:-}" project="${4:-}" type="${5:-}"
  local write_record="${6:-}"
  [ -n "$team" ] && [ -n "$agent" ] || {
    echo "agmsg: terminal_name_self needs <team> and <agent>" >&2; return 1
  }

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
  if [ -n "$sid" ]; then
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

  # Named. Whether that ALSO makes this pane the seat's recorded placement is the
  # caller's claim to make, not this function's.
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
