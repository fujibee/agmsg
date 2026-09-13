This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `plain`. Its manifest ceiling (`terminal.conf`):
`spawn despawn peek poke`. `where`, `arrange`, and `name` are NOT in that
list — plain has no addressable pane to locate, arrange, or label at all, so
do not attempt them; there is nothing more to read about them here.

## peek and poke are conditional on the ceiling, not guaranteed by it

The manifest lists `peek poke` because SOME plain placements support them —
one whose record is qualified with a recognized terminal emulator and a real
tty (`plain:<emulator>:<tty>`), reached through that emulator's own adapter
(currently AppleScript/`osascript` on macOS). A bare `plain:-` placement (no
emulator, no addressable tty — the common case for an OS terminal window
opened without one) narrows the ceiling to unsupported for both, at the
instance level, before either verb is attempted.

## peek exit codes

**13** = unsupported — this placement has no emulator/tty to reach at all
(the bare `plain:-` case), or this agmsg install has no adapter for the
recorded emulator; **10** = the emulator-qualified adapter could not read the
tty (a momentary reach failure, not a capability verdict). Plain's peek has
no 12/11 split: it has no side channel to CONFIRM a tty is gone the way
herdr's pane read or tmux's pane listing can, so a reach failure never claims
more than "could not read it right now".

## poke exit codes

**13** = unsupported (no emulator/tty, same as peek); **10** = the adapter
could not write to the tty. Same absence of a 12/11 split as peek, for the
same reason.
