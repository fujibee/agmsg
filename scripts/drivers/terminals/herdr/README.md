This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `herdr`. Its manifest ceiling (`terminal.conf`):
`spawn despawn peek poke where arrange name`. Every verb `where.sh` lists under
`capabilities=` for herdr works; nothing here narrows that ceiling further.

## Caller-owned placement: `AGMSG_HERDR_PLACEMENT`

`spawn` normally places a member by splitting the spawning pane (`pane split`)
or creating a tab (`--window`), then `pane run`s the boot in it. A caller that
manages the layout of its herdr tab itself (a reconcile/layout library, a
tab-lock, a placement journal) cannot let the driver split, because a pane the
driver creates lands outside that layout and the caller can neither find it
nor close it later. Set `AGMSG_HERDR_PLACEMENT` to a command template
containing `{cmd}`; `spawn` then runs it instead of split + run. The command
must (1) create the pane in this herdr instance, (2) launch the boot — `{cmd}`
is replaced with the shell-quoted boot path, exactly as `AGMSG_TERMINAL`'s
`{cmd}` is — inside that pane, and (3) print the bare pane id (`wN:pX`) as its
only stdout line. The driver verifies the id with `pane get`, renames the pane
with the member label, and records the placement, so `peek`, `poke`,
`despawn` and `fix` reach the pane as usual. A failed command, an empty,
multi-line or non-grammar stdout, or an id herdr does not know all fail with
**13** before any pane is touched; the command owns whatever it created.
Before 1.3.0 the `AGMSG_TERMINAL` template was consulted inside a herdr pane
and served this purpose; the herdr driver's own split no longer does, so a
caller that relied on it must set this variable (`AGMSG_TERMINAL` is still
read on the non-tmux, non-herdr path).

## peek exit codes

herdr's own `terminal_peek` returns exactly three failure codes, never a
fourth: **12** = herdr's own reply confirmed the pane is gone; **11** = the
read failed WITHOUT herdr confirming that — a denied socket operation, a
timeout, an unrecognized reply, or a reply about some OTHER pane — treat it
as "cannot tell", never as "gone" (#1158); **10** = herdr is not reachable at
all (not on PATH). herdr is, as of this writing, the one driver that
distinguishes 11 from 12; a driver whose backend never reports a
confirmed-gone signal separately from an ordinary failure has no way to emit
11 — check that driver's own file, not this one. (13 is not one of these: a
target that never existed is refused by the caller's own ref parser before
any driver is loaded, not by this function — see the "where" section's point
4 in the root file.)

## poke exit codes

herdr's own `terminal_poke` returns exactly two failure codes: **12** = the
pane exists but has no live agent to receive — a member whose agent process
EXITED can be peeked but not poked — or the pane is confirmed gone; poke does
not split those two the way peek splits 11 from 12, because either one needs
the same next action. **10** = herdr is unreachable. (13 is not one of
these, for the same reason as peek's.)
