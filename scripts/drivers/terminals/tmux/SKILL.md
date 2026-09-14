This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `tmux`. Its manifest ceiling (`terminal.conf`):
`spawn despawn peek poke where arrange name`. Every verb `where.sh` lists under
`capabilities=` for tmux works; nothing here narrows that ceiling further.

## peek exit codes

tmux's own `terminal_peek` returns exactly two failure codes: **12** =
`capture-pane` failed, read as the pane being gone — tmux's backend has no
separate "failed but not confirmed gone" signal, so there is no 11 here
(contrast herdr's own file, which has one); **10** = tmux is not reachable
(not on PATH, or no server for the given socket). (13 is not one of these: a
target that never existed, or is not a tmux pane/window id at all, is refused
by the caller's own ref parser before any driver is loaded, not by this
function — see the "where" section's point 4 in the root file.)

## poke exit codes

tmux's own `terminal_poke` returns exactly two failure codes: **12** =
`send-keys` failed — tmux has no live-agent distinction the way herdr does,
so this covers both "pane gone" and "nothing there to receive"; **10** = tmux
is unreachable. (13 is not one of these, for the same reason as peek's.)
