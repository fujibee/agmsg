<!-- Codex overlay for the shared SKILL.md. -->

<!-- agmsg:slot shell-extra -->
On Windows PowerShell, invoke Git Bash explicitly and keep the full `bash -lc` payload inside one single-quoted string:

`& 'C:\Program Files\Git\bin\bash.exe' -lc '~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" codex'`

Do not use POSIX `'"'"'` quote splicing in PowerShell, and do not use escaped double quotes inside the wrapper.
<!-- /agmsg:slot shell-extra -->

<!-- agmsg:slot delivery -->
  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick `monitor`, `turn`, or `off` delivery. Empty input means `monitor`.
     Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`.
     Monitor uses the Codex app-server bridge; it changes how `codex` starts and is documented in `docs/codex-monitor-beta.md`.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Resolve the role and run `identities.sh`/`join.sh` for `__AGENT_TYPE__` as needed.
2. Record the Codex thread with `codex-record-session.sh` so a later spawn can resume it.
3. Use the role as the active FROM; monitor delivery is routed only to its recorded thread.
<!-- /agmsg:slot actas -->

<!-- agmsg:slot drop -->
If argument starts with "drop", run `reset.sh "$(pwd)" __AGENT_TYPE__ <name>` and clear the role's recorded Codex seat.
<!-- /agmsg:slot drop -->

<!-- agmsg:slot spawn -->
If argument starts with "spawn", run `spawn.sh <type> <name> --project "$(pwd)" [options]`. Codex spawn uses the bundled shim and bridge; `despawn --force` is required when a Codex member has no watcher.
<!-- /agmsg:slot spawn -->

<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.

For `mode monitor|turn|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; `both` is unsupported. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
