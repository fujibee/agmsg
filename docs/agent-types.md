# Agent types

agmsg supports several agent runtimes — claude-code, codex, gemini, antigravity,
copilot, opencode, hermes, cursor — and each is described by a small **manifest** so that the rest
of agmsg (detection, the join whitelist, spawn, and delivery routing) discovers it
from data instead of hardcoded `case` arms.

Adding a type is a **manifest + a command template** (plus an optional
`_delivery.sh` plug for bespoke delivery), not an edit across `whoami.sh`,
`join.sh`, `spawn.sh`, and `delivery.sh`.

## The manifest

Each type has `scripts/drivers/types/<name>/type.conf` — read-only `key=value`
**data**. agmsg reads it with a small per-key reader; it is **never `source`d**, so
a manifest cannot execute code. Multi-value keys are whitespace-separated.

| key | required | meaning |
|---|---|---|
| `name` | yes | the type name (matches the directory) |
| `template` | yes | the `/agmsg` command template filename, relative to the type dir (e.g. `template.md`); becomes `SKILL.md` |
| `priority` | — | numeric auto-detection priority; lower values are checked first, with 50 as the default |
| `detect` | — | env-var names whose presence selects this type. `explicit` = never auto-detected from the environment |
| `detect_fallback` | — | weaker env-var names checked only after process detection, for shared credentials that are not reliable runtime markers |
| `detect_proc` | — | parent-process-name glob patterns that select this type (e.g. `codex codex-*`) |
| `session_env` | — | the single env-var name that carries this runtime's current session id. `join` passes its value to terminal self-naming; omitted means the type publishes no session id |
| `cli` | spawnable types | the launch command. Usually a single binary name, but may be a fixed multi-word prefix (subcommand and/or flags a CLI needs ahead of its own options) — only the first word is resolved/checked as the executable; the rest are passed through as-is. Safe because this is manifest data agmsg ships, not runtime user input |
| `spawnable` | — | `yes` if `spawn.sh` can launch this type |
| `spawn` | — | a `.mjs` node-launcher (beside the manifest) `spawn.sh` runs via Node; also marks the type spawnable |
| `model_arg` | — | the `--model`/`-m`-style flag `spawn --model <id>` passes through to the CLI; a type with no `model_arg` refuses `--model` |
| `prompt_arg` | — | for a CLI that does not accept the actas prompt as a bare positional argument, the named flag whose value IS the prompt (e.g. antigravity's `--prompt-interactive`, copilot's `--interactive`, opencode's `--prompt`) — `spawn.sh` inserts it immediately before the (already-quoted) prompt. Unset = bare positional, the default |
| `hooks_file` | yes | project-relative delivery hooks file (e.g. `.codex/hooks.json`) |
| `monitor` | — | `yes` if the type exposes a native Monitor tool; `spawn` skips the readiness wait when `no` |
| `delivery_modes` | — | space-separated delivery modes the type's CLI accepts (e.g. `monitor turn off`); `delivery.sh`'s gate rejects anything else. Defaults to `monitor turn both off` when omitted |
| `stop_output` | — | output protocol for the Stop/turn inbox check — `json` (codex, copilot) vs. plain text (default) |
| `hook_windows_wrap` | — | `yes` if JSON hook entries also need a Windows-native `commandWindows` variant (codex) |

> The reader does not fail-fast: an omitted key reads as the empty string, so
> "required" above means "needed for the type to actually work", not "validated at
> load time".

### Detection

`whoami.sh` auto-detects the running type when none is passed:

1. **Strong environment** — the manifests' `detect=` env vars, evaluated by
   ascending `priority` (then type name). `detect=explicit` types are never
   selected here.
2. **Process tree** — walking up from the current process, the first type whose
   `detect_proc=` glob matches the ancestor's name wins, using the same priority
   order.
3. **Fallback environment** — `detect_fallback=` vars are checked only now.
   This keeps shared credentials such as `GEMINI_API_KEY` from hiding a stronger
   process marker for another CLI; `GEMINI_CLI` remains a strong Gemini marker.
4. Falls back to `claude-code`.

> Precedence note: detection iterates types in ascending `priority`, then by name.
> Keep strong `detect=` vars runtime-exclusive (a runtime's own session marker,
> not a shared SDK credential) so ties do not arise. Shared credentials belong in
> `detect_fallback=` and are considered only after process evidence.

### Delivery

`hooks_file=` is the per-project file delivery hooks are written into, and
`delivery_modes=` declares which modes the type accepts (the central gate in
`delivery.sh` rejects the rest). The hook *format* lives in a **Template Method**:
`delivery.sh` defines the default behavior (JSON event-hooks) and a type's optional
`scripts/drivers/types/<name>/_delivery.sh` plug overrides any of
`agmsg_delivery_apply` / `on_enable` / `on_disable` / `status`. Rule-file types
(gemini, antigravity, …) delegate to the shared `rulefile_apply`; codex's plug adds
its bridge/shim lifecycle. No per-type `case` arms remain in `delivery.sh`.

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
as an external plugin (under `<install_dir>/plugins/types/<name>/` or a dir on
`$AGMSG_PLUGIN_DIRS`) with no built-in edits. External types must be opted into
with `agmsg plugin trust types/<name>` — see
[ADR 0002](adr/0002-driver-discovery-and-plugin-opt-in.md).

## Adding a type

1. Create `scripts/drivers/types/<name>/type.conf` with at least `name`,
   `template`, and `hooks_file` (add `detect`/`detect_proc` for auto-detection,
   `cli` + `spawnable=yes` if `spawn.sh` should launch it, and `delivery_modes` to
   restrict the modes the type accepts).
2. Add the command template beside the manifest as `template.md` (the path the
   `template=` key names, relative to the type dir).
3. If the type needs a delivery behavior that doesn't exist yet, add a
   `_delivery.sh` plug in the type dir overriding `agmsg_delivery_apply` /
   `on_enable` / `on_disable` / `status`. Reusing an existing format (default JSON
   hooks, or `rulefile_apply`) needs no code.

That's it — `whoami.sh`, `join.sh`, and `spawn.sh` pick the type up from the
registry with no further edits.

## Worked example

The six built-in manifests under `scripts/drivers/types/` are the reference. For
instance `scripts/drivers/types/codex/type.conf`:

```
name=codex
template=template.md
cli=codex
spawnable=yes
detect=CODEX_SANDBOX CODEX_THREAD_ID
session_env=CODEX_THREAD_ID
detect_proc=codex codex-*
hooks_file=.codex/hooks.json
readiness_sentinel=no
stop_output=json
hook_windows_wrap=yes
delivery_modes=monitor turn off
```
