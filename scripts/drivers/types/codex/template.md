<!-- Codex overlay for the shared SKILL.md. -->

<!-- agmsg:slot shell-extra -->
On Windows PowerShell, invoke Git Bash explicitly and keep the full `bash -lc` payload inside one single-quoted string:

`& 'C:\Program Files\Git\bin\bash.exe' -lc '~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" codex'`

Do not use POSIX `'"'"'` quote splicing in PowerShell, and do not use escaped double quotes inside the wrapper.
<!-- /agmsg:slot shell-extra -->

<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Respect the existing delivery choice.** Decided 11-02, following #1810: a running agmsgd is the default; only an explicit delivery switch overrides it. Ask about delivery only on a human-initiated first join, and only when there is a real choice. Never ask on `actas`, `spawn`, or rejoin of an existing seat, even if `join.sh` must restore its registration. First run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery status --type __AGENT_TYPE__ --project "$(pwd)"`. If its `this project:` line says a mode was `chosen — agmsgd does not deliver here`, preserve that explicit choice, say "Keeping this project's explicitly chosen delivery mode; agmsgd does not deliver here", and continue without asking or running `delivery agmsgd`. Otherwise run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg daemon offer __AGENT_TYPE__`; it only reads and prints one line:
     - `agmsgd=available`: only on a human-initiated first join, ask the user to pick one, in this order:
       1. `agmsgd` — notices delivered directly by a background service (recommended). Choosing it registers a background service that starts at login; `agmsg daemon disable` stops and removes it. Empty input means this one.
       2. `monitor (legacy)` — the Codex app-server bridge streams the inbox (the `monitor` mode value). It changes how `codex` starts and is documented in `docs/codex-monitor-beta.md`.
       3. `turn`, 4. `off` — as before.
     - `agmsgd=on`: ask nothing. Run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery agmsgd --type __AGENT_TYPE__ --project "$(pwd)"`. Only if it succeeds, say "agmsgd is on: notices are delivered directly", and continue. On failure, report the failure and continue without a delivery question or a claim that notices are delivered.
     - `agmsgd=not-running reason=...`: agmsgd is turned on but is not running, so do not say notices are delivered directly. Say so with the reason; only on a human-initiated first join, ask whether to start it (`agmsg delivery agmsgd` starts it) or switch to `monitor (legacy)`.
     - `agmsgd=unavailable reason=...`: do not offer agmsgd; say the reason in one line; only on a human-initiated first join, ask for `monitor (legacy)`, `turn`, or `off` (empty input means `monitor`).

     Outside a human-initiated first join, if the offer is not `agmsgd=on`, preserve the configured delivery and continue without asking or changing it. Report a stopped or unavailable service with its reason; do not claim delivery is active. An explicit `delivery <value>` request still applies the requested value directly.

     To apply the choice, run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery <choice> --type __AGENT_TYPE__ --project "$(pwd)"` with `<choice>` = `agmsgd`, `monitor`, `turn` or `off` (`monitor (legacy)` is the value `monitor`) and show its output:
     - `agmsgd` turns the background service on (`daemon enable`) and records the choice; the project then receives through agmsgd only, with no Monitor fallback, and a stopped agmsgd is reported with how to restart it. If it fails, report the failure; offer the other choices only on a human-initiated first join, otherwise preserve the existing configuration and continue without a delivery question.
     - After the user chooses to start a stopped agmsgd: run `agmsg delivery agmsgd` the same way; it also records that this project uses agmsgd.
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
If argument is "delivery" (or its alias "mode") with nothing after it, run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery status --type __AGENT_TYPE__ --project "$(pwd)"`. It shows both the install-wide agmsgd state (for example "delivery: agmsgd (on) — notices are delivered directly") and this project's own delivery (for example "this project: agmsgd"). When agmsgd is off but available, tell the user that `/agmsg delivery agmsgd` turns direct delivery on.

For `delivery agmsgd|monitor|turn|off` (and the same values after the alias `mode`), run `~/.agents/skills/__SKILL_NAME__/scripts/agmsg delivery <value> --type __AGENT_TYPE__ --project "$(pwd)"`; `both` is unsupported. `agmsgd` runs `daemon enable` and records the choice (no Monitor fallback); the other values are exactly `delivery.sh set <value>`. `monitor` is always shown as `monitor (legacy)` on the choice screen, but its value stays `monitor`. Legacy `hook on` maps to `turn`; `hook off` maps to `off`.
<!-- /agmsg:slot mode -->
