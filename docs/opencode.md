# agmsg for OpenCode

OpenCode is supported for **manual and turn/off delivery workflows**.

`monitor` and `both` are not supported in this release (real-time push delivery requires a Monitor-tool equivalent that OpenCode does not have built in). `spawn opencode` is supported via `opencode --prompt`. OpenCode + Ollama is a useful local coding agent that can participate in an agmsg team alongside Claude Code, Codex, Gemini CLI, and other CLI agents.

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

On first run it prompts for a team name and agent name, then joins you to the team. Choose delivery mode `turn` or `off` when prompted.

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
| `turn`    | ✓         | Instruction rule runs check-inbox after each tool call |
| `off`     | ✓         | Manual `$agmsg` only |
| `monitor` | ✗         | Requires Monitor tool — not available in OpenCode |
| `both`    | ✗         | Requires monitor |

Switch mode:

```
$agmsg mode turn
$agmsg mode off
```

Requesting `monitor` or `both` returns an error:

```
Error: 'monitor' mode is not supported for opencode (no Monitor-tool equivalent). Use 'turn' or 'off'.
```

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

- No real-time push delivery (`monitor` mode requires a Monitor-tool equivalent, not available in OpenCode itself)
- No native OpenCode plugin integration

These may be addressed in future releases.
