This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `herdr`. Its manifest ceiling (`terminal.conf`):
`spawn despawn peek poke where arrange name`. Every verb `where.sh` lists under
`capabilities=` for herdr works; nothing here narrows that ceiling further.

## peek exit codes

**13** = unsupported — this agmsg install has no measured adapter for the
target, or the pane never existed; **12** = herdr's own reply confirmed the
pane is gone; **11** = the read failed WITHOUT herdr confirming that — a
denied socket operation, a timeout, an unrecognized reply — treat it as
"cannot tell", never as "gone" (#1158). herdr is, as of this writing, the one
driver that distinguishes 11 from 12; a driver whose backend never reports a
confirmed-gone signal separately from an ordinary failure has no way to emit
11 and stays with 10/12/13 only — check that driver's own file, not this one.
**10** = herdr is not reachable at all (not on PATH).

## poke exit codes

**13** = unsupported (no measured adapter, or the target never existed);
**12** = the pane exists but has no live agent to receive — a member whose
agent process EXITED can be peeked but not poked; **10** = herdr is
unreachable.
