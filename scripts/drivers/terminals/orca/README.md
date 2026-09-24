This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `orca`. Its manifest ceiling (`terminal.conf`):
`peek where spawn despawn name poke`. `arrange` is not implemented and is not
in that ceiling — do not attempt it; it reports `unsupported` (13) if called
anyway, and has no path forward on this backend at all: orca's own CLI has no
reordering/move/swap verb for a terminal or its tab.

Detection is env-only: `TERM_PROGRAM=Orca` plus `$ORCA_TERMINAL_HANDLE`, the
opaque handle every `orca terminal <verb> --terminal <handle>` call addresses
this pane by (measured directly against real orca instances).
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

`terminal_poke` sends `<text>` followed by Enter via
`orca terminal send --text ... --enter`. Same taxonomy as peek: **10** = orca
unreachable (not on PATH, or `orca terminal send` answered ok:false with error
code `runtime_unavailable`); **12** = `orca terminal send` answered ok:false
for any other reason, unparsable JSON, nothing at all, OR answered ok:true but
`result.send.accepted` was not the JSON boolean `true` (false, missing, or any
non-boolean shape) — `ok:true` is only the envelope succeeding, not proof the
bytes were actually delivered to the pane. (13 is not one of these — reserved
for a driver with no poke path at all, which orca is not. `terminal_arrange`
returns that code unconditionally instead, and unlike `poke`, has no path
forward on this backend at all: orca's own CLI has no reordering/move/swap
verb for a terminal or its tab, checked against 1.4.206.)

## terminal_input_draft (optional hook)

`terminal_input_draft <id>` reports the pane's composer draft, gated on
whether orca recognizes an agent integration for that pane at all. **stdout on
success (0) is `base64(draft)`, not raw text** — command substitution strips
every trailing newline unconditionally, so raw text cannot carry a trailing
newline or reliably round-trip Shift+Enter multi-line content; decode with
`base64 -d`. Empty stdout (nothing to decode) means an empty draft.

- **0** — `show` reports an `agentIdentity` for this pane, and `read`'s
  `draft` field is either a JSON string (stdout is its base64-encoded exact
  bytes) or absent (empty stdout — a real "nothing typed", not an unknown).
- **10** — could not be determined: orca unreachable, `show`'s JSON did not
  parse or answered ok:false, OR `show` succeeded but reports no
  `agentIdentity` at all for this pane (no agent integration to read a draft
  from — the case a bare "empty string" would misreport as a checked fact).
  stdout carries `unknown:orca_unreachable` or `unknown:no_agent_identity`.
- **12** — `agentIdentity` WAS confirmed present, but either the subsequent
  `read` call itself failed (unparsable JSON, ok:false, or no output), or
  `draft` was present with a non-string JSON type (null, object, array,
  number, boolean) — a malformed response, not a confirmed empty box. Both
  are a different failure than "no identity", kept out of 10's unknown
  sentinel on purpose.

Not in `capabilities=`: optional ABI hooks are never listed there (matches
`terminal_id_ok`/`terminal_peek_styled` on every driver) — a caller checks for
this one with `declare -F terminal_input_draft` after loading the driver.

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
