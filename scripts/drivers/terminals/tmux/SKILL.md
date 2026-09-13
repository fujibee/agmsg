This driver's own capability notes (#1082) — read only after `where.sh` names
this session's terminal as `tmux`. Its manifest ceiling (`terminal.conf`):
`spawn despawn peek poke where arrange name`. Every verb `where.sh` lists under
`capabilities=` for tmux works; nothing here narrows that ceiling further.

## peek exit codes

**13** = unsupported (the target never existed, or is not a tmux pane/window
id at all); **12** = `capture-pane` failed, read as the pane being gone —
tmux's backend has no separate "failed but not confirmed gone" signal, so
there is no 11 here (contrast herdr's own file, which has one); **10** = tmux
is not reachable (not on PATH, or no server for the given socket).

## poke exit codes

**13** = unsupported (the target never existed); **12** = `send-keys` failed —
tmux has no live-agent distinction the way herdr does, so this covers both
"pane gone" and "nothing there to receive"; **10** = tmux is unreachable.
