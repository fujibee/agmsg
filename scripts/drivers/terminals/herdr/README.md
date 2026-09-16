This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `herdr`. Its manifest ceiling (`terminal.conf`):
`spawn despawn peek poke where arrange name`. Every verb `where.sh` lists under
`capabilities=` for herdr works; nothing here narrows that ceiling further.

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
