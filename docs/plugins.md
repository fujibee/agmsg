# Plugins (external drivers)

*[日本語](plugins.ja.md)*

agmsg's pluggable units are **drivers**, grouped by **axis**:

| axis | what it swaps | status |
|---|---|---|
| `types` | agent runtimes (claude-code, codex, gemini, …) | shipping |
| `ext-tools` | external tools a team member can be (Slack, …) | shipping |
| `terminals` | terminal drivers (tmux, herdr, …) | shipping |
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
3. each installed plugin source listed in `<skill>/db/plugin-sources` (see
   [Installing a plugin from GitHub](#installing-a-plugin-from-github))
4. each `:`-separated entry of `$AGMSG_PLUGIN_DIRS` — extra dirs

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
agmsg plugin install|update|remove ...   # from GitHub, see below
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
AXIS/NAME                  STATE       SOURCE                       COMMIT        PATH
types/codex                builtin     -                            -             /…/scripts/drivers/types/codex
types/foo                  trusted     -                            -             /…/plugins/types/foo
types/bar                  UNTRUSTED   -                            -             /…/plugins/types/bar
types/baz                  trusted     github/acme/baz              9074a92c6404  /…/plugins/sources/github/acme/baz/9074…/types/baz
```

> On non-Windows hosts the `agmsg` command surface is provided by your agent's
> skill flow; you can always invoke the script directly:
> `~/.agents/skills/<cmd>/scripts/plugin.sh list`.
> The `install`, `update` and `remove` commands are available the same way, and as
> `/agmsg plugin ...` in your agent (the agent asks you before it installs anything).

## Installing a plugin from GitHub

A plugin can be published as its own GitHub repository and installed with one
command. Plugins installed this way are third-party code: **you install them at
your own risk. agmsg does not review or sign plugins.** Version 1 supports `git`
only (no archive URLs), so `git` must be installed.

```
agmsg plugin install <owner>/<repo>[@<ref>] [--yes] [--override]   # alias: add
agmsg plugin update  <owner>/<repo>[@<ref>] [--yes] [--override]
agmsg plugin remove  <owner>/<repo>                                 # alias: uninstall
agmsg plugin list
```

`<ref>` is a branch, a tag, or a full commit SHA. `install` without it uses the
default branch. `update` without it follows the ref recorded at install time (the
default branch if none), so a plugin installed from an exact SHA stays on that SHA
until you give `update` another ref. Installing and updating always show what will happen first and ask. With no
terminal and no `--yes`, the command prints the same report, installs nothing and
exits with status 3 ("needs confirmation").

**What `install` does**

1. Fetches a shallow checkout of `https://github.com/<owner>/<repo>` into a staging
   directory.
2. Checks it: `agmsg-plugin.conf` is present, only the `ext-tools`, `terminals` and
   `types` axes are used (anything else is ignored and listed as such), driver names
   match `[a-z0-9-]+`, no symlinks, `min_core` is not newer than this agmsg, and
   nothing clashes (see below).
3. Prints the source and commit, every `<axis>/<name>` it adds, every file that can
   run (a shebang or the executable bit), and the at-your-own-risk notice.
4. Asks `y/N` (or uses `--yes`), then installs and trusts each driver.

The checkout lives in `<skill>/plugins/sources/github/<owner>/<repo>/<sha>/` and is
listed in `<skill>/db/plugin-sources`. Only `agmsg-plugin.conf` and the driver
directories are kept. `plugins/sources/` is managed by these commands; do not put
hand-made plugins in it.

**The commit is pinned.** The directory name is the commit SHA and trust is
path-pinned (see above), so trust is tied to exactly that commit. `update` fetches
the same spec again: if the commit is the same it says so; if it is new it shows the
old and new SHA and the added, modified and deleted files, and asks again. Only
after you confirm is the new commit trusted and the old one removed. Nothing is ever
updated on its own — not by `install --update`, not in the background. To pin
yourself, install `<owner>/<repo>@<full-sha>`. When an agent runs the command for
you, it shows you the report and asks in chat, then reruns pinned to the commit it
showed: `plugin install <owner>/<repo>@<sha> --yes --track <branch>`. The extra
`--track <branch>` (or `--track-default` for the default branch) records which ref
later updates follow while the commit stays exactly the one you approved; the
report's closing line prints the full command. Without it, an exact SHA is a
permanent pin.

**Clashes.**

- A driver with the same `<axis>/<name>` as one from another installed source, or
  one you placed by hand under `plugins/`, is refused with both named.
- A driver with the same `<axis>/<name>` as a **built-in** (for example `types/codex`)
  would replace it for every team on this machine. `install` stops and explains what
  would be replaced, what can break, and that `plugin remove` brings the built-in back.
  Proceed on purpose with `--override`. `update` asks for `--override` only for a
  built-in the installed commit did not already replace.

**`remove`** untrusts the source's drivers, deletes its checkout and record, and says
when a built-in is back in use.

**`agmsg-plugin.conf`** is `key=value` data (never `source`d):

```
name=my-plugin
description=What it adds
min_core=1.6.0
```

`name` and `description` are shown in the report. `min_core` is optional; if it is
newer than the running agmsg the install is refused.

**Repository layout**

```
<repo>/
├── agmsg-plugin.conf
├── ext-tools/<tool>/...      # same contract as scripts/drivers/ext-tools/README.md
├── terminals/<name>/...      # same contract as a built-in terminal driver
└── types/<name>/...          # same contract as agent-types.md
```

`storage` plugins are not accepted from GitHub yet. A plugin agent type is delivered
by the classic delivery path; it does not get agmsgd's native delivery.

> These are **agmsg plugins** (drivers). They are a different thing from the
> *Claude Code plugin*, which is one way to distribute agmsg itself.

For testing, `AGMSG_PLUGIN_GIT_BASE` replaces the `https://github.com` part of the
clone URL (for example with a local `file://` directory).

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

Signing and sandboxing are deferred (see
[ADR 0001](adr/0001-storage-driver-pluginization.md) §5 and
[ADR 0002](adr/0002-driver-discovery-and-plugin-opt-in.md)), as are installing from
an archive URL and installing `storage` plugins. A plugin is code you trust by path
(and, when installed from GitHub, by commit).
