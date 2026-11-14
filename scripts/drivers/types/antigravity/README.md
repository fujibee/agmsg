# Antigravity TUI launcher

`agy-tui` starts `agy` under agmsg's PTY supervisor, which is the only way
Antigravity gets monitor delivery. The installer does not put an `agy-tui`
command on your machine. The launcher is the script `agy-tui.sh` in this
directory; make the command yourself.

`agy-tui.sh` finds the rest of agmsg relative to its own location, so it has to
be run where it is, not copied elsewhere. Put a two-line wrapper on your `PATH`
instead (here `~/.local/bin`; use any directory that is on it):

```bash
cat > ~/.local/bin/agy-tui <<'WRAPPER'
#!/usr/bin/env bash
exec bash "$HOME/.agents/skills/agmsg/scripts/drivers/types/antigravity/agy-tui.sh" "$@"
WRAPPER
chmod +x ~/.local/bin/agy-tui
```

Change the path if your agmsg lives elsewhere (a `--cmd` install uses its own
skill directory, and a checkout works too: point it at that checkout's
`scripts/drivers/types/antigravity/agy-tui.sh`). If you move or rename the
install, update the path.

Usage, and what the monitor does, are in `docs/antigravity-monitor-beta.md`.
