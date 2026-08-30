#!/usr/bin/env bash
# plain terminal driver — OS terminal window, no addressable pane.
#
# Sourced by the terminals registry into the caller's context (docs/spec/
# driver-interface.md §1.2). Exposes terminal_* functions only; no set -e/-u.
# plain is the detection fallback and can spawn a window, but has no pane to
# peek/poke/despawn/name — those return status 13 (runtime_error) with a reason
# on stderr, the "unsupported" convention (§1.4).

# control op: deps check. plain has no external dependency.
terminal_check() { echo ok; return 0; }

# metadata op: exit 0, key=value only.
terminal_describe() {
  printf 'name=plain\n'
  printf 'backend=OS terminal window (no addressable pane)\n'
  printf 'capabilities=spawn\n'
}

# record op: plain is the fallback — it always "matches", but has no addressable
# pane, so it prints '-' as the self id and exits 0. (Detection order puts plain
# last, so it only wins when neither tmux nor herdr claimed the session.)
terminal_detect() { printf '%s\n' '-'; return 0; }

_plain_unsupported() {
  printf 'unsupported: plain terminal has no addressable pane (%s)\n' "$1" >&2
  return 13
}
terminal_peek()    { _plain_unsupported "peek"; }
terminal_poke()    { _plain_unsupported "poke"; }
terminal_despawn() { _plain_unsupported "despawn"; }
terminal_name()    { _plain_unsupported "name"; }
