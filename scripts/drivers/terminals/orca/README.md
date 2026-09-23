This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `orca`. Its manifest ceiling (`terminal.conf`):
`peek where`. This is a read-only driver: `spawn`, `despawn`, `poke`, `name`
and `arrange` are not implemented yet (a later release adds them) and are not
in that ceiling — do not attempt them; each reports `unsupported` (13) if
called anyway.

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

`terminal_poke` is not implemented in this release. It always returns **13**
(`unsupported`) — the same code `plain` uses for a capability outside its own
manifest ceiling.
