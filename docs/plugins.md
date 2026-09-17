# Plugins (external drivers)

*[日本語](plugins.ja.md)*

agmsg's pluggable units are **drivers**, grouped by **axis**:

| axis | what it swaps | status |
|---|---|---|
| `types` | agent runtimes (claude-code, codex, gemini, …) | shipping |
| `storage` | the message store (sqlite, …) | planned |
| `delivery` | how messages reach an agent (monitor / turn / …) | planned |

Built-in drivers ship in-tree under `scripts/drivers/<axis>/<name>`. A **plugin**
is a driver shipped *outside* core that you drop in — no fork, no patch. This doc
covers discovering, trusting, and authoring them. The design rationale lives in
[ADR 0002](adr/0002-driver-discovery-and-plugin-opt-in.md); the driver contract
in [docs/spec/driver-interface.md](spec/driver-interface.md).

## Where plugins live

agmsg searches these bases, in order:

1. `<skill>/scripts/drivers/` — built-ins (always trusted)
2. `<skill>/plugins/` — your default plugin drop-in dir
3. each `:`-separated entry of `$AGMSG_PLUGIN_DIRS` — extra dirs

`<skill>` is the install dir (`~/.agents/skills/<cmd>/`). Each base holds
axis subdirs, so a types plugin named `foo` lives at
`<skill>/plugins/types/foo/` (with the same layout as a built-in type — see
[Agent types](agent-types.md)).

Among **eligible** candidates of the same `<axis>/<name>`, **later bases win**, so
a trusted plugin can deliberately override a built-in (e.g. customize `codex`
locally).

## Trust: external drivers are opt-in

A driver is shell code that runs with your privileges. So agmsg **never loads an
external driver until you explicitly opt in** — this turns a stray or malicious
drop-in from a code-execution vector into a harmless, ignored directory.

- Built-ins (`scripts/drivers/`) are always trusted.
- Anything under `plugins/` or `$AGMSG_PLUGIN_DIRS` is **ignored until trusted** —
  with a one-line warning on stderr the first time the registry runs:

  ```
  agmsg: external plugin 'types/foo' found at /…/plugins/types/foo but not trusted (ignored).
         Opt in if you put it there intentionally: agmsg plugin trust types/foo
  ```

- Trust is **path-pinned**: the allowlist records `<axis>/<name>` → the absolute
  path you trusted. A driver of that name resolved at a *different* path is **not**
  honored, so swapping a directory's contents (or shadowing it from a
  higher-priority base) does not silently activate unreviewed code. Moving a
  trusted plugin therefore requires re-trusting it — intentional friction.

The allowlist is a plain TSV at `<skill>/db/trusted-plugins` (preserved across
`--update`, like `config.yaml`). You normally manage it with the CLI below.

## The `agmsg plugin` command

```
agmsg plugin list                 # every discovered driver + its trust state
agmsg plugin trust <ref>          # opt into an external driver
agmsg plugin untrust <ref>        # revoke
```

`<ref>` is `<axis>/<name>` (e.g. `types/codex`) or a bare `<name>`. A bare name
matches across axes; if more than one axis has it, you must qualify it:

```
$ agmsg plugin trust codex
agmsg plugin: 'codex' is ambiguous across axes:
  types/codex
  storage/codex
       qualify it, e.g. agmsg plugin trust types/codex
```

`agmsg plugin list` marks each driver `builtin`, `trusted`, or `UNTRUSTED`:

```
AXIS/NAME                  STATE       PATH
types/codex                builtin     /…/scripts/drivers/types/codex
types/foo                  trusted     /…/plugins/types/foo
types/bar                  UNTRUSTED   /…/plugins/types/bar
```

> On non-Windows hosts the `agmsg` command surface is provided by your agent's
> skill flow; you can always invoke the script directly:
> `~/.agents/skills/<cmd>/scripts/plugin.sh list`.

## Authoring a types plugin

A types plugin is exactly a built-in type, placed under `plugins/types/<name>/`
instead of `scripts/drivers/types/`. The minimum is a `type.conf` manifest plus a
`template.md`; add a `_delivery.sh` plug for bespoke delivery. The full manifest
key reference and the delivery Template Method are in
[Agent types](agent-types.md).

```
<skill>/plugins/types/foo/
├── type.conf          # name=foo, template=template.md, hooks_file=…, delivery_modes=…
├── template.md        # the /agmsg command template (becomes SKILL.md)
└── _delivery.sh       # optional: override agmsg_delivery_apply / on_enable / …
```

Then trust it and confirm:

```
agmsg plugin trust types/foo
agmsg plugin list          # types/foo -> trusted
```

Manifests are read as **data** (never `source`d), so a plugin's `type.conf`
cannot execute code; only its `_delivery.sh` / launcher scripts run, and only
once you've trusted the plugin.

## Not yet supported

`plugin.json` metadata, `min_core_version` gating, and signing/sandboxing are
deferred (see [ADR 0001](adr/0001-storage-driver-pluginization.md) §5 and
[ADR 0002](adr/0002-driver-discovery-and-plugin-opt-in.md)). Today a plugin is a
plain directory you trust by path.
