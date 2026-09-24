#!/usr/bin/env bash
# orca terminal driver — a terminal hosted by the Orca multi-agent IDE
# (github.com/stablyai/orca), addressed by its own opaque `term_<uuid>` handle.
#
# Sourced by the terminals registry into the caller's context. terminal_* only,
# no set -e/-u.
#
# PR3 SCOPE (builds on PR1's read-only set): spawn/despawn/name are now real.
# arrange remains unimplemented and reports unsupported (13), the same
# convention `plain` uses for a capability its manifest does not advertise —
# orca's own CLI has no reordering verb at all (checked against 1.4.206).
#
# PR4 SCOPE: adds terminal_enumerate_panes, one of the two OPTIONAL
# sweep/self-proof ops — read-only, nothing written. terminal_pane_process_
# observe, the other one, is DELIBERATELY NOT DEFINED: confirmed live, one
# throwaway pane, before writing anything (the two other, real, pre-existing
# terminals untouched throughout), that `orca terminal show`'s JSON has no
# field carrying an OS process id anywhere (handle/ptyId/incarnationId/
# tabId/leafId/connected/writable/preview/paneRuntimeId/rendererGraphEpoch —
# checked `--help` too, no flag surfaces one either). See the comment where
# that op would otherwise live, further down, for why "define it and always
# fail" is the wrong answer to a permanent gap, not just a smaller one.
#
# PR2 SCOPE: terminal_poke is now real, and adds the optional
# terminal_input_draft hook (composer-draft read, gated on show's
# agentIdentity field).
#
# MEASURED (directly against real orca instances, orca 1.4.198 and 1.4.206;
# not asserted):
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
  printf 'capabilities=peek where spawn despawn name poke\n'
  printf 'syntax_help=orca terminal --help\n'
}

# ABI hook: is <id> an orca handle in THIS driver's grammar? Every handle
# measured against real orca instances is `term_` followed by a UUID's five
# hyphen-separated hex groups
# (`term_ea11f227-ca2c-44b0-a3e6-75c62b9f20ba`). Checked here so `terminal_id_ok`
# and `terminal_detect` share ONE authority (review, #1439): without a
# `terminal_id_ok`, the registry's fallback for "driver has no hook" is to
# ACCEPT any value, and `terminal_detect` printing $ORCA_TERMINAL_HANDLE on
# mere non-emptiness would let a tab/newline/control byte in that env var
# reach a tab-separated placement record and corrupt its framing. Every
# character class below already excludes those bytes, so this doubles as the
# framing guard the record format needs.
_orca_handle_ok() {   # <bare handle>
  local id="$1" rest
  rest="${id#term_}"
  [ "$rest" != "$id" ] || return 1
  # No byte outside hex digits and '-' anywhere. This is the check that
  # actually blocks a tab/newline/space/control byte: a glob `*` placed right
  # after a character class (e.g. `[0-9a-fA-F]*`) only anchors the FIRST
  # character to that class and lets `*` swallow anything unconstrained after
  # it — measured while writing this test, a first draft of this grammar
  # accepted a tab-injected string for exactly that reason.
  case "$rest" in *[!0-9a-fA-F-]*) return 1 ;; esac
  # Exactly five hyphen-separated non-empty groups — the UUID shape every
  # measured handle has: no leading/trailing hyphen, no empty group (adjacent
  # hyphens), and exactly four hyphens total.
  case "$rest" in -*|*-|*--*) return 1 ;; esac
  local hyphens="${rest//[^-]/}"
  [ "${#hyphens}" -eq 4 ] || return 1
  # The groups' own lengths, not just "5 non-empty hex groups in some shape"
  # (review, #1439): a UUID's five groups are fixed at 8-4-4-4-12, and without
  # this check something like `term_a-b-c-d-e` — five non-empty hex groups,
  # just not UUID-shaped — passed.
  local g1 g2 g3 g4 g5
  IFS='-' read -r g1 g2 g3 g4 g5 <<< "$rest"
  [ "${#g1}" -eq 8 ] && [ "${#g2}" -eq 4 ] && [ "${#g3}" -eq 4 ] \
    && [ "${#g4}" -eq 4 ] && [ "${#g5}" -eq 12 ]
}

# Accept the bare placement ref and the instance-qualified locator form. Orca
# has one local runtime; a different explicit instance is malformed, not a
# reason to target whichever runtime happens to be available.
_orca_bare_of() {   # <id>
  local id="$1"
  case "$id" in
    local:*) id="${id#local:}" ;;
    *:*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

terminal_id_ok() {   # <id>
  local bare
  bare="$(_orca_bare_of "$1")" || return 1
  _orca_handle_ok "$bare"
}

# record op: report TWO facts and decide nothing, same shape as tmux/herdr
# (2026-08-31). PRESENCE is the exit code: 0 iff this process is running inside
# an Orca-hosted pane (TERM_PROGRAM=Orca), whether or not the handle itself is
# readable. SELF-ID is stdout: $ORCA_TERMINAL_HANDLE, printed only when it
# matches the bare-handle grammar — an unset OR malformed value is
# "present but could not resolve", not "not orca"; the reason goes to stderr.
# The session-id argument is unused — orca reports via the environment, like
# tmux, not via a session-id lookup like herdr.
terminal_detect() {
  [ "${TERM_PROGRAM:-}" = Orca ] || return 1
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && _orca_handle_ok "$ORCA_TERMINAL_HANDLE"; then
    printf '%s\n' "$ORCA_TERMINAL_HANDLE"
  else
    echo "orca: \$ORCA_TERMINAL_HANDLE is unset or malformed — cannot identify this pane" >&2
  fi
  return 0
}

# Run `orca terminal show` for <id> and print its JSON on stdout. Callers check
# their own $? and stdout emptiness; this only centralizes the invocation.
_orca_show_json() {   # <id>
  local bare
  bare="$(_orca_bare_of "$1")" || return 1
  orca terminal show --terminal "$bare" --json 2>/dev/null
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
# via `read --screen`: measured directly against real orca instances, it
# never carries ANSI/color/SGR information in either read mode, so there is
# nothing --screen costs against the default and
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
  local target
  target="$(_orca_bare_of "$id")" \
    || { echo "orca: malformed terminal locator '$id'" >&2; return 12; }
  command -v orca >/dev/null 2>&1 \
    || { echo "orca: not on PATH — cannot reach the terminal to peek pane '$id'" >&2; return 10; }
  local json
  if [ -n "$lines" ]; then
    json="$(orca terminal read --terminal "$target" --screen --limit "$lines" --json 2>/dev/null)"
  else
    json="$(orca terminal read --terminal "$target" --screen --json 2>/dev/null)"
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
  # ok:true alone is not proof `tail` is the array of lines this function
  # promises to emit (review, #1439): missing/null would otherwise iterate to
  # ZERO rows — indistinguishable from a genuinely empty pane — and a scalar
  # would iterate to ONE row holding that whole scalar as if it were a line of
  # pane content. Require json_type = array FIRST; only a confirmed array
  # (including a correctly empty one) reaches json_each.
  local esc tail_type
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  tail_type="$(sqlite3 :memory: "SELECT json_type('$esc','\$.result.terminal.tail')" 2>/dev/null)"
  [ "$tail_type" = array ] || {
    echo "orca: read for terminal '$id' did not return an array of lines (got: ${tail_type:-missing})" >&2
    return 12
  }
  # "array" alone does not prove every ELEMENT is a line of text (review,
  # #1439): `[{"x":1}]` or `[null]` is still json_type=array, and json_each
  # would hand either straight through as if it were real pane content. Count
  # elements against count-of-text-elements in one query; any mismatch (a
  # single non-string element is enough) rejects the whole read rather than
  # silently passing through the ones that were fine. A genuinely empty array
  # has 0 of both, so it still succeeds.
  #
  # Uses json_each's OWN `type` column, not `json_type(value)` — measured:
  # json_each's `value` column already comes out UNWRAPPED to a native SQLite
  # value for a scalar element (a bare TEXT `a`, not the JSON-quoted `"a"`),
  # and re-parsing that bare text as JSON via a second `json_type(value)` call
  # fails outright ("malformed JSON") the moment a text element is reached —
  # it happened to work for the integer elements in the same test array only
  # because a bare integer's text form is coincidentally also valid JSON.
  # json_each's own `type` column needs no such re-parse.
  local counts total non_text
  counts="$(sqlite3 :memory: "
    SELECT COUNT(*),
           SUM(CASE WHEN type != 'text' THEN 1 ELSE 0 END)
    FROM json_each('$esc','\$.result.terminal.tail')" 2>/dev/null)" \
    || { echo "orca: could not enumerate terminal '$id''s rendered lines" >&2; return 12; }
  IFS='|' read -r total non_text <<< "$counts"
  [ "${non_text:-0}" -eq 0 ] || {
    echo "orca: read for terminal '$id' returned a non-text line (${non_text} of ${total} elements were not strings)" >&2
    return 12
  }
  sqlite3 :memory: "SELECT value FROM json_each('$esc','\$.result.terminal.tail')" 2>/dev/null || {
    echo "orca: could not enumerate terminal '$id''s rendered lines" >&2
    return 12
  }
  return 0
}

# WRITE op: deliver <text> into the pane, followed by Enter, via
# `orca terminal send --text ... --enter`. Same exit taxonomy as
# terminal_peek, so the same numbers mean the same thing across every
# poke-capable driver: orca unreachable — not on PATH, OR answered ok:false
# with error.code=runtime_unavailable (the whole runtime is down, not this one
# terminal) — is 10; an answered-but-failed send for any OTHER reason
# (ok:false with a different code, unparsable JSON, or no output at all) is
# 12. `ok:true` is only the ENVELOPE succeeding — orca accepted and processed
# the command — it is NOT proof the bytes were actually delivered (review,
# #1443): `result.send.accepted` is the real receipt, and only a JSON boolean
# `true` there counts. `accepted:false`, a missing key, or any non-boolean
# shape must all fail closed (12), never report `ok` — an envelope success
# with a rejected/absent/malformed `accepted` is a write that did NOT reach
# the pane, and reporting it as delivered would silently drop the caller's
# text.
terminal_poke() {   # <id> <text>
  local id="$1" text="$2"
  local target
  target="$(_orca_bare_of "$id")" \
    || { echo runtime_error; echo "orca: malformed terminal locator '$id'" >&2; return 12; }
  command -v orca >/dev/null 2>&1 \
    || { echo runtime_error; echo "orca: not on PATH — cannot reach the terminal to poke pane '$id'" >&2; return 10; }
  local json
  json="$(orca terminal send --terminal "$target" --text "$text" --enter --json 2>/dev/null)"
  [ -n "$json" ] || { echo runtime_error; echo "orca: could not send to terminal '$id' (it may no longer exist)" >&2; return 12; }
  _orca_json_valid "$json" \
    || { echo runtime_error; echo "orca: send to terminal '$id' returned unparsable output" >&2; return 12; }
  local ok
  ok="$(_orca_json_bool "$json" '$.ok')"
  if [ "$ok" != 1 ]; then
    if [ "$(_orca_error_code "$json")" = runtime_unavailable ]; then
      echo runtime_error
      echo "orca: the Orca runtime is unavailable — cannot reach the terminal to poke pane '$id'" >&2
      return 10
    fi
    echo runtime_error
    echo "orca: could not send to terminal '$id' (it may no longer exist)" >&2
    return 12
  fi
  local accepted
  accepted="$(_orca_json_bool "$json" '$.result.send.accepted')"
  if [ "$accepted" != 1 ]; then
    echo runtime_error
    echo "orca: send to terminal '$id' was not accepted (accepted=${accepted:-missing or not a boolean})" >&2
    return 12
  fi
  echo ok
  return 0
}

# OPTIONAL op: report <id>'s composer draft, but only when `show` says an
# agent integration is actually present. MEASURED (throwaway terminal, this
# PR, Claude Code v2.1.281 on orca, via `read --screen`): the JSON carries a
# `draft` field at `$.result.terminal.draft`, sibling to `tail`, holding the
# box's real typed text — present once real characters have been typed,
# ABSENT both when the box is truly empty and when it only shows a dim
# candidate suggestion (e.g. `Try "fix typecheck errors"`). That absence is
# exactly the ambiguity this op exists to resolve: on a pane with no agent CLI
# running at all, `draft` is equally absent, and reporting that as "empty
# draft" would be a false claim of a real, checked fact. `show`'s own
# `agentIdentity` field (`$.result.terminal.agentIdentity`, e.g. "claude") is
# present iff orca has recognized an agent integration for this pane,
# independent of `draft` — so it is the gate: identity absent means "cannot
# tell", identity present means an absent `draft` really is a decided,
# checked "nothing typed". Always reads via `--screen`, matching terminal_peek
# (measured: `draft` was observed alongside --screen's own `tail`; there is no
# separate measurement of the non-screen mode carrying it, so this driver only
# claims the mode it actually checked).
#
#   0    identity present; stdout is base64(draft), empty stdout when the key
#        itself is absent (a real "nothing to preserve", not an unknown).
#        Base64, not raw text (review, #1443): exact text — including a
#        trailing newline, or Shift+Enter multi-line content — cannot survive
#        raw stdout + command substitution, which strips every trailing
#        newline unconditionally; "x" and "x\n" would otherwise be
#        indistinguishable to any caller capturing this op's output. Embedded
#        newlines from base64's own optional line-wrapping (GNU wraps at 76
#        cols by default, BSD/macOS does not) are stripped in pure bash after
#        capture, so the encoded form is always exactly one line regardless of
#        implementation.
#   10   could not be determined at all: orca unreachable (not on PATH, or
#        answered ok:false with error.code=runtime_unavailable), the show
#        call's JSON did not parse or answered ok:false for any other reason,
#        OR the call succeeded but no agentIdentity is reported for this pane
#   12   identity WAS confirmed present, but any of: the subsequent draft read
#        itself failed (unparsable JSON, ok:false, no output); `draft` was
#        present but its JSON type was something other than a string (null,
#        object, array, number, boolean — review, #1443: folding every
#        non-text shape to "" via _orca_json_field would report a broken
#        response as a confirmed, decided empty box, rather than the
#        malformed answer it actually is); the extraction's own sqlite3 call
#        exited non-zero (review, #1443 round 2: `"$(cmd; printf x)"` always
#        exits 0 regardless of `cmd`'s own status, so a real extraction
#        failure would otherwise silently become a confirmed-empty 0 — `&&`
#        instead of `;` before the sentinel is what makes this failure visible
#        at all); or base64-encoding itself failed. All distinct from 10 on
#        purpose: none of these is "no identity", so none is folded into its
#        unknown sentinel.
#
# stdout carries an `unknown:<reason>` sentinel on every 10 path (the
# codebase's own non-value-observation convention), so a caller can log why
# without parsing stderr.
terminal_input_draft() {   # <id>
  local id="$1" json ok identity target
  target="$(_orca_bare_of "$id")" \
    || { echo 'unknown:invalid_locator'; echo "orca: malformed terminal locator '$id'" >&2; return 10; }
  command -v orca >/dev/null 2>&1 \
    || { echo "unknown:orca_unreachable"; echo "orca: not on PATH — cannot reach the terminal to read pane '$id''s draft" >&2; return 10; }
  json="$(_orca_show_json "$id")"
  if [ -z "$json" ] || ! _orca_json_valid "$json"; then
    echo "unknown:orca_unreachable"
    echo "orca: could not read terminal '$id' to check its agent identity" >&2
    return 10
  fi
  ok="$(_orca_json_bool "$json" '$.ok')"
  if [ "$ok" != 1 ]; then
    if [ "$(_orca_error_code "$json")" = runtime_unavailable ]; then
      echo "unknown:orca_unreachable"
      echo "orca: the Orca runtime is unavailable — cannot reach the terminal to read pane '$id''s draft" >&2
      return 10
    fi
    echo "unknown:orca_unreachable"
    echo "orca: could not read terminal '$id' to check its agent identity ($(_orca_error_code "$json"))" >&2
    return 10
  fi
  identity="$(_orca_json_field "$json" '$.result.terminal.agentIdentity' text)"
  if [ -z "$identity" ]; then
    echo "unknown:no_agent_identity"
    return 10
  fi
  local read_json read_ok
  read_json="$(orca terminal read --terminal "$target" --screen --json 2>/dev/null)"
  if [ -z "$read_json" ] || ! _orca_json_valid "$read_json"; then
    echo "orca: could not read terminal '$id''s draft" >&2
    return 12
  fi
  read_ok="$(_orca_json_bool "$read_json" '$.ok')"
  if [ "$read_ok" != 1 ]; then
    echo "orca: could not read terminal '$id''s draft ($(_orca_error_code "$read_json"))" >&2
    return 12
  fi
  local esc draft_type draft extract_rc encoded b64_rc _restore_e
  esc="$(printf '%s' "$read_json" | sed "s/'/''/g")"
  draft_type="$(sqlite3 :memory: "SELECT json_type('$esc','\$.result.terminal.draft')" 2>/dev/null)"
  case "$draft_type" in
    '')
      return 0
      ;;
    text)
      # NOT `_orca_json_field` (review, #1443): that helper's own
      # `"$(sqlite3 ...)"` capture strips every trailing newline, which would
      # silently truncate a draft ending in one before this function even gets
      # to base64-encode it — one layer too early for the fix above to help.
      # sqlite3's list-mode output also unconditionally appends its OWN
      # row-terminator newline after the value, on top of whatever the value
      # itself ends with. So: capture with `&&` and a non-newline sentinel
      # (`&&`, not `;` — review, #1443 round 2: `; printf x` always succeeds,
      # so a real sqlite3 failure would otherwise vanish into the command
      # substitution's own always-0 exit status and this whole case would
      # report a broken read as a confirmed empty draft). The sentinel only
      # ever appears when sqlite3 itself exited 0, which is also what protects
      # the payload's own trailing newline(s) from $(...)'s stripping; drop
      # the sentinel, then drop exactly the ONE row-terminator newline sqlite3
      # always adds, leaving the payload's own trailing newline(s) untouched.
      #
      # Both assignments below read `$?`/exit status right after a bare
      # `x=$(cmd)` (CI: check-errexit-status-reads.sh) — under an inherited
      # `set -e` a failing command substitution kills the shell AT the
      # assignment, so the status read never runs and the rc12 handling below
      # would never fire. `&&` inside the substitution does not protect the
      # OUTER assignment statement itself. Lifted with the codebase's own
      # two-line pattern (`agmsg_terminal_load`, terminal-registry.sh) around
      # both, restored once after.
      _restore_e=0
      case $- in *e*) _restore_e=1 ;; esac
      set +e
      draft="$(sqlite3 :memory: "SELECT json_extract('$esc','\$.result.terminal.draft')" 2>/dev/null && printf x)"
      extract_rc=$?
      if [ "$extract_rc" -eq 0 ]; then
        draft="${draft%x}"
        draft="${draft%$'\n'}"
        # A 2-stage pipe's own exit status (no `set -o pipefail` in this file)
        # is the LAST command's — base64's — so this needs no PIPESTATUS
        # gymnastics; a separate `tr -d '\n'` stage would (PIPESTATUS does not
        # survive a "$(...)" boundary), so base64's own line-wrapping (GNU
        # wraps at 76 cols by default, BSD/macOS does not) is stripped in pure
        # bash instead, on the OUTER shell's already-captured value.
        encoded="$(printf '%s' "$draft" | base64)"
        b64_rc=$?
      fi
      [ "$_restore_e" = 1 ] && set -e
      if [ "$extract_rc" -ne 0 ]; then
        echo "orca: could not extract terminal '$id''s draft (sqlite3 exited $extract_rc)" >&2
        return 12
      fi
      if [ "$b64_rc" -ne 0 ]; then
        echo "orca: could not base64-encode terminal '$id''s draft" >&2
        return 12
      fi
      printf '%s\n' "${encoded//$'\n'/}"
      return 0
      ;;
    *)
      echo "orca: terminal '$id''s draft field was not text (got: $draft_type)" >&2
      return 12
      ;;
  esac
}

# The one INSTANCE value every orca row is qualified with (herdr/tmux qualify
# with a socket path because they can have several live servers on one
# machine; orca has exactly one reachable runtime per machine, so there is
# nothing to disambiguate). MEASURED, not invented: every terminal's own JSON
# (`show`, `list`) already carries `executionHostId`, and it read "local" on
# every terminal checked (this driver's own probe, and independently PR1's
# own measurement passes) — no remote execution host exists in any
# environment measured so far. Defined ONCE here so a later PR that needs an
# orca instance value (PR1 itself has no such call site today) uses this
# constant rather than a second literal drifting from it.
_ORCA_INSTANCE=local

# Split both the placement's bare handle and a qualified locator id into the
# same instance/handle pair used by enumeration and locator composition.
terminal_id_split() {   # <id>
  local bare
  bare="$(_orca_bare_of "$1")" || return 1
  _orca_handle_ok "$bare" || return 1
  printf '%s\t%s\n' "$_ORCA_INSTANCE" "$bare"
}

# Resolve the instance carried by a canonical locator without consulting the
# environment or Orca's CLI. A validated Orca handle belongs to the one local
# runtime represented by _ORCA_INSTANCE.
terminal_instance_for_ref() {   # <canonical-ref>
  local ref="$1" halves
  _agmsg_terminal_ref_parse "$ref" || { printf 'unknown:invalid_locator\n'; return 0; }
  [ "$_AGMSG_REF_TERM" = orca ] || { printf 'unknown:wrong_terminal\n'; return 0; }
  halves="$(terminal_id_split "$_AGMSG_REF_ID")" \
    || { printf 'unknown:invalid_orca_id\n'; return 0; }
  printf '%s\n' "$halves"
}

# OPTIONAL OP. Every pane this terminal can see. Contract: see the tmux/herdr
# drivers' own copies and scripts/lib/self-proof.sh. Orca has one runtime, so
# there is only ever one instance row-set (or one `!` row when it cannot be
# read) — never several, unlike herdr/tmux's per-socket sweep.
#
# stdout, one line:
#   <instance><TAB><pane>   for each live terminal `orca terminal list` shows
#   !<TAB><instance>        the runtime could not be read at all
#
# AN ENTRY WE DO NOT UNDERSTAND FAILS THE WHOLE ENUMERATION (same discipline
# as terminal_peek's own tail-array validation above and tmux/herdr's own
# copies of this op): `$.result.terminals` must be a JSON array, and every
# element's `$.handle` must be JSON text; the count of elements is compared
# against the count of ones with a valid handle, and any mismatch means this
# driver does not understand the payload well enough to say what is really
# out there, rather than silently reporting fewer panes than exist.
#
# "JSON text" alone is not "a real orca id" (review, #1441): a handle of ""
# or one carrying a control byte, or one that is text but not this driver's
# own term_<uuid> grammar (a foreign or corrupted value), all passed the
# json_type check but were then either silently DROPPED at print time (an
# undercount masquerading as a complete list — exactly the failure this
# whole discipline exists to prevent) or printed through unvalidated as a
# pane id the rest of this driver would refuse if asked about it directly.
# Every extracted handle is now run through terminal_id_ok -- the SAME
# authority terminal_detect and every other op in this file already answer
# to -- and one failure anywhere aborts the whole enumeration rather than
# quietly narrowing it. Duplicate handles get the same treatment: a payload
# is not "a set of distinct live panes" once a handle repeats, so the whole
# read is nothing this op understands well enough to report, rather than a
# false confirmation that one pane is reachable through two different rows.
terminal_enumerate_panes() {
  command -v orca >/dev/null 2>&1 || return 10
  command -v sqlite3 >/dev/null 2>&1 || return 10
  local json
  json="$(orca terminal list --json 2>/dev/null)"
  if [ -z "$json" ]; then printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0; fi
  _orca_json_valid "$json" || { printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0; }
  local ok
  ok="$(_orca_json_bool "$json" '$.ok')"
  if [ "$ok" != 1 ]; then
    printf '!\t%s\n' "$_ORCA_INSTANCE"
    return 0
  fi
  local esc n_all n_ok
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  n_all="$(sqlite3 :memory: "SELECT CASE WHEN json_type('$esc','\$.result.terminals')='array' THEN json_array_length('$esc','\$.result.terminals') ELSE -1 END" 2>/dev/null)"
  case "$n_all" in ''|*[!0-9]*) printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0 ;; esac
  n_ok="$(sqlite3 :memory: "SELECT count(*) FROM json_each('$esc','\$.result.terminals') WHERE json_type(value,'\$.handle')='text'" 2>/dev/null)"
  case "$n_ok" in ''|*[!0-9]*) printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0 ;; esac
  [ "$n_ok" -eq "$n_all" ] || { printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0; }
  # A genuinely empty terminal list is a real, valid answer -- empty stdout,
  # rc 0 -- and must be told apart from the named `!` hole an unreadable
  # runtime gets (review): with $n_ok=0, `$handles` is the empty string, but
  # `while ... done <<EOF` still supplies exactly ONE empty line to the loop
  # below regardless (a heredoc's content is never truly zero lines), which
  # would otherwise read as one malformed candidate and wrongly fail the
  # whole (actually-fine, actually-empty) enumeration. Handled before the
  # loop is ever entered, not inside it.
  if [ "$n_ok" -eq 0 ]; then return 0; fi
  # Every row is emitted with a leading '=' marker, not bare (review, own
  # finding while testing this fix): `$(...)` strips ALL trailing newlines,
  # so a genuinely empty LAST handle -- its row is just an empty line --
  # would otherwise vanish from $handles entirely rather than surviving as
  # a blank line, silently dropping n_ok's own count out of sync with what
  # the loop below actually sees. The marker makes every row non-empty text
  # regardless of the handle's own content, so nothing is lost to that
  # stripping; '=' is stripped back off per line before use.
  local handles h raw seen="" n_seen=0
  handles="$(sqlite3 :memory: "SELECT '=' || json_extract(value,'\$.handle') FROM json_each('$esc','\$.result.terminals') WHERE json_type(value,'\$.handle')='text'" 2>/dev/null)"
  while IFS= read -r raw; do
    [ -n "$raw" ] || { printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0; }
    h="${raw#=}"
    _orca_handle_ok "$h" || { printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0; }
    case "$seen" in *"	$h	"*) printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0 ;; esac
    seen="$seen	$h	"
    n_seen=$((n_seen + 1))
  done <<EOF
$handles
EOF
  # The loop's own row count must match n_ok too: `$(...)` swallowing a
  # trailing blank line (see the comment above) would otherwise make this
  # loop silently see FEWER rows than the driver believes it validated,
  # passing every per-row check while still under-reporting the total.
  [ "$n_seen" -eq "$n_ok" ] || { printf '!\t%s\n' "$_ORCA_INSTANCE"; return 0; }
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    printf '%s\t%s\n' "$_ORCA_INSTANCE" "${raw#=}"
  done <<EOF
$handles
EOF
  return 0
}

# terminal_pane_process_observe is DELIBERATELY NOT DEFINED (review, #1441).
# MEASURED, not assumed (one throwaway pane, before this PR wrote anything):
# `orca terminal show`'s JSON has no field anywhere that carries an OS
# process id, and no `--help` flag surfaces one either — this op could never
# actually succeed for orca, on any candidate, ever. self-proof.sh's own
# contract treats the two shapes of "no answer" differently and on purpose:
# the function being UNDEFINED reports unsupported/driver_no_process_binding
# (rc 3) and the caller stops asking; the function being defined but
# returning a non-{0,13} code every time reports undetermined/
# pane_process_unreadable (rc 2) instead — a TEMPORARY failure a caller
# retries. Orca's gap is permanent, not temporary, so defining this op just
# to always fail would misreport which kind of "no" self-proof is getting.
# `plain`'s own driver already omits this exact op for the same reason (its
# own file has no process-binding primitive at all) — this is that same
# precedent, not a new one. Self-proof for orca seats does not need this op
# regardless: they identify themselves directly through $ORCA_TERMINAL_HANDLE
# (see the file header), which never needed a process/pid binding.

# `arrange` is unimplemented — reported as `unsupported`, the same word
# `plain` uses for a capability its manifest does not advertise (13). It is
# not in this driver's terminal.conf `capabilities=` line, so a caller
# checking the manifest first should never reach it at all; it exists because
# the terminal ABI requires every driver to define every required function
# (the loader verifies it — see scripts/lib/terminal-registry.sh's
# _AGMSG_TERMINAL_REQUIRED). Orca's own `--help` has no reordering/move/swap
# verb for a terminal or its tab (checked against 1.4.206's CLI surface) —
# nothing for this driver to call, not a choice not to wire one up.
_orca_unsupported() {   # <verb>
  printf 'unsupported: orca terminal driver does not implement %s yet (read-only in this release)\n' "$1" >&2
  return 13
}
terminal_arrange() { _orca_unsupported "arrange"; }

# RECORD op: create a new terminal in <project>'s worktree, launch <boot> as
# its initial command, print the new terminal's handle. Unlike tmux/herdr,
# there is no separate "wait for the shell prompt, then type the boot command"
# step here and therefore none of their lost-keystroke race: `orca terminal
# create --command` launches the boot text AS the pane's own initial process
# (measured, Third pass (c)) — the command is argv, not typed input, so there
# is nothing to type before the shell is ready because there is no separate
# typing step at all.
#
# <target> (window|pane-h|pane-v) is validated the same as tmux/herdr — a typo
# must fail, not silently spawn — but orca's `create` has no window/split
# distinction of its own (every call just adds one more terminal to the
# worktree), so all three valid values behave identically here.
#
# --title is set at creation as a best-effort courtesy (matching tmux's own
# -n/-T at creation), NOT the naming contract itself — measured (Third pass
# (b)), a terminal's `show`-visible title reverts to Orca's own auto-generated
# value almost immediately regardless of how it was set, so the caller's own
# later `terminal_name` call (against the TAB title via `rename`, which does
# hold) is what actually names this pane.
#
# UNMEASURED: whether `--worktree "path:<project>"` for a path Orca has never
# opened as a worktree before fails cleanly or does something unexpected —
# every measurement so far used a worktree already open in the app. Surfaces
# as an ordinary create failure (13) either way; not specifically verified.
terminal_spawn() {
  local name="$1" project="$2" target="$3"; shift 3
  local boot="$*"
  case "$target" in
    window|pane-h|pane-v) : ;;
    *) printf 'unsupported: unknown target: %s (window|pane-h|pane-v)\n' "$target" >&2; return 13 ;;
  esac
  command -v orca >/dev/null 2>&1 \
    || { printf 'orca: not on PATH — cannot spawn a terminal in %s\n' "$project" >&2; return 13; }
  # `json="$(cmd)"` (not combined with `local`) propagates a non-zero cmd
  # exit to THIS assignment statement's own status -- under a caller's set -e
  # that aborts right here, before any of the ok/13 handling below ever runs
  # (review, #1440). `|| true` on the assignment itself neutralizes it; the
  # emptiness/validity checks immediately after already treat a failed call
  # the same as an empty or unparsable one.
  local json ok id
  json="$(orca terminal create --worktree "path:$project" --title "$name" --command "$boot" --json 2>/dev/null)" || true
  [ -n "$json" ] || { printf 'orca: terminal create for %s produced no output\n' "$project" >&2; return 13; }
  _orca_json_valid "$json" \
    || { printf 'orca: terminal create for %s returned unparsable output\n' "$project" >&2; return 13; }
  ok="$(_orca_json_bool "$json" '$.ok')"
  if [ "$ok" != 1 ]; then
    printf 'orca: terminal create for %s failed (%s)\n' "$project" "$(_orca_error_code "$json")" >&2
    return 13
  fi
  id="$(_orca_json_field "$json" '$.result.terminal.handle' text)"
  [ -n "$id" ] || { printf 'orca: terminal create for %s answered ok with no handle\n' "$project" >&2; return 13; }
  # Same boundary #1439 already closed for terminal_detect: an ok:true
  # response is not proof the handle is well-formed. A malformed handle
  # (control byte, wrong grammar) must never reach a placement record.
  _orca_handle_ok "$id" \
    || { printf 'orca: terminal create for %s answered ok with a malformed handle\n' "$project" >&2; return 13; }
  printf '%s\n' "$id"
  return 0
}

# control op: close <id>, then CONFIRM it through `show`'s own `connected`
# field — never through `close`'s own return. MEASURED (Third pass (d)):
# `close` on an already-closed handle changed behaviour between the two orca
# versions checked three days apart (1.4.198 errored with
# terminal_handle_stale; 1.4.206 returns ok:true, ptyKilled:false) — the exact
# instability `terminal_pane_state`'s own header already documents as the
# reason it is built on `show` alone. `terminal_despawn` reuses that same
# function rather than re-deriving the same fact a second way: after issuing
# the close, the only question left is "is this pane now gone", which
# `terminal_pane_state` already answers honestly (gone only on a positively
# confirmed connected:false, never merely because `close` claimed success).
terminal_despawn() {
  local id="$1"
  local target
  target="$(_orca_bare_of "$id")" \
    || { echo runtime_error; echo "orca: malformed terminal locator '$id'" >&2; return 13; }
  command -v orca >/dev/null 2>&1 \
    || { echo runtime_error; echo "orca: not on PATH — cannot despawn terminal '$id'" >&2; return 13; }
  # `close`'s own exit status is deliberately never inspected (see the header
  # comment above) -- `|| true` makes that literal: a bare failing command
  # here would otherwise abort under a caller's set -e before the
  # pane_state re-check below ever runs (review, #1440), defeating the whole
  # point of not trusting close in the first place.
  orca terminal close --terminal "$target" --json >/dev/null 2>&1 || true
  # Same errexit hazard as `close` above, on the very next line: pane_state's
  # own documented contract returns non-zero (10) for unknown, so this
  # assignment's status would abort a set -e caller before the runtime_error
  # output and 13 below ever run (review, #1440) -- silently violating
  # despawn's own "anything else is 13" contract instead of honoring it.
  local state
  state="$(terminal_pane_state "$id")" || true
  if [ "$state" = gone ]; then
    echo ok
    return 0
  fi
  echo runtime_error
  echo "orca: terminal '$id' was not confirmed gone after close (pane_state: ${state:-unknown})" >&2
  return 13
}

# control op: set <id>'s visible name. Orca has exactly ONE name — the TAB
# title `orca terminal rename --title` actually controls (MEASURED, Third
# pass (b): a per-terminal `show.title` looks like the obvious target but
# auto-reverts to Orca's own generated value near-instantly and is NOT what
# rename controls; the tab title exposed by `list --include-visual-layouts`
# is the field that holds). Per this driver ABI's own contract comment
# (scripts/lib/terminal-registry.sh, terminal_name's doc): "a driver that has
# only one name treats it as the key" — so <mode> (key vs default/both) is
# accepted for signature compatibility but makes no difference here; there is
# no separate internal-key mechanism to skip.
terminal_name() {
  local id="$1" team="$2" name="$3" label
  local target
  target="$(_orca_bare_of "$id")" \
    || { echo runtime_error; echo "orca: malformed terminal locator '$id'" >&2; return 13; }
  label="$team:$name"
  command -v orca >/dev/null 2>&1 \
    || { echo runtime_error; echo "orca: not on PATH — cannot rename terminal '$id'" >&2; return 13; }
  # Same errexit hazard as terminal_spawn's create call, same fix (#1440).
  local json ok
  json="$(orca terminal rename --terminal "$target" --title "$label" --json 2>/dev/null)" || true
  [ -n "$json" ] || { echo runtime_error; echo "orca: rename for '$id' produced no output" >&2; return 13; }
  _orca_json_valid "$json" \
    || { echo runtime_error; echo "orca: rename for '$id' returned unparsable output" >&2; return 13; }
  ok="$(_orca_json_bool "$json" '$.ok')"
  if [ "$ok" != 1 ]; then
    echo runtime_error
    echo "orca: rename for '$id' failed ($(_orca_error_code "$json"))" >&2
    return 13
  fi
  echo ok
  return 0
}

# Orca has one name: terminal_name writes the visible tab title, which is also
# the only identity key this driver can read back.
terminal_expected_label() {   # <team> <agent>
  printf '%s:%s\n' "$1" "$2"
}
