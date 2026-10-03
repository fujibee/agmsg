#!/usr/bin/env bash
# claude-desktop terminal driver — a Claude Code session running in the
# Claude desktop app's Code tab.
#
# Sourced by the terminals registry into the caller's context. terminal_* only,
# no set -e/-u.
#
# Why this driver exists: the desktop app's Code tab has no pane at all — its
# only handle is the conversation itself (the Claude Code session id). Without
# a driver for it, a desktop seat either resolved to plain's "no addressable
# pane" sentinel or inherited whatever pane env var happened to be lying
# around (observed 2026-10-02: a desktop seat carrying a stale herdr
# placement left behind by an earlier terminal session). This driver gives it
# its own identity instead: present and addressable by session id, but with
# no pane to peek, poke, spawn, despawn, arrange or name.
#
# MEASURED 2026-10-02, on a live Claude desktop app process: its environment
# carries CLAUDE_CODE_ENTRYPOINT=claude-desktop; a plain terminal session
# carries CLAUDE_CODE_ENTRYPOINT=cli. No other marker was checked or is relied
# on here.
#
# Step 1 scope (see memory/design/2026-10-02-desktop-app-terminal-drivers.md):
# detect + where only. Waking an idle desktop session, delivery changes, and
# everything else are explicitly out of scope for this driver.

terminal_check() { echo ok; return 0; }

terminal_describe() {
  printf 'name=claude-desktop\n'
  printf 'backend=Claude desktop app (Code tab)\n'
  printf 'capabilities=where\n'
}

# ABI hook: is <id> usable as a placement id? The desktop app's session id is
# an opaque token this driver has not measured a strict grammar for (unlike
# orca's UUID-shaped handle) — Claude Code's own session id is what is
# addressed, not something this driver mints or parses. What this driver DOES
# own is framing safety: a tab, newline or carriage return in the id would
# corrupt a tab-separated placement record (same concern orca's own
# _orca_handle_ok header documents), so that is the one thing checked here.
_claude_desktop_id_ok() {   # <id>
  local id="$1"
  [ -n "$id" ] || return 1
  case "$id" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  return 0
}

terminal_id_ok() {   # <id>
  _claude_desktop_id_ok "$1"
}

# record op: report TWO facts and decide nothing, same shape as orca/tmux/herdr
# (2026-08-31). PRESENCE is the exit code: 0 iff CLAUDE_CODE_ENTRYPOINT is
# claude-desktop, whether or not a usable session id is at hand. SELF-ID is
# stdout: the session id, preferring the argument (the same value every other
# driver here is handed), falling back to $CLAUDE_CODE_SESSION_ID when the
# argument is empty — nothing else is consulted, so a present-but-unresolved
# desktop session prints nothing and names the reason on stderr rather than
# guessing.
terminal_detect() {
  local sid="${1:-}"
  [ "${CLAUDE_CODE_ENTRYPOINT:-}" = claude-desktop ] || return 1
  if [ -z "$sid" ]; then sid="${CLAUDE_CODE_SESSION_ID:-}"; fi
  if [ -n "$sid" ] && _claude_desktop_id_ok "$sid"; then
    printf '%s\n' "$sid"
  else
    echo "claude-desktop: no usable session id (neither the caller's argument nor the CLAUDE_CODE_SESSION_ID environment variable) — cannot identify this session" >&2
  fi
  return 0
}

# Optional environment-only self identity, same contract as orca's own
# terminal_self_env: an entrypoint marker without a usable session id is
# ambiguous ("present but could not resolve"); a session id without the
# marker is not this driver's concern at all.
terminal_self_env() {
  local sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ "${CLAUDE_CODE_ENTRYPOINT:-}" != claude-desktop ]; then
    printf 'n/a:not_in_terminal\n'
    return 0
  fi
  if [ -z "$sid" ] || ! _claude_desktop_id_ok "$sid"; then
    printf 'unknown:claude_desktop_session_id_unset_or_malformed\n'
    return 0
  fi
  printf '%s\n' "$sid"
}

# The desktop app exposes no generation witness of its own.
terminal_epoch() {
  printf 'n/a:no_generation\n'
}

# READ op: the id's container. A desktop session has no notion of a container
# at all (no window, no tab, no split) — this is a decided fact about what
# this driver has to observe, not a failed read, so it is reported with the
# codebase's own n/a: prefix (terminal-registry.sh's observation-field
# convention), never unknown:.
terminal_where() {
  printf 'n/a:no_container_concept\n'
  return 0
}

# No addressable pane exists to ask about at all — not "gone", not
# "unknown", but the same permanent absence `plain`'s own terminal_pane_state
# reports (13), never 0: a caller deletes the placement record on a `gone`
# answer alone, and this driver can never honestly give one.
terminal_pane_state() { echo unknown; return 13; }

_claude_desktop_unsupported() {   # <verb>
  printf 'unsupported: claude-desktop terminal driver does not implement %s — this is the Claude desktop app, which has no addressable pane\n' "$1" >&2
  return 13
}
terminal_spawn()   { _claude_desktop_unsupported "spawn"; }
terminal_despawn() { _claude_desktop_unsupported "despawn"; }
terminal_peek()    { _claude_desktop_unsupported "peek"; }
terminal_poke()    { _claude_desktop_unsupported "poke"; }
terminal_arrange() { _claude_desktop_unsupported "arrange"; }
terminal_name()    { _claude_desktop_unsupported "name"; }

# No independent agent key to compare — this driver never names a pane.
terminal_expected_label() { printf 'n/a:no_addressable_pane\n'; }

# No activity, label, key or title concept of its own — same shape as
# plain's own terminal_team_observe, all four fields n/a.
terminal_team_observe() {
  printf 'n/a:no_addressable_pane\tn/a:no_addressable_pane\tn/a:no_addressable_pane\tn/a:no_addressable_pane\n'
}
