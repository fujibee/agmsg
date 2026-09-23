#!/usr/bin/env bash
# orca terminal driver — a terminal hosted by the Orca multi-agent IDE
# (github.com/stablyai/orca), addressed by its own opaque `term_<uuid>` handle.
#
# Sourced by the terminals registry into the caller's context. terminal_* only,
# no set -e/-u.
#
# PR1 SCOPE: read-only. detect/check/describe/where/pane_state/peek are real;
# spawn/despawn/poke/name/arrange are not implemented yet and report
# unsupported (13) uniformly, the same convention `plain` uses for a capability
# its manifest does not advertise. A later PR adds them.
#
# MEASURED (memory/design/2026-09-20-orca-terminal-driver-feasibility.md,
# orca 1.4.198 and 1.4.206; not asserted):
#   - `ORCA_TERMINAL_HANDLE` is set, inside an Orca-hosted pane, to the exact
#     handle every `orca terminal <verb> --terminal <handle>` call addresses
#     that pane by — no PID/TTY witness-matching needed, unlike `plain`.
#     `TERM_PROGRAM=Orca` is set alongside it in every pane checked.
#   - `orca terminal show --terminal <handle> --json` on a handle that once
#     existed and was closed answers ok:true, with connected:false,
#     writable:false, orphaned:true and an exitCause object — a real, gone
#     pane, positively confirmed. On a handle orca has never heard of (a typo,
#     or one from a fully-reset instance) it answers ok:false instead, error
#     code terminal_handle_stale — that shape is NOT proof of gone, only proof
#     of "could not resolve"; the two must not be conflated, so pane_state
#     below keeps them apart.
#   - `orca terminal close` on an already-closed handle changed behaviour
#     between versions measured 3 days apart on the same machine: 1.4.198
#     returned an error (terminal_handle_stale); 1.4.206 returns ok:true,
#     ptyKilled:false. `close`'s own return is therefore NOT a stable signal
#     for "already gone" across versions — this is exactly why pane_state is
#     built on `show` alone, never on `close`.
#   - `orca terminal read --terminal <handle> --screen --json` returns the
#     rendered frame as a plain-text `tail` array — no ANSI/color/SGR
#     information in any read mode; nothing to lose by always using --screen.

# control op: orca binary present?
terminal_check() {
  if command -v orca >/dev/null 2>&1; then echo ok; return 0; fi
  printf 'AGMSG-DIRECTIVE: {"type":"install_deps","driver":"terminals/orca","reason":"orca not found"}\n'
  echo missing_deps
  return 10
}

terminal_describe() {
  printf 'name=orca\n'
  printf 'backend=orca terminal pane\n'
  printf 'capabilities=peek where\n'
  printf 'syntax_help=orca terminal --help\n'
}

# record op: report TWO facts and decide nothing, same shape as tmux/herdr
# (2026-08-31). PRESENCE is the exit code: 0 iff this process is running inside
# an Orca-hosted pane (TERM_PROGRAM=Orca), whether or not the handle itself is
# readable. SELF-ID is stdout: $ORCA_TERMINAL_HANDLE, which may be EMPTY — that
# is "present but could not resolve", not "not orca"; the reason goes to
# stderr. The session-id argument is unused — orca reports via the environment,
# like tmux, not via a session-id lookup like herdr.
terminal_detect() {
  [ "${TERM_PROGRAM:-}" = Orca ] || return 1
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
    printf '%s\n' "$ORCA_TERMINAL_HANDLE"
  else
    echo "orca: \$ORCA_TERMINAL_HANDLE is unset — cannot identify this pane" >&2
  fi
  return 0
}

# Run `orca terminal show` for <id> and print its JSON on stdout. Callers check
# their own $? and stdout emptiness; this only centralizes the invocation.
_orca_show_json() {   # <id>
  orca terminal show --terminal "$1" --json 2>/dev/null
}

# 0 when <json> is a valid JSON document; non-zero otherwise. Uses sqlite3's
# JSON1 extension (the codebase's no-jq convention — see herdr's ops.sh).
_orca_json_valid() {   # <json>
  local esc valid
  esc="$(printf '%s' "$1" | sed "s/'/''/g")"
  valid="$(sqlite3 :memory: "SELECT json_valid('$esc')" 2>/dev/null)" || return 1
  [ "$valid" = 1 ]
}

# Print one field from <json> at <path>, or nothing if it is absent/not the
# expected SQL type. <type> is the sqlite json_type() name to require
# (text/integer/...), so a missing key and a key of the wrong shape both come
# back empty rather than as sqlite's own NULL/blank rendering.
#
# NOT for JSON booleans — sqlite's JSON1 reports a boolean's json_type() as the
# literal string 'true'/'false' (measured), not 'integer', so a boolean field
# checked with type=integer here always comes back empty. Use
# _orca_json_bool for `ok` / `connected` and any other true/false field.
_orca_json_field() {   # <json> <path> <type>
  local esc="$1" path="$2" type="$3"
  esc="$(printf '%s' "$esc" | sed "s/'/''/g")"
  sqlite3 :memory: "SELECT CASE WHEN json_type('$esc','$path')='$type' THEN json_extract('$esc','$path') ELSE '' END" 2>/dev/null
}

# Print 1 / 0 for a JSON boolean field at <path>, or nothing if it is
# absent/not a boolean. See the type-name note on _orca_json_field above.
_orca_json_bool() {   # <json> <path>
  local esc="$1" path="$2" t
  esc="$(printf '%s' "$esc" | sed "s/'/''/g")"
  t="$(sqlite3 :memory: "SELECT json_type('$esc','$path')" 2>/dev/null)"
  case "$t" in
    true)  printf '1\n' ;;
    false) printf '0\n' ;;
  esac
}

# Print <json>'s $.error.code, or nothing if absent. MEASURED
# (2026-09-23, feasibility doc Fourth pass (g)): when the Orca APP process
# itself is killed but its terminal daemon survives as an independent child,
# every `orca` CLI call keeps exiting **0** while answering ok:false with this
# code set to "runtime_unavailable" — the whole runtime is unreachable, not
# any one terminal being gone. Exit code alone is therefore not sufficient
# evidence of success; every ok:false path in this driver already treats a
# non-1 `ok` as "could not learn anything" (never `gone`), and terminal_peek
# additionally distinguishes this specific code to report unreachable (10)
# rather than an answered-but-failed read (12) — the same call that a real
# "not on PATH" gets, because from the caller's perspective both mean orca
# itself cannot be reached right now.
_orca_error_code() {   # <json>
  _orca_json_field "$1" '$.error.code' text
}

# READ ONLY: is the pane still there? Built on `orca terminal show` alone,
# deliberately never on `close`'s own return — see the FACT BOUNDARY comment
# at the top of this file for why (`close`'s idempotent-vs-error behavior on an
# already-closed handle is not stable across the two orca versions measured).
#
#   present / 0   show answered ok:true and connected:true
#   gone    / 0   show answered ok:true and connected:false (a real, closed
#                 pane, positively confirmed — not merely unresolved)
#   unknown / 10  orca is unreachable, the JSON did not parse, show answered
#                 ok:false (including terminal_handle_stale — an unresolved
#                 reference is not evidence of gone; a bogus id and a genuine
#                 reach failure look identical from here), or `connected` was
#                 not a boolean this driver recognizes
#
# "Could not ask" must never come back as 0: a caller deletes the placement
# record on `gone` alone (same rule as tmux/herdr).
terminal_pane_state() {
  local id="$1" json ok connected
  command -v orca >/dev/null 2>&1 || { echo unknown; return 10; }
  json="$(_orca_show_json "$id")"
  [ -n "$json" ] || { echo unknown; return 10; }
  _orca_json_valid "$json" || { echo unknown; return 10; }
  ok="$(_orca_json_bool "$json" '$.ok')"
  [ "$ok" = 1 ] || { echo unknown; return 10; }
  connected="$(_orca_json_bool "$json" '$.result.terminal.connected')"
  case "$connected" in
    1) echo present; return 0 ;;
    0) echo gone; return 0 ;;
    *) echo unknown; return 10 ;;
  esac
}

# READ op: print the id's container — its Orca TAB id (a tab may hold more
# than one pane, split; the tab is the addressable grouping, the same role a
# tmux window id or herdr tab_id plays for those drivers). Existence is not
# answered here: an unresolved id is unknown/10, never a claim that the pane
# is gone (same discipline as tmux's terminal_where).
terminal_where() {
  local id="$1" json ok container
  command -v orca >/dev/null 2>&1 || { echo unknown; return 10; }
  json="$(_orca_show_json "$id")"
  [ -n "$json" ] || { echo unknown; return 10; }
  _orca_json_valid "$json" || { echo unknown; return 10; }
  ok="$(_orca_json_bool "$json" '$.ok')"
  [ "$ok" = 1 ] || { echo unknown; return 10; }
  container="$(_orca_json_field "$json" '$.result.terminal.tabId' text)"
  [ -n "$container" ] || { echo unknown; return 10; }
  printf '%s\n' "$container"
  return 0
}

# record op: print the rendered pane content verbatim (NOT parsed) — always
# via `read --screen`: measured, it never carries ANSI/color/SGR information
# in either read mode (memory/design/2026-09-20-orca-terminal-driver-feasibility.md,
# Third pass, (a)), so there is nothing --screen costs against the default and
# it is the one that answers "what does the pane actually show" rather than an
# accumulated, possibly-stale-repaint stream. --lines maps to --limit, passed
# through unchanged to the backend (same contract as tmux/herdr's --lines).
#
# peek exit taxonomy, shared with tmux/herdr so the same numbers mean the same
# thing across every peek-capable driver: orca unreachable — not on PATH, OR
# answered ok:false with error.code=runtime_unavailable (the whole Orca
# runtime is down, not this one terminal — see _orca_error_code) — is **10**;
# an answered-but-failed read for any OTHER reason (ok:false with a different
# code, unparsable JSON, or no output at all) is **12**. 13 is reserved for a
# driver with no peek path at all (plain's permanent case) — orca always has
# a peek path once its CLI is on PATH, so a reach failure here must never
# borrow 13.
terminal_peek() {
  local id="$1"; shift
  local lines=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) lines="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$lines" in ''|*[!0-9]*) lines="" ;; esac
  command -v orca >/dev/null 2>&1 \
    || { echo "orca: not on PATH — cannot reach the terminal to peek pane '$id'" >&2; return 10; }
  local json
  if [ -n "$lines" ]; then
    json="$(orca terminal read --terminal "$id" --screen --limit "$lines" --json 2>/dev/null)"
  else
    json="$(orca terminal read --terminal "$id" --screen --json 2>/dev/null)"
  fi
  [ -n "$json" ] || { echo "orca: could not read terminal '$id' (it may no longer exist)" >&2; return 12; }
  _orca_json_valid "$json" \
    || { echo "orca: read for terminal '$id' returned unparsable output" >&2; return 12; }
  local ok
  ok="$(_orca_json_bool "$json" '$.ok')"
  if [ "$ok" != 1 ]; then
    if [ "$(_orca_error_code "$json")" = runtime_unavailable ]; then
      echo "orca: the Orca runtime is unavailable — cannot reach the terminal to peek pane '$id'" >&2
      return 10
    fi
    echo "orca: could not read terminal '$id' (it may no longer exist)" >&2
    return 12
  fi
  local esc
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  sqlite3 :memory: "SELECT value FROM json_each('$esc','\$.result.terminal.tail')" 2>/dev/null
  return 0
}

# Every write-shaped verb is unimplemented in this PR — reported uniformly as
# `unsupported`, the same word `plain` uses for a capability its manifest does
# not advertise (13). None of these are in this driver's terminal.conf
# `capabilities=` line, so a caller checking the manifest first should never
# reach these at all; they exist because the terminal ABI requires every
# driver to define every required function (the loader verifies it — see
# scripts/lib/terminal-registry.sh's _AGMSG_TERMINAL_REQUIRED).
_orca_unsupported() {   # <verb>
  printf 'unsupported: orca terminal driver does not implement %s yet (read-only in this release)\n' "$1" >&2
  return 13
}
terminal_spawn()   { _orca_unsupported "spawn"; }
terminal_despawn() { _orca_unsupported "despawn"; }
terminal_name()    { _orca_unsupported "name"; }
terminal_arrange() { _orca_unsupported "arrange"; }

# `terminal_poke`'s own `return 13` is written INLINE (not delegated to
# `_orca_unsupported`) so `test_capability_docs.bats`'s exit-code cross-check —
# which scans each driver's `terminal_peek`/`terminal_poke` bodies for their
# own literal `return N` statements — can see it and confirm README.md's
# claimed poke exit codes against this function's real behavior, the same as
# tmux/herdr.
terminal_poke() {
  printf 'unsupported: orca terminal driver does not implement poke yet (read-only in this release)\n' >&2
  return 13
}
