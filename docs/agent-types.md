# Agent types

agmsg supports several agent runtimes — claude-code, codex, gemini, antigravity,
copilot, opencode — and each is described by a small **manifest** so that the rest
of agmsg (detection, the join whitelist, spawn, and delivery routing) discovers it
from data instead of hardcoded `case` arms.

Adding a type is a **manifest + a command template**, not an edit across
`whoami.sh`, `join.sh`, `spawn.sh`, and `delivery.sh`.

## The manifest

Each type has `types/<name>/type.conf` — read-only `key=value` **data**. agmsg
reads it with a small per-key reader; it is **never `source`d**, so a manifest
cannot execute code. Multi-value keys are whitespace-separated.

| key | required | meaning |
|---|---|---|
| `name` | yes | the type name (matches the directory) |
| `template` | yes | the `/agmsg` command template in `templates/` (becomes `SKILL.md`) |
| `detect` | — | env-var names whose presence selects this type. `explicit` = never auto-detected from the environment |
| `detect_proc` | — | parent-process-name glob patterns that select this type (e.g. `codex codex-*`) |
| `cli` | spawnable types | the launch binary |
| `spawnable` | — | `yes` if `spawn.sh` can launch this type |
| `spawn` | — | a `.mjs` node-launcher (beside the manifest) `spawn.sh` runs via Node; also marks the type spawnable |
| `hooks_file` | yes | project-relative delivery hooks file (e.g. `.codex/hooks.json`) |
| `monitor` | — | `yes` if the type exposes a Monitor tool; `spawn` skips the readiness wait when `no` |

> The reader does not fail-fast: an omitted key reads as the empty string, so
> "required" above means "needed for the type to actually work", not "validated at
> load time".

### Detection

`whoami.sh` auto-detects the running type when none is passed:

1. **Environment** — the manifests' `detect=` env vars, evaluated in sorted type
   order, which preserves the precedence claude-code < codex < gemini (a runtime's
   own session vars beat the `GEMINI_*` family that users also set for the SDK).
   `detect=explicit` types are never selected here.
2. **Process tree** — walking up from the current process, the first type whose
   `detect_proc=` glob matches the ancestor's name wins.
3. Falls back to `claude-code`.

> Precedence note: env detection iterates types in **sorted name order**, so when
> two types' `detect=` vars are both present the alphabetically-earlier type wins.
> Keep `detect=` vars runtime-exclusive (a runtime's own session var, not a shared
> SDK var) so ties don't arise; this is why the `GEMINI_*` family — which users
> set without the CLI — sits behind the claude-code/codex session vars.

### Delivery

`hooks_file=` is the per-project file delivery hooks are written into. The hook
*format* (settings JSON vs. rule markdown vs. …) is still per-type code in
`delivery.sh` (`apply_settings_*`); the manifest drives the file **path** and the
allowed modes.

### Node-launcher types (external add-ons)

A type whose manifest sets a `spawn=` key to a `.mjs` file is launched by
`spawn.sh` **via Node** rather than through a `cli=` binary. agmsg core invokes the
launcher with only four **universal** flags:

```
node <type-dir>/<spawn>.mjs --name <name> --team <team> --project <path> --initial-input <text>
```

All type-specific configuration (which binary, which model, which transport, env
vars) is the launcher's **own default / environment** — agmsg core never names any
add-on. This is what lets a node-launcher type ship entirely outside the agmsg tree
(under `${AGMSG_HOME:-$HOME/.config/agmsg}/types`) with no built-in edits.

## Adding a type

1. Create `types/<name>/type.conf` with at least `name`, `template`, and
   `hooks_file` (add `detect`/`detect_proc` for auto-detection, and `cli` +
   `spawnable=yes` if `spawn.sh` should launch it).
2. Add the command template `templates/cmd.<name>.md`.
3. If the type needs a delivery hook format that doesn't exist yet, add an
   `apply_settings_<name>` path in `delivery.sh`. Reusing an existing format needs
   no code.

That's it — `whoami.sh`, `join.sh`, and `spawn.sh` pick the type up from the
registry with no further edits.

## Worked example

The six built-in manifests under `types/` are the reference. For instance
`types/codex/type.conf`:

```
name=codex
template=cmd.codex.md
cli=codex
spawnable=yes
detect=CODEX_SANDBOX CODEX_THREAD_ID
detect_proc=codex codex-*
hooks_file=.codex/hooks.json
monitor=no
```
