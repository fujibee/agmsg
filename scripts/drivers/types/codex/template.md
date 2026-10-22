<!-- Codex overlay for the shared SKILL.md. -->

<!-- agmsg:slot shell-extra -->
On Windows PowerShell, invoke Git Bash explicitly and keep the full `bash -lc` payload inside one single-quoted string:

`& 'C:\Program Files\Git\bin\bash.exe' -lc '~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" codex'`

Do not use POSIX `'"'"'` quote splicing in PowerShell, and do not use escaped double quotes inside the wrapper.
<!-- /agmsg:slot shell-extra -->

<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Choose how incoming messages reach this agent. Show this screen every time (a new join, a new seat added by someone already using agmsg, and when the mode is changed). First run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg daemon offer __AGENT_TYPE__`; it only reads and prints one line:
     - `agmsgd=available`: ask the user to pick one, in this order:
       1. `agmsgd` — notices delivered directly by a background service (recommended). Choosing it registers a background service that starts at login; `agmsg daemon disable` stops and removes it. Empty input means this one.
       2. `monitor (legacy)` — the Codex app-server bridge streams the inbox (the `monitor` mode value). It changes how `codex` starts and is documented in `docs/codex-monitor-beta.md`.
       3. `turn`, 4. `off` — as before.
     - `agmsgd=on`: do not ask which to use. Say "agmsgd is on: notices are delivered directly" and ask only whether to keep using it or switch to `monitor (legacy)`.
     - `agmsgd=not-running reason=...`: agmsgd is turned on but is not running, so do not say notices are delivered directly. Say so with the reason and ask whether to start it (`agmsg delivery agmsgd` starts it) or switch to `monitor (legacy)`.
     - `agmsgd=unavailable reason=...`: do not offer agmsgd; say the reason in one line, then ask for `monitor (legacy)`, `turn`, or `off` (empty input means `monitor`).

     To apply the choice, run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery <choice> --type __AGENT_TYPE__ --project "$(pwd)"` with `<choice>` = `agmsgd`, `monitor`, `turn` or `off` (`monitor (legacy)` is the value `monitor`) and show its output:
     - `agmsgd` turns the background service on (`daemon enable`) and leaves the project on `monitor` as the fallback for a seat whose destination is not confirmed yet. If it fails, say so and offer the other choices.
     - Keep using agmsgd (it is on or turned on but not running): run `agmsg delivery agmsgd` the same way; it also records that this project uses agmsgd.
     - `monitor (legacy)` (and `turn`, `both`, `off`) is a real opt-out: the CLI records that this project does not use agmsgd, so agmsgd stops delivering here and the project keeps the old path. agmsgd stays on for the install's other projects; when it says so, pass on its line that `agmsg daemon disable` turns agmsgd off for all of them.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__`. If `<name>` is not listed, join with `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`.
2. Record this Codex thread and its effective profile directory so a later spawn can resume it and route notices to the right profile: `~/.agents/skills/__SKILL_NAME__/scripts/drivers/types/codex/codex-record-session.sh <team> <name>`. Both arguments are required; `<team>` is the team `<name>` belongs to (from step 1). Without them nothing is recorded and the monitor cannot deliver to this thread.
3. Use the role as the active FROM; monitor delivery is routed only to its recorded thread.
<!-- /agmsg:slot actas -->

<!-- agmsg:slot drop -->
If argument starts with "drop", run `reset.sh "$(pwd)" __AGENT_TYPE__ <name>` and clear the role's recorded Codex seat.
<!-- /agmsg:slot drop -->

<!-- agmsg:slot spawn -->
If argument starts with "spawn" (e.g. "spawn claude-code alice", "spawn codex reviewer --window"):
1. Parse `<type>` (a spawnable agent type), `<name>`, and any options (`--boot-prompt <text>`, `--project <path>`, `--team <team>`, `--window`, `--split h|v`, `--terminal <template>`, `--no-wait`, `--ready-timeout <secs>`, `--model <id>`, `--fresh`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - `spawn.sh` pre-joins `<name>`, then opens a new pane or window through the terminal driver and launches the target CLI with `$__SKILL_NAME__ actas <name>` as its initial prompt. `--boot-prompt` appends a first task to that prompt. Codex spawn uses the bundled shim and bridge. Which terminal that is is the driver's decision, never something to name here.
   - By default it blocks until a spawned Claude Code agent's watcher attaches and prints `status=ready`; `--no-wait` returns immediately. A spawned Codex agent skips the readiness wait: it has no spawn-time readiness handshake (that is separate from how it receives messages).
   - It refuses early when `<name>` is already held by another live session, the target CLI is missing, the project path is invalid, or the terminal driver has nowhere to place it.
3. Show the script's output.

If argument starts with "despawn" (e.g. "despawn reviewer", "despawn alice --force"):
1. Parse `<name>` and any options (`--force`, `--timeout <secs>`). `despawn` tears down a member previously spawned by this session.
2. Determine which team `<name>` belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/despawn.sh <team> $AGENT <name> [--force] [--timeout <secs>]`
   - The default graceful path sends a `ctrl:despawn` message so a Claude Code member's watcher drops its role and closes its spawned pane, then waits for the lock to release.
   - A Codex member has no watcher (and never holds an actas lock), so graceful teardown cannot be confirmed; use `--force` for it. `--force` skips the message, tears down the recorded pane/window, and drops the registration directly.
3. Show the script's output.
<!-- /agmsg:slot spawn -->

<!-- agmsg:slot mode -->
If argument is "delivery" (or its alias "mode") with nothing after it, run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery status --type __AGENT_TYPE__ --project "$(pwd)"`. It shows both the install-wide agmsgd state (for example "delivery: agmsgd (on) — notices are delivered directly") and this project's own delivery ("this project's fallback: monitor (legacy)"). When agmsgd is off but available, tell the user that `/agmsg delivery agmsgd` turns direct delivery on.

For `delivery agmsgd|monitor|turn|off` (and the same values after the alias `mode`), run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery <value> --type __AGENT_TYPE__ --project "$(pwd)"`; `both` is unsupported. `agmsgd` runs `daemon enable` and leaves the project on `monitor` as the fallback; the other values are exactly `delivery.sh set <value>`. `monitor` is always shown as `monitor (legacy)` on the choice screen, but its value stays `monitor`. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
