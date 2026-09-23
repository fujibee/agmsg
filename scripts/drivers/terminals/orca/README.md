This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `orca`. Its manifest ceiling (`terminal.conf`):
`peek where spawn despawn name`. `poke` and `arrange` are not implemented and
are not in that ceiling — do not attempt them; each reports `unsupported`
(13) if called anyway. `arrange` has no path forward on this backend at all:
orca's own CLI has no reordering/move/swap verb for a terminal or its tab.

Detection is env-only: `TERM_PROGRAM=Orca` plus `$ORCA_TERMINAL_HANDLE`, the
opaque handle every `orca terminal <verb> --terminal <handle>` call addresses
this pane by (measured, memory/design/2026-09-20-orca-terminal-driver-feasibility.md).
When both herdr and orca could claim the same environment, orca's lower
manifest `priority` means its own env var wins.

## peek exit codes

orca's own `terminal_peek` returns exactly two failure codes: **10** = orca is
not reachable at all — not on PATH, or `orca terminal read` answered ok:false
with error code `runtime_unavailable` (measured: killing the Orca app process
while its terminal daemon survives leaves every `orca` CLI call exiting 0 but
answering this way — the whole runtime is down, not one terminal, so it gets
the same code as "not on PATH"); **12** = `orca terminal read` answered
ok:false for any other reason, unparsable JSON, or nothing at all — read as
the pane being gone or unreadable, orca's backend has no separate "failed but
not confirmed gone" signal, so there is no 11 here. (13 is not one of these:
it is reserved for a driver with no peek path at all, which orca is not — it
always has one once its CLI is on PATH.)

## poke exit codes

`terminal_poke` is not implemented. It always returns **13** (`unsupported`)
— the same code `plain` uses for a capability outside its own manifest
ceiling. `terminal_arrange` returns the same **13** and, unlike `poke`, has
no path forward on this backend at all: orca's own CLI has no
reordering/move/swap verb for a terminal or its tab, checked against 1.4.206.

## spawn

Creates a new terminal in `<project>`'s worktree (`orca terminal create
--worktree "path:<project>" --command "<boot>"`) and prints its handle. No
lost-keystroke race to guard against here, unlike tmux/herdr: `--command`
launches the boot text as the pane's own initial process, not typed input
into an already-open shell, so there is no "wait for the prompt first" step
at all. `--title` is set at creation as a courtesy only — it does not durably
name the pane (see `name` below) — the caller's own follow-up `terminal_name`
call is what actually does. Failure is always **13**.

## despawn

Calls `orca terminal close`, then confirms the result through
`terminal_pane_state` (i.e. `show`'s own `connected` field) rather than
trusting `close`'s own return — measured, `close` on an already-closed handle
answered differently across two orca versions checked three days apart, the
same instability `terminal_pane_state` itself is built to route around.
Confirmed gone is **ok** / 0; anything else is **13**.

## name

Sets the pane's TAB title via `orca terminal rename --title "<team>:<name>"`
— measured, this is the field that actually holds (a per-terminal `show`
title looks like the obvious target but auto-reverts to Orca's own generated
value near-instantly and is not controlled by `rename` at all). Orca has only
one name, so the `mode` argument (key-only vs both) makes no difference here.
Failure is always **13**.
