# agmsg for Pi

Pi ([earendil-works/pi](https://github.com/earendil-works/pi)) supports **turn, monitor, and off** delivery through a project-local extension. `both` is not supported. `spawn pi` launches the `pi` CLI.

Pi's session store takes a SQLite writer lease, so an external process cannot inject into the live TUI (`pi --print` from a watcher would contend for that lease). Incoming messages are delivered **in-process**: `delivery.sh` writes `.pi/extensions/agmsg.ts`, which either checks the inbox when the agent settles (`turn`) or polls unread messages on a ~15s timer (`monitor`) and injects them with `pi.sendMessage({ triggerTurn: true, deliverAs: "steer" })`.

## Install

**Alongside Codex (typical setup):**

```bash
bash <(curl -fsSL https://agmsg.cc/install.sh)
```

When `~/.pi/` already exists, the installer automatically places a Pi-typed
`SKILL.md` at `~/.pi/agent/skills/agmsg/SKILL.md` without touching the shared
`~/.agents/skills/agmsg/SKILL.md` (which stays Codex-typed). This is the
recommended approach for mixed Codex + Pi teams.

**Pi-only (no Codex):**

```bash
bash <(curl -fsSL https://agmsg.cc/install.sh) --agent-type pi
```

`--agent-type pi` overwrites the shared `~/.agents/skills/agmsg/SKILL.md` with
the Pi template. Use this only when Codex is **not** installed; it will break
Codex identification if both agents share the same `~/.agents/` path.

From a local clone, substitute `bash <(curl ...)` with `./install.sh`.

Pi skill search order (later locations win on name collision):

1. `.pi/skills/` — project-local
2. `~/.pi/agent/skills/<name>/SKILL.md` — global Pi skills ← installed here
3. `~/.agents/skills/<name>/SKILL.md` — agent-compatible fallback (Codex-typed)

## Join a team

From Pi, run:

```
/agmsg
```

On first run it prompts for a team name and agent name, then joins you to the
team. Choose delivery mode `turn`, `monitor`, or `off` when prompted. Then
`/reload` (or restart Pi) so the project extension is picked up.

Or join directly from the shell:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> pi "$(pwd)"
~/.agents/skills/agmsg/scripts/delivery.sh set turn pi "$(pwd)"
```

## Delivery modes

| mode | mechanism |
|---|---|
| **`turn`** (default) | Extension runs `inbox.sh` on `agent_settled` |
| **`monitor`** | Extension polls unread messages every 15s and injects them into the session |
| **`off`** | The extension file is removed; manual `/agmsg` only |

`delivery.sh set` writes or removes `<project>/.pi/extensions/agmsg.ts`. Project-local Pi extensions load only after the project is trusted.

Do **not** start `watch.sh` for Pi. That path is for runtimes with a Monitor tool; Pi injects from inside the session instead.

The extension also registers `agmsg_send` and `agmsg_inbox` tools so the model can send and check mail without going through the skill command.

## Common actions

```
/agmsg                          — check inbox
/agmsg send <agent> <message>   — send a message
/agmsg team                     — list team members
/agmsg mode turn|monitor|off    — switch delivery mode (then /reload)
```
