# Design: align agmsg with the `skills` CLI ecosystem (#201-A)

Status: draft · Target: 1.1.2 (direction A only; direction B deferred to 1.2.0)
Issue: #201

## Goal

Make agmsg installable through the `vercel-labs/skills` CLI:

```bash
npx skills add fujibee/agmsg -a <agent>     # -a is optional (auto-detects when omitted)
```

so agmsg reaches the 70+ agents that CLI targets with one command, **without** giving up
agmsg's shared-runtime + shared-SQLite model.

Direction B (reworking agmsg's *own* installer to mirror the skills conventions —
multi-`-a`, project/global scopes, per-agent path map) is **out of scope here** (1.2.0).

## Background: how agmsg installs today

agmsg is more than an instruction file. Its installer (`install.sh` / `npx agmsg install`)
produces two layers:

1. **One shared runtime + state** at `~/.agents/skills/agmsg/` — scripts + the shared
   SQLite DB. Every agent on the machine shares this one store. The `SKILL.md` here defaults
   to the codex-typed template.
2. **Per-agent discovery files, auto-detected** — for each agent present on the machine it
   drops that agent's correctly-typed instruction file in that agent's own location, e.g.
   `~/.claude/commands/agmsg.md`, `~/.copilot/skills/agmsg/SKILL.md`,
   `~/.config/opencode/skills/agmsg/SKILL.md`, `~/.hermes/...`, `~/.grok/...`.

`--agent-type` only selects the **flavor of the single shared `~/.agents/skills` SKILL.md**.
It is required only for agents that read that shared file and have no dedicated dir of their
own — **gemini, antigravity, cursor**. Agents with their own dir (claude-code, codex, copilot,
opencode, hermes, grok-build) are auto-detected and get their own correctly-typed copy, so no
flag is needed for them.

## The `skills` CLI contract (what it does / does not do)

Verified by reading `vercel-labs/skills` `src/`:

- **Pure file-dropper.** `add` clones the source repo to a temp dir, discovers skills, and
  **copies files** into each target agent's path. There is **no postinstall / setup / script
  execution** of skill content — the CLI never runs anything inside the skill. A skill *can*
  ship runnable scripts (they are copied verbatim), but the CLI will not execute them; only the
  AI agent might, at use-time.
- **A skill = a directory containing `SKILL.md`** with YAML frontmatter; `name` and
  `description` are required. No bespoke manifest is required. Convention: put
  `skills/<name>/SKILL.md` at the repo root. The CLI also honors a Claude-Code
  `.claude-plugin/plugin.json` `skills[]` list (agmsg already ships that file) to aid discovery.
- **Per-agent path registry.** Each agent has a project path and a global path. Many agents
  share the universal project dir `.agents/skills`; the **global canonical** dir is
  `~/.agents/skills/<name>`.
- **`-a/--agent` is optional and multi-valued.** Omitted → auto-detect installed agents (and,
  when run inside an AI agent, auto-select detected + universal agents). `-a '*'` → all agents.
  Scope: `-g/--global`, default project.

## Design decisions

### D1. The skills CLI is a *front door*, not the runtime installer

Because the CLI only drops files, it **cannot bootstrap agmsg's runtime/DB**. So:

- The skills CLI delivers the **instruction file (`SKILL.md`)** into each agent.
- The **shared runtime + DB** is still set up by agmsg's own bootstrap (the canonical bash
  installer / `npx agmsg install`), triggered as a documented first-run step from the
  `SKILL.md` body.
- `install.sh` (curl|bash, **zero Node dependency**) **stays a first-class path** and is not
  deprecated. The skills-CLI path is **additive** — it adds reach for users already in the
  Node/skills ecosystem; nobody is forced onto Node.

Three install front doors after this lands (documented side by side):

| path | Node? | reach |
|---|---|---|
| `install.sh` (curl\|bash) | no | manual |
| `npx agmsg install` | yes | npm users |
| `npx skills add fujibee/agmsg` | yes | one command across 70+ agents |

### D2. Identify the agent type by **install path**, not ambient detection

agmsg's `detect_cli_type` (env-var signals, then a process-tree walk, then a `claude-code`
default) is **not reliable enough to be the basis of a universal SKILL.md**:

- Three types are `detect=explicit` with **no ambient signal at all** — antigravity, copilot,
  hermes. They are undetectable by design and would mis-fall-back to `claude-code`.
- cursor / opencode are process-tree-only (fragile; nested/spawn ambiguity, `ps comm`
  truncation).
- agmsg's signature multi-agent/spawn case shares env + process tree between parent and child,
  so an agent spawned by another mis-detects as the parent.

A real-world example of exactly this: a Grok "composer" session mis-identified itself as Cursor
(no `GROK_SESSION_ID` exported and a `cursor-agent` ancestor in the tree), then refused a
monitor it should have supported.

**The skills CLI gives a reliable signal for free: the install *path* encodes the agent.**
`-a cursor` lands the file in `~/.cursor/skills/`, `-a copilot` in `~/.copilot/skills/`,
`-a claude-code` in `~/.claude/...`, etc. So the delivered `SKILL.md` should derive its type
from **where it sits**, not from ambient env. The only ambiguous location is the shared
`.agents/skills/` universal dir; there, fall back to a one-time confirm at join. The type is
**persisted at join** (the registry records it), so detection is a first-contact concern only.

Consequence: **#142 (the non-hermetic auto-detect test) is solvable but is *not* a blocker for
#201** — the design does not depend on perfect ambient detection.

### D3. SKILL.md: one common core + per-type fragments, composed at **build time**

Today there are **nine per-type templates** (`scripts/drivers/types/<type>/template.md`) that
are ~80% identical and have already **drifted** (claude-code 211 lines vs ~136 for the rest).
The only real differences are:

1. cosmetic: the invocation prefix (`/cmd` for Claude vs `$cmd` for Codex/Gemini) and the type
   token passed to `whoami.sh` / `join.sh`;
2. behavioral: the **delivery (receive) section** — Claude uses the Monitor tool (real-time
   push); Codex uses a Stop-hook turn pull (with an experimental bridge); gemini / grok-build /
   opencode use a rule-file self-poll. This differs because agents have different hook/tool
   capabilities. (Grok specifically: `monitor=no`, `delivery_modes=turn off`, rule file
   `.grok/rules/agmsg.md`, because Grok's passive hooks have stdout ignored.)

**Refactor** to:

```
scripts/drivers/types/
  _common/template.md            # the shared ~80% (placeholders: __PREFIX__, __TYPE__, __DELIVERY__)
  <type>/type.conf
  <type>/delivery.fragment.md     # just this type's delivery section
```

The installer composes `_common` + `<type>/delivery.fragment.md` and substitutes
`__PREFIX__` / `__TYPE__` / `__SKILL_NAME__` into a **single self-contained `SKILL.md`**.

Why build-time composition (not a runtime `include` / "see other file"): **agents do not
reliably follow file references** — a separate delivery doc would be skipped by some agents.
The shipped file must be self-contained. Build-time composition keeps one source of truth
(kills the nine-way drift; a new type = `type.conf` + a small fragment, the core untouched)
while still emitting a self-contained output.

The **same fragment machinery** generates a committed `skills/agmsg/SKILL.md` (the universal
variant) for the skills-CLI path, since that path is a pure copy with no per-machine build —
its `__DELIVERY__` is written to be self-contained and to resolve the type from install path
(D2), never referencing an external file.

### D4. Path collision (open decision)

The skills CLI's global canonical dir `~/.agents/skills/<name>` collides with agmsg's global
runtime root `~/.agents/skills/agmsg/`. Two ways to resolve:

- **Option X (recommended):** move agmsg's runtime root off `~/.agents/skills/` (e.g.
  `~/.local/share/agmsg/` or `~/.config/agmsg/`), pairing with #60 (separate config/state from
  the skills dir). Cleaner long-term; larger; #60 is its own axis.
- **Option Y:** keep the runtime root but ensure the skill payload and the runtime cohabit /
  do not clobber (name/dir scoping). Smaller; risks awkward naming.

This is the one decision still open before T5.

### D5. Delivery-hook registration stays per-project

`delivery.sh set <mode>` remains the per-project step that wires SessionStart/Stop or the
rule file. The skills CLI does not register hooks. Documented as the post-add step.

## Implementation tasks (delegated to ccs; co1 static-reviews)

- **T3** — Refactor the nine per-type templates into `_common/template.md` + per-type
  `delivery.fragment.md`; update the installer to compose them. Generate and commit the
  universal `skills/agmsg/SKILL.md`. Register it in `.claude-plugin/plugin.json` `skills[]`.
- **T4** — First-run runtime bootstrap: the delivered `SKILL.md` triggers the canonical
  installer/DB setup once; reconcile with the existing bootstrap entry points.
- **T5** — Resolve the path collision per D4 (depends on the X/Y decision; the runtime-root
  move, if chosen, is designed together with #60).
- **T6** — Scratch validation: `npx skills add fujibee/agmsg -a claude-code` (+ cursor, codex):
  verify file placement, runtime bootstrap, and a send/inbox round-trip.
- **T7** — Docs: add the `npx skills add` path alongside `install.sh` / `npx agmsg install`;
  document `delivery.sh set` as the per-project follow-up; keep `install.sh` framed as the
  zero-dependency first-class path.

Dependency order: T3 → T4 → (T5) → T6 → T7. T3 also unblocks the universal SKILL.md.

## Open decisions

1. **D4 path collision: Option X (move runtime root, with #60) vs Option Y (scope to avoid
   clobber).** Blocks T5.
2. Release timing: land in 1.1.2 with the storage axis, or sequence separately.
