## Step 0: First-run bootstrap

agmsg keeps its SQLite database, team registry, and runtime state under `~/.agents/skills/agmsg/`. The `./install.sh` install path creates that tree; the Claude Code plugin install path does not (the plugin marketplace only copies this repository into `~/.claude/plugins/cache/`). Before any other command, bootstrap if needed:

```bash
if [ ! -d ~/.agents/skills/agmsg ]; then
  # Newest cached copy of the plugin (several versions can sit side by side).
  installer=$(ls -t ~/.claude/plugins/cache/fujibee-agmsg/agmsg/*/install.sh 2>/dev/null | head -1)
  if [ -n "$installer" ]; then
    bash "$installer" --cmd agmsg
  else
    echo "agmsg not installed. Either:" >&2
    echo "  - run ./install.sh in the agmsg repo, or" >&2
    echo "  - install via /plugin marketplace add fujibee/agmsg && /plugin install agmsg@fujibee-agmsg" >&2
    exit 1
  fi
fi
```

Once `~/.agents/skills/agmsg/` exists this step does nothing, so it is safe to run every time.
