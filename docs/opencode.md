# agmsg for OpenCode

OpenCode supports **manual, turn/off, and real-time `monitor` delivery**.

`monitor` mode routes incoming messages through the external [`opencode-sentinel`](https://github.com/tsukimiya/opencode-sentinel) plugin (a Monitor-tool equivalent for OpenCode), with a turn-mode fallback when the plugin is not installed. `spawn opencode` is supported via `opencode --prompt` (TUI mode). `both` is not supported. OpenCode + Ollama is a useful local coding agent that can participate in an agmsg team alongside Claude Code, Codex, Gemini CLI, and other CLI agents.

## Install

**Alongside Codex (typical setup):**

```bash
bash <(curl -fsSL https://agmsg.cc/install.sh)
```

When `~/.config/opencode/` already exists, the installer automatically places
an OpenCode-typed `SKILL.md` at `~/.config/opencode/skills/agmsg/SKILL.md`
without touching the shared `~/.agents/skills/agmsg/SKILL.md` (which stays
Codex-typed). This is the recommended approach for mixed Codex + OpenCode teams.

**OpenCode-only (no Codex):**

```bash
bash <(curl -fsSL https://agmsg.cc/install.sh) --agent-type opencode
```

`--agent-type opencode` overwrites the shared `~/.agents/skills/agmsg/SKILL.md`
with the OpenCode template. Use this only when Codex is **not** installed; it
will break Codex identification if both agents share the same `~/.agents/` path.

From a local clone, substitute `bash <(curl ...)` with `./install.sh`.

The installer places an OpenCode-typed `SKILL.md` at
`~/.config/opencode/skills/agmsg/SKILL.md`. This is the global skill path
OpenCode reads and takes priority over the shared
`~/.agents/skills/agmsg/SKILL.md` (which is Codex-typed). Without this,
OpenCode would pick up the Codex template and identify itself as `codex`.

OpenCode skill search order (first match wins):
1. `.opencode/skills/<name>/SKILL.md` — project-local
2. `~/.config/opencode/skills/<name>/SKILL.md` — global config ← installed here
3. `~/.claude/skills/<name>/SKILL.md` — Claude-compatible fallback
4. `~/.agents/skills/<name>/SKILL.md` — agent-compatible fallback (Codex-typed)

## Join a team

From OpenCode, run:

```
$agmsg
```

On first run it prompts for a team name and agent name, then joins you to the team. Choose delivery mode `monitor`, `turn`, or `off` when prompted (`monitor` requires the `opencode-sentinel` plugin — see [Delivery modes](#delivery-modes) below).

Or join directly from the shell:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> opencode "$(pwd)"
~/.agents/skills/agmsg/scripts/delivery.sh set turn opencode "$(pwd)"
```

## Common actions

Check inbox:

```
$agmsg
```

Send a message:

```
$agmsg send claude check this draft
```

Show team members:

```
$agmsg team
```

Show message history:

```
$agmsg history
```

## Delivery modes

| Mode      | Supported | Notes |
|-----------|:---------:|-------|
| `monitor` | ✓         | Real-time push via the [`opencode-sentinel`](https://github.com/tsukimiya/opencode-sentinel) plugin's `sentinel_monitor` tool — same shape as Claude Code's Monitor. Falls back to turn-mode self-checks when the tool is unavailable |
| `turn`    | ✓         | Instruction rule runs check-inbox after each tool call |
| `off`     | ✓         | Manual `$agmsg` only |
| `both`    | ✗         | Not applicable to opencode (the sentinel tool already provides the real-time path, with turn as its in-band fallback) |

Switch mode:

```
$agmsg mode monitor    # real-time push (requires opencode-sentinel plugin)
$agmsg mode turn
$agmsg mode off
```

### Real-time push (`monitor` mode)

`monitor` mode streams incoming agmsg messages into the OpenCode session as
they arrive, using the [`opencode-sentinel`](https://github.com/tsukimiya/opencode-sentinel)
plugin's `sentinel_monitor` tool — the same shape as Claude Code's Monitor
tool. Install the plugin first:

```
opencode plugin opencode-sentinel
```

Then set the mode and follow the rule's instruction to launch a resident
watcher via `sentinel_monitor`:

```
$agmsg mode monitor
```

If `sentinel_monitor` is unavailable (plugin not installed, or the OpenCode
build does not expose the tool), the rule falls back to turn-mode self-checks
— so `monitor` never silently drops messages, it just degrades to `turn`.

## Spawn

`spawn opencode` is supported via the existing `prompt_arg=` mechanism. The
manifest declares `cli=opencode` + `prompt_arg=--prompt`, so `spawn.sh` emits
`opencode --model <id> --prompt "<actas text>"`.

TUI mode (`opencode --prompt`, not `opencode run --interactive`) is required:
`run --interactive` exits as soon as the boot prompt's turn completes, so the
spawned worker would never stay resident to receive further agmsg messages.
`--prompt` auto-sends the initial prompt and keeps the TUI open.

See the main spawn documentation in [README.md](../README.md#spawn-a-new-agent-spawn).

## Typical team setup

```text
tmux
├─ Claude Code        Main implementation — monitor mode
├─ Codex              Review / design checks — turn mode
├─ OpenCode + Ollama  Local tasks (research, drafts, tests) — turn mode
└─ agmsg SQLite       Shared message store
```

OpenCode + Ollama is well-suited for local, low-cost tasks such as:
- Research and investigation
- README updates
- Drafting small test cases
- Mechanical edits

## Known limitations

- `monitor` mode depends on the external `opencode-sentinel` plugin — without it, delivery degrades to `turn` rather than failing
- No native OpenCode plugin integration

These may be addressed in future releases.
