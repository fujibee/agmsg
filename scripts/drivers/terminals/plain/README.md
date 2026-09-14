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

For a bare `plain:-` **claude-code** target specifically, `peek.sh` tries one
substitute before giving up: the target's own session transcript, read
straight off disk (never a screen, never written to). It only works when
this session's own actas lock for that member resolves to a live owner; if
it does, the output leads with an `AGMSG-NATIVE-RECORD:` marker line so a
caller never mistakes a transcript for a screen. No lock, no owner, or no
transcript falls straight through to the unsupported message above,
unchanged.

## poke exit codes

**13** = unsupported (no emulator/tty, same as peek); **10** = the adapter
could not write to the tty. Same absence of a 12/11 split as peek, for the
same reason.

## poke on a bare plain:- target (no emulator/tty)

There is no pane to type into, but that is not automatically a dead end:

- **Both the caller and the target are Claude Code.** Do not call `poke.sh`
  at all — use Claude Code's own local session messaging instead: ListAgents
  to find the target's row, then SendMessage to it directly. A member spawned
  by agmsg carries the session name `<team>-<name>` (`spawn.sh`'s own `-n`
  convention), so match ListAgents' row by that name. `poke.sh` has no shell
  path to this channel (its wire protocol is internal and undocumented,
  #1229) — called anyway for this pair, it refuses (still exit 13) and names
  this section rather than attempting anything.
- **Otherwise** (the caller is not Claude Code, or the target's type has no
  native channel of its own): `poke.sh` delivers the poke text as an
  ordinary agmsg message instead of typing it — the same store `send.sh`
  writes to, picked up on the target's own delivery terms rather than
  synchronously. `from` is the caller's own agmsg identity in this member's
  team, resolved from its own actas lock; `poke.sh` refuses rather than
  guessing one it cannot resolve to exactly one role. `poke.sh`'s own output
  says which of these two things happened.
