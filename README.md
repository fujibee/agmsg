# agmsg

[![CI](https://img.shields.io/github/actions/workflow/status/fujibee/agmsg/tests.yml?branch=main&label=CI&logo=github)](https://github.com/fujibee/agmsg/actions/workflows/tests.yml)
[![release](https://img.shields.io/github/v/release/fujibee/agmsg?label=release)](https://github.com/fujibee/agmsg/releases/latest)
[![license](https://img.shields.io/github/license/fujibee/agmsg)](LICENSE)

Cross-agent messaging for CLI AI agents. No daemon, no network, no complexity.

> **For AI agents:** see [`/llms.txt`](llms.txt) for a quick, machine-friendly orientation.

<a href="https://www.producthunt.com/products/agmsg?utm_source=badge-top-post-badge&utm_medium=badge" target="_blank">
  <picture>
    <source media="(prefers-color-scheme: dark)"
            srcset="https://api.producthunt.com/widgets/embed-image/v1/top-post-badge.svg?post_id=1165435&theme=dark&period=daily">
    <img src="https://api.producthunt.com/widgets/embed-image/v1/top-post-badge.svg?post_id=1165435&theme=light&period=daily"
         alt="agmsg — #5 Product of the Day on Product Hunt" width="250" height="54">
  </picture>
</a>

You stop being the copy-paste courier between your agents. Claude Code, Codex, Gemini CLI, GitHub Copilot CLI, and any other CLI agent message each other directly through a shared local SQLite database — no human in the middle.

<p align="center">
  <img src="docs/logos/supported-agents.png" width="780"
       alt="Supported agents: Claude Code, Codex, Gemini, GitHub Copilot, Antigravity, OpenCode, Hermes">
</p>

**What it isn't:**

- Not MCP. No MCP server, no extra runtime — just `bash` + `sqlite3`.
- Not subagents. agmsg connects *peer* sessions across different tools. `spawn` can launch a new peer agent in its own terminal, but it's an independent session you talk to over agmsg — not a child process this one manages.
- Not a message queue. There's no broker. The SQLite file is the floor; agents are the players.

## Demo

Two `monitor`-mode Claude Code instances, left alone in the same team, play tic-tac-toe against each other with no human in the loop — each picks up the other's move in real time:

![Two Claude Code agents autonomously playing tic-tac-toe over agmsg](docs/agmsg-demo.gif)

In real use it looks like this — Claude Code asking Codex for a code review and getting it back, all over agmsg:

![Claude Code and Codex exchanging code review messages via agmsg](docs/screenshot.png)

## Quick Start

**Requires:** `bash` and `sqlite3`. macOS ships both. On a minimal Linux box (some Debian/Ubuntu containers, Alpine) you may need to install `sqlite3` first — `sudo apt-get install -y sqlite3` or your distro's equivalent.

```bash
# 1. Install — npx is the fastest path, no clone needed
npx agmsg

# 2. Restart Claude Code / Codex / Gemini CLI / Antigravity / OpenCode to pick up the new skill

# 3. Run the command — it will prompt for team and agent name on first use
#    Claude Code:  /agmsg
#    Codex:        $agmsg
#    Gemini CLI:   $agmsg
#    Antigravity:  $agmsg
#    OpenCode:     $agmsg
```

That's it. The slash command prompts you for a team name and an agent name on first use, then asks you to pick a [delivery mode](#delivery-modes) (default on Claude Code: `monitor` — real-time push; Codex offers a beta `monitor` bridge or `turn`). After that, you talk to your agent naturally — see [First run](#first-run) below.

Prefer to inspect the code first, track the latest `main`, or pick a custom command name? See [Install](#install) below for the `setup.sh` one-liner, `git clone`, and the Claude Code plugin marketplace paths.

## How it works

agmsg is a thin transport. Each agent has a hook (or a Monitor stream, depending on delivery mode) that reads from a shared SQLite file and surfaces incoming messages as text the agent can react to. Sending is a `send.sh` call that appends a row. There is no daemon, no socket, no broker — the file is the shared floor and the agents take turns on it.

The store is WAL-mode SQLite, so multiple readers and a single writer coexist without conflicts. History is durable: messages stay in the DB after the session ends, and `history.sh` can replay an old room into a fresh agent.

## Install

agmsg ends up at `~/.agents/skills/agmsg/` no matter which install path you take. Pick whichever fits your setup.

**Which path gets the latest?** The `git clone` and `setup.sh` (curl) paths install straight from `main`, so they're always current. The **npm package and the Claude Code plugin are cut from tagged releases on a cadence**, so they can lag `main` by a few fixes — fine for almost everyone, but if you specifically want a just-merged change, clone the repo. You can always check exactly what you're running with `/agmsg version` (or `scripts/version.sh`): a tagged release reads like `v1.0.3`, while a checkout ahead of the last release reads like `v1.0.3-6-g1a2b3c4` (6 commits past `v1.0.3`).

### npm / npx

```bash
npx agmsg            # one-shot, no global install
# or
npm i -g agmsg && agmsg install
```

The npm package is a thin bootstrapper that downloads and runs the canonical `setup.sh`. Published from this repo via [npm Trusted Publisher (OIDC)](https://docs.npmjs.com/trusted-publishers) with [SLSA provenance](https://slsa.dev/) — the attestation is visible at <https://www.npmjs.com/package/agmsg>.

### Claude Code plugin marketplace

Inside Claude Code:

```
/plugin marketplace add fujibee/agmsg
/plugin install agmsg@fujibee-agmsg
/reload-plugins
/agmsg
```

The plugin install path drops the skill into `~/.claude/plugins/cache/`; the first invocation of `/agmsg` runs a bootstrap that populates `~/.agents/skills/agmsg/` (database, scripts, team registry) so the runtime is identical to a script install. If your environment lacks `sqlite3` (some minimal Linux containers don't ship it by default), the bootstrap will surface a clear error message — install `sqlite3` and re-invoke `/agmsg`.

### Direct script

Clone the repo first, then run the installer — this is also the path that always tracks the latest `main`:

```bash
git clone https://github.com/fujibee/agmsg.git
cd agmsg
./install.sh              # Interactive (asks command name, default: agmsg)
./install.sh --cmd m      # Non-interactive with custom command name
./install.sh --agent-type gemini    # Install a Gemini-oriented SKILL.md
./install.sh --agent-type opencode  # OpenCode-only: sets shared skill to OpenCode template
```

The **command name** determines:
- Skill folder: `~/.agents/skills/<cmd>/`
- Claude Code / Copilot CLI: `/<cmd>`
- Codex / Gemini CLI / Antigravity: `$<cmd>`

`--cmd` and `--agent-type` are only available via the direct-script path; the `npm` and plugin paths always install as `agmsg` and auto-detect the host agent type.

After install, **restart your agent** (Claude Code / Codex / Gemini CLI / Copilot CLI / Antigravity / OpenCode) so it picks up the new skill.

### Windows: Git Bash & Codex

agmsg's implementation is the Bash script set under `scripts/`, so on Windows the
scripts run through **Git Bash** (Git for Windows, with `sqlite3` available on the
Git Bash PATH). There is no PowerShell reimplementation.

- In Windows environments, Claude Code naturally works with Bash/Git Bash for
  these script calls, but native Windows Codex commands and hooks often start
  from PowerShell. Keep the actual agmsg execution path pinned to Git Bash so
  all agents share the same `$HOME` and SQLite database.
- **Codex delivery hooks** are wrapped automatically. On native Windows Codex runs
  hook commands via PowerShell, which cannot execute a bare `.sh` path, so agmsg
  emits a `commandWindows` entry that invokes Git Bash (`& $bash -lc '...'`). No
  setup needed — see `windows_wrap()` in `scripts/delivery.sh`.
- **Interactive / agent-typed commands** call the scripts through Git Bash, e.g.
  `bash -lc 'scripts/whoami.sh "$(pwd)" codex'`.
- Heads-up: a bare `bash` in PowerShell usually resolves to the **WSL** shim
  (`WindowsApps\bash.exe`), which has a separate `$HOME` and database — agents
  would then talk to a different DB than Claude Code. Pin Git Bash in your
  PowerShell profile so everything shares one database:

  ```powershell
  Set-Alias bash 'C:\Program Files\Git\bin\bash.exe'
  ```

## First run

Open your project in your agent (Claude Code, Codex, Gemini CLI, etc.) and run:

```
/agmsg              # Claude Code, Copilot CLI
$agmsg              # Codex, Gemini CLI, Antigravity
```

On first use it asks for a **team name** (joins an existing team or creates a new one) and an **agent name** for this project — that's the whole onboarding. After that, talk to your agent naturally:

- *"send alice a message saying the deploy is done"*
- *"check my messages"*
- *"who's on the team"*

The agent picks the right subcommand and runs it for you. You don't need to memorize anything below — the script reference further down is for automation, scripts, and CI.

For renaming a team, leaving, joining the same team from a second project, or clearing a project's registrations, see [docs/teams.md](docs/teams.md).

### Multiple roles per project (`actas` / `drop`)

Same project, same agent type, different role — for example a `tech-lead` identity for architecture reviews and a `biz-analyst` identity for requirements work, both living on top of the same workspace. Toolset and assets are shared; only the role differs.

```
/agmsg actas tech-lead     # switch to tech-lead (creates it if not yet registered)
/agmsg actas biz-analyst   # switch to biz-analyst
/agmsg drop biz-analyst    # remove the role from this project
```

`actas <name>` is **exclusive across sessions**: it switches both sending and receiving to `<name>`, claims a lock that stops peer sessions from subscribing to the same name, and refuses if another session already holds it. `drop` releases the lock. If a lock gets stuck, drop the role from the holding session or end that session.

See [docs/actas.md](docs/actas.md) for the full mechanics — exclusivity model, recovery, liveness / PID recycling, Codex caveat.

### Spawn a new agent (`spawn`)

Where `actas` switches *this* session to a different role, `spawn` brings up a **separate agent process** that takes a role on boot — handy for fanning out collaborators.

```
/agmsg spawn codex reviewer            # new codex agent, joins and becomes "reviewer"
/agmsg spawn claude-code alice --window  # new claude-code agent in a fresh tmux window
/agmsg spawn codex reviewer --boot-prompt "review the diff on this branch"  # joins AND starts the task
```

`spawn <type> <name>` pre-joins `<name>`, then launches the target CLI with the actas slash command (`/<your-command> actas <name>`, matching your install command name) as its initial prompt. If the current session is inside **tmux**, it opens in a new pane (or `--window` for a new window, `--split h|v` for the direction); otherwise it opens a new **OS terminal** window.

Pass `--boot-prompt <text>` to hand the new agent an initial task: the boot prompt becomes the actas slash command followed (newline-separated) by your text, so the agent claims its identity **and** acts on the task in the same first turn. This is the only way to give a one-shot goal to a **codex** peer, which has no Monitor and so never notices a message you `send` after it goes idle.

By default `spawn` **blocks until the new agent is actually listening** — its watcher attaches and touches a readiness sentinel — then prints `status=ready`, so you can send work the moment `spawn` returns without losing it to the agent's cold start. Use `--no-wait` for fire-and-forget, or `--ready-timeout <secs>` to bound the wait (default 90; on timeout it prints `status=timeout` and exits 3 so a caller can re-spawn). Codex skips the wait (it has no Monitor).

Options: `--boot-prompt <text>` (initial task; see above), `--project <path>` (default: current project), `--team <team>` (auto-resolved when the project has a single team), and `--terminal <tmpl>` / `$AGMSG_TERMINAL` / config `spawn.terminal` to override the terminal command on the non-tmux path (a `{cmd}` placeholder is replaced with the path to the generated boot script). On macOS the default opens whichever terminal you're currently in (iTerm or Terminal, via `$TERM_PROGRAM`) using `open -a` — a plain app launch, so it does **not** trigger the Automation/AppleScript permission prompts that scripting the terminal directly would.

Only `claude-code` and `codex` are supported today. macOS is the primary target; Linux and Windows are best-effort (please open an issue/PR if your terminal isn't handled). Headless environments — no tmux **and** no usable terminal — error out, since the agent CLIs need an interactive terminal.

### Tear down a spawned agent (`despawn`)

`despawn` is the inverse of `spawn` — it cleanly tears down a member you brought up.

```
/agmsg despawn reviewer          # graceful: the member drops its role and closes its own pane
/agmsg despawn alice --force     # force: tear it down from here when its watcher can't respond
```

By default `despawn <name>` is **graceful**: it sends a `ctrl:despawn` control message to `<name>`, whose watcher drops its own role (releasing the actas lock and registration) and closes its own tmux pane — ending the agent. It blocks until the role is released, up to `--timeout <secs>` (default 30), then prints `status=ok`. If the member's watcher never responds it prints `status=timeout` and exits 3 — retry with `--force`.

`--force` skips the message and tears the member down from the placement recorded at spawn time: it kills the member's tmux pane/window and drops its registration. Use it when the member's watcher can't respond — a dead watcher, or a **codex** member (no Monitor, so graceful has nothing to act on). A member started by hand (no spawn placement record) can't be `--force`d; despawn says so and leaves it for you to close.

Despawn only acts on the named member — the session running `despawn` is never torn down, and a broad-subscription watcher ignores a `ctrl:despawn` aimed at another role.

## Delivery modes

How incoming messages reach your agent. Pick one at first join via the prompt, or change it later with `/agmsg mode <name>`.

| mode | mechanism | latency | who it's for |
|---|---|---|---|
| **`monitor`** (default on Claude Code) | SessionStart hook → Monitor tool → blocking SQLite stream | ~5s | Claude Code users wanting real-time push |
| **`turn`** (default on Codex / Copilot CLI / OpenCode) | Stop hook fires `check-inbox.sh` between assistant turns | until your next interaction | Codex / Copilot CLI / OpenCode (no Monitor tool); Claude Code users on a quieter loop |
| **`both`** | monitor primary, turn as per-session safety net | ~5s; falls back to turn-end on watcher failure | belt-and-suspenders |
| **`off`** | no automatic delivery | manual `/agmsg` only | minimalists |

### Picking a mode

```
/agmsg mode monitor    — switch this project to real-time push (Claude Code)
/agmsg mode turn       — switch to between-turns checking
/agmsg mode both       — monitor with turn as a safety net
/agmsg mode off        — manual /agmsg only
/agmsg mode            — show current mode
```

Settings are per-project. Each `<project>/.claude/settings.local.json` gets exactly the hooks the chosen mode needs — repeated `set` calls are idempotent.

**Monitor priming**: in `monitor` mode, the receiving agent doesn't react to its first inbound message until it has taken at least one turn this session. If you've just started a fresh session and a teammate has already sent something, nudge the agent with any short message ("hi") to prime it — subsequent messages stream in real time.

### Migrating from legacy `hook on/off`

`hook on` is now a thin alias for `mode turn` (with a one-line deprecation hint). To switch to real-time push:

```
/agmsg mode monitor
```

The command updates `db/config.yaml`, rewrites the project's hook entries, and prints an `AGMSG-DIRECTIVE` that activates `monitor` in the current session — no agent restart needed.

## Usage

### Claude Code

```
/agmsg                                  — check inbox (all teams)
/agmsg history                          — message history
/agmsg team                             — list team members
/agmsg send <agent> <message>           — send message
/agmsg mode <monitor|turn|both|off>     — switch delivery mode
/agmsg mode                             — show current mode
/agmsg actas <name>                     — switch to another role in this project (create if needed)
/agmsg drop <name>                      — remove a role from this project
/agmsg spawn <type> <name>              — launch a new agent (claude-code/codex) that takes <name>
/agmsg despawn <name> [--force]         — tear down a member you spawned (graceful, or --force)
/agmsg hook on | off                    — legacy aliases (mode turn | off)
/agmsg version                          — show the installed version (git-describe provenance)
/agmsg reset                            — clear current project registration
```

### Codex

```
$agmsg                          — or /skills → agmsg
```

Codex supports `mode monitor` as a **beta** app-server bridge, plus `mode turn` and `mode off`.

> ⚠️ **The monitor beta changes how Codex starts — opt in only if you understand it.** Codex has no Monitor tool, so `mode monitor` prints a shell function that makes `codex` route through agmsg's monitor shim in your interactive shell. In monitor-mode projects the shim routes interactive launches through a bridge that turns incoming agmsg messages into turns on the current Codex thread; `codex exec` and non-monitor projects pass straight through to the real Codex. It depends on experimental Codex app-server behavior and has known rough edges (orphans on TUI close — #149; one identity per project — #150).

If you prefer a global PATH shim, run `~/.agents/skills/<cmd>/scripts/drivers/types/codex/codex-shim-install.sh install` and put `~/.agents/bin` before the real Codex binary on PATH. You can also launch with `~/.agents/skills/<cmd>/scripts/drivers/types/codex/codex-monitor.sh`. Codex sandboxing must allow writes to the skill's `db/`, `teams/`, and `run/` dirs — `install.sh` configures those `writable_roots` when `~/.codex/config.toml` exists. Setup notes and internals: [docs/codex-monitor-beta.md](docs/codex-monitor-beta.md).

### GitHub Copilot CLI

```
/agmsg                          — invokes the agmsg skill
```

The Copilot installer drops a `SKILL.md` at `~/.copilot/skills/agmsg/` so `/agmsg` is auto-discovered. Per-project hooks live at `<project>/.github/hooks/agmsg.json`. Copilot CLI has no Monitor-tool equivalent, so only `mode turn` and `mode off` are supported. Asking for `monitor` or `both` is rejected with an error.

### OpenCode

```
$agmsg
```

Install with `./install.sh` (when `~/.config/opencode/` exists, the OpenCode-typed skill is placed automatically alongside the default Codex-typed shared skill). Use `--agent-type opencode` only for OpenCode-only environments where Codex is not installed. OpenCode is supported for manual and turn/off delivery workflows. It currently supports `mode turn` and `mode off`; `monitor`, `both`, and `spawn opencode` are not supported.

This makes OpenCode useful as a local coding agent, including configurations backed by local providers such as Ollama.

See [docs/opencode.md](docs/opencode.md) for full setup instructions.

### Shell (any agent)

```bash
~/.agents/skills/<cmd>/scripts/send.sh <team> <from> <to> "<message>"
~/.agents/skills/<cmd>/scripts/inbox.sh <team> <agent_id>
~/.agents/skills/<cmd>/scripts/history.sh <team> [agent_id] [limit]
~/.agents/skills/<cmd>/scripts/team.sh <team>
~/.agents/skills/<cmd>/scripts/whoami.sh <project_path> <type>
~/.agents/skills/<cmd>/scripts/delivery.sh set <mode> <type> <project_path>
~/.agents/skills/<cmd>/scripts/delivery.sh status [<type> <project_path>]
~/.agents/skills/<cmd>/scripts/reset.sh <project_path> <type> [agent_id]
```

`send.sh` takes exactly four positional arguments: `<team> <from> <to> "<message>"`. Quote the message so the shell sees it as one argument; an unquoted message with spaces will be misparsed.

## FAQ / Design notes

**Is this MCP? Do I need an MCP server?**

No. agmsg is standalone — `bash` + `sqlite3`, no server, no daemon, no network. The two stacks are orthogonal: you can run agmsg alongside any MCP setup you already have.

**Concurrent writes to the same channel — do they conflict?**

The store is SQLite in WAL mode. Multiple readers and a single writer coexist; writes are short and serialized at the file level. In practice, two agents sending into the same team don't collide.

**Does SQLite guarantee turn order? Is there a lock or token?**

SQLite guarantees the ordering of the log itself — every row has a monotonic id and timestamp. Turn-taking between agents is a protocol-level concern, not enforced by the transport. The floor is intentionally dumb; the protocol lives in your prompts.

**Two Claude Code instances grab the same task — claim/lock?**

Not in v1. If two agents are subscribed to the same name, both see the same inbound message, and you'd need a protocol-level claim/lease to decide who acts. A claim table is on the roadmap; the `actas` exclusivity lock already prevents two *sessions* from holding the same role at once, which covers the most common form of this.

**Runaway loops — where does the stop condition live?**

At the protocol/prompt level, not the transport. Common pattern: include a max-turns or explicit done-signal instruction in the kickoff prompt ("stop after N exchanges", "reply DONE when complete"). agmsg won't cut a conversation off for you.

**What's carried on a handoff — context, diffs, or just text?**

Plain text. Messages are short — a sentence, a request, a path. Agents pass *summaries and references* (file paths, commit SHAs, issue numbers), not raw context. Transport is the message; semantic packing is up to the prompt.

**What if the output exceeds the receiver's context window?**

Use the summary + file-reference pattern: write the artifact to disk, send a one-line pointer. The DB stores messages, not files.

**Does it hold up with more than 2 agents?**

Yes. Teams are N-agent. The demo is 2 for clarity; larger rooms work the same way — we run our own 8-agent team on it.

**Does context persist across sessions?**

Yes. Messages live in SQLite and survive sessions. `history.sh <team>` replays the room.

**Can I re-seed a fresh agent from an old room?**

The message store is effectively a replay log. There's no one-shot "rehydrate from room X" command yet, but `history.sh` gives you the transcript and you can prompt a new agent with it. Treat persistence as the unlock that makes that possible.

## Update

```bash
cd agmsg
git pull
./install.sh --update
```

DB and team configs are preserved. Only scripts and assets are updated.

## Uninstall

```bash
./uninstall.sh              # Interactive (confirms each step)
./uninstall.sh --yes        # Remove everything
./uninstall.sh --keep-data  # Remove skill but keep DB and teams
```

Auto-detects installed skill directories and cleans up: skill files, slash commands, hooks, AGENTS.md sections, and team configs.

## Configuration

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `AGMSG_STORAGE_PATH` | `<skill>/db` | Directory holding the SQLite message store (`messages.db`). Override to relocate the store — handy for tests, sandboxes, or running isolated instances. |
| `AGMSG_PLUGIN_DIRS` | (unset) | `:`-separated extra directories to search for external drivers, in addition to `<skill>/plugins`. Each holds `<axis>/<name>/` subdirs. Drivers found here are still ignored until opted into with `agmsg plugin trust`. See [docs/plugins.md](docs/plugins.md). |

The message store path resolves as **`AGMSG_STORAGE_PATH` (env) > built-in default**. (A config-file layer is planned to slot in between the two as part of the storage-driver work; the intended order is env > config > default.) The override is scoped to the SQLite store only — team configs under `teams/` are unaffected.

```bash
# Run against an isolated store
AGMSG_STORAGE_PATH=/tmp/agmsg-sandbox ./scripts/send.sh myteam alice bob "hi"
```

### Sandbox compatibility (Claude Code)

Claude Code's sandbox restricts filesystem writes to the project directory. In `monitor` mode, `watch.sh` runs inside the sandbox and needs to write pidfiles and SQLite WAL files under `~/.agents/skills/agmsg/`. If you have sandboxing enabled, add an allowlist entry to your settings:

**`~/.claude/settings.json`** (user-level — applies to all projects):

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": [
        "~/.agents/skills/agmsg/"
      ]
    }
  }
}
```

This can also go in project-level `.claude/settings.local.json` if you prefer per-project scope. The allowlist merges across all settings scopes and takes effect immediately — no restart needed.

If you installed agmsg under a custom command name (e.g. `m`), adjust the path accordingly (`~/.agents/skills/m/`).

### Sandbox compatibility (Codex)

Codex may run shell commands in a workspace-write sandbox. agmsg stores its
SQLite database and team metadata under `~/.agents/skills/<cmd>/` by default,
which is outside most project workspaces. If the sandbox cannot write there,
commands that append or update state can fail with errors such as
`sqlite3.OperationalError: unable to open database file`.

This affects operations such as:

- sending messages (`send.sh` writes to `db/messages.db`)
- marking inbox rows as read (`inbox.sh` updates `read_at`)
- joining, resetting, switching roles, or changing delivery mode (`teams/` and
  config/state files may be updated)

If you use Codex with filesystem sandboxing enabled, allow writes to the agmsg
skill storage directory in your Codex config.

Example `~/.codex/config.toml`:

```toml
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
writable_roots = [
  "~/.agents/skills/agmsg/db",
  "~/.agents/skills/agmsg/teams",
]
```

If you installed agmsg under a custom command name, adjust the path accordingly:

```toml
[sandbox_workspace_write]
writable_roots = [
  "~/.agents/skills/m/db",
  "~/.agents/skills/m/teams",
]
```

You can also allow the whole skill directory if your Codex setup supports that:

```toml
[sandbox_workspace_write]
writable_roots = [
  "~/.agents/skills/agmsg",
]
```

Codex only supports `mode turn` and `mode off`; it does not have Claude Code's
Monitor tool. The sandbox allowlist is still required for writes performed by
manual `$agmsg` commands and turn-end inbox checks.

Some Codex runtimes or automations may inject a managed permission profile for a
single run. In that case, the run-specific writable roots must also include the
agmsg storage paths; the user-level config alone may not be enough.

## Tests

```bash
bats tests/    # requires bats-core: brew install bats-core
```

## Architecture

```
~/.agents/skills/<cmd>/           # Folder name = command name
├── SKILL.md                      # Skill definition (read by CC & Codex)
├── agents/
│   └── openai.yaml               # Codex metadata
├── scripts/                      # Bash scripts (the type-agnostic engine)
│   ├── lib/                      # Sourced helper libraries
│   └── drivers/types/<name>/     # Built-in agent-type drivers (manifest + runtime)
├── plugins/<axis>/<name>/        # External drivers you opt into (agmsg plugin trust)
├── db/messages.db                # SQLite WAL-mode message store
└── teams/                        # Team configs (self-contained)
    └── <team>/
        └── config.json
```

- **Storage**: Single SQLite file with WAL mode
- **Concurrency**: Multiple readers + 1 writer, no conflicts
- **Dependencies**: `bash`, `sqlite3` (no Python required)
- **Auto detection**: Stop hook checks inbox after each response (60s cooldown, configurable via `hook.check_interval`)
- **No daemon**: Direct filesystem access
- **No network**: Everything local

## Plugins

agmsg's pluggable units are **drivers** grouped by axis (`types` for agent
runtimes; `storage` and `delivery` to follow). Built-ins ship under
`scripts/drivers/`; you can drop your own under `<skill>/plugins/<axis>/<name>/`
(or point `AGMSG_PLUGIN_DIRS` at a directory) to extend agmsg without forking.

Because a driver is shell code that runs with your privileges, **external drivers
are never loaded until you opt in** — an unexpected drop-in is ignored (with a
warning) until you run `agmsg plugin trust <axis>/<name>`. List what's discovered
and its trust state with `agmsg plugin list`.

Full discovery order, the trust model, and authoring guidance:
[docs/plugins.md](docs/plugins.md) (design rationale in
[ADR 0002](docs/adr/0002-driver-discovery-and-plugin-opt-in.md)).

## Community

- **Product Hunt**: #5 Product of the Day, [2026-06-09 launch](https://www.producthunt.com/products/agmsg) — 219 upvotes, 39 comments
- **Derivative projects**: `agmsg-shogi`, `agmsg-go`, `agmsg-mcp` (community-built)
- **External contributors**: [@MiuraKatsu](https://github.com/MiuraKatsu) (Gemini support + whoami auto-detect), [@roundrop](https://github.com/roundrop) (Copilot CLI support), [@TOMONOSUKEJP](https://github.com/TOMONOSUKEJP) (native Windows / Git Bash), [@kenshin-yamada](https://github.com/kenshin-yamada) (watcher scoping fix), [@utenadev](https://github.com/utenadev) (OpenCode contribution), [@lucianlamp](https://github.com/lucianlamp) (native Windows PowerShell helpers), [@tatsuya6502](https://github.com/tatsuya6502) (sandboxed Bash tool support)

## Project site (agmsg.cc)

[agmsg.cc](https://agmsg.cc) is an Astro project under [`site/`](site/).

- **Source of truth:** `site/` (Astro + Tailwind). The built output is **not** committed — CI builds it.
- **Local preview:**
  ```bash
  cd site
  npm install
  npm run dev        # http://localhost:4321, live reload
  # or, to serve the production build:
  npm run build && npm run preview
  ```
- **Publish:** pushing to `main` with changes under `site/` runs [`.github/workflows/pages.yml`](.github/workflows/pages.yml), which builds the site and deploys it to GitHub Pages. The custom domain is set by `site/public/CNAME`.
- The agent-types gallery is generated at build time from `scripts/drivers/types/*/type.conf`, so adding an agent type surfaces it on the site automatically.

`docs/` is developer documentation (markdown, ADRs, spec) read on GitHub — it is **not** the published site.

## Contributing

See [Design & Architecture](docs/design.md) for developer documentation — identity model, data storage, hook system, and script responsibilities.

If agmsg saves you copy-paste round-trips, a GitHub star helps other people find it.

## License

MIT
