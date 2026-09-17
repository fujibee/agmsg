# ADR 0004: `AGMSG_HOME` as a general data-root override, and an env-var naming convention

**Status:** proposed
**Date:** 2026-07-02
**Deciders:** @fujibee

## Context

Every install today resolves its data root (`db/`, `teams/`, `run/`) relative to
`SKILL_DIR` — the directory the running script physically lives in, normally
`~/.agents/skills/<cmd>/` (or a per-agent-type equivalent for Copilot/Hermes/
Grok/OpenCode installs). There is no general override; the two existing
env-var overrides are narrow and single-purpose: `AGMSG_STORAGE_PATH` (the
directory holding `messages.db` only) and `AGMSG_SPAWN_OPTIONS_FILE` (one
YAML file's path only, #273).

The official desktop app (Tauri-based) changes the
picture: it is meant to work **standalone**, with agmsg core bundled inside
the app bundle as a read-only sidecar, so a user who only wants the app never
touches `install.sh`. Bundled scripts can't write into the signed app bundle,
so the app needs *some* writable location for `db/`/`teams/`/`run/` — and if
a user also has the CLI installed separately, the app and the CLI need to
agree on that location, or they silently diverge into two different stores
for the same teams (the exact failure class behind the 2026-06-30 storage
fleet incident — mismatched schema/versions against the same store, from a
global `install.sh --update` of a schema-axis build while a heterogeneous
watcher fleet was running).

ADR 0002 previously rejected an `AGMSG_HOME` env var, but for a narrower
purpose: *external type-plugin discovery* (`~/.config/agmsg/types`), which it
replaced with the opt-in `AGMSG_PLUGIN_DIRS` + `agmsg plugin trust` scheme.
That ADR's own "runtime/config dir" note is scoped to plugin *discovery*,
not the data-root question this ADR answers — the two don't collide as long
as this ADR doesn't change what "runtime/config dir" means for that purpose.

This ADR does, however, touch a security-relevant file that also lives under
`db/` today: `driver-registry.sh`'s plugin-trust allowlist
(`<install_dir>/db/trusted-plugins`, ADR 0002). That decision is unaffected
by this ADR — this is a different concept (where the *data* lives, not
where *drivers* are discovered from or trusted) — but the allowlist's own
storage location needs an explicit call so `AGMSG_HOME` doesn't silently
change it as a side effect (see Decision).

Separately, the existing env vars have inconsistent naming
(`AGMSG_STORAGE_PATH` is actually a **directory**, not a path to a file),
which makes it hard to guess a new variable's shape from its name alone.

## Decision

**Add `AGMSG_HOME`**: when set, every install (CLI, and the desktop app's
bundled fallback) resolves `db/`, `teams/`, `run/`, and `config.yaml` under
it instead of the install-relative default. When unset, **each consumer
keeps its own default**, unchanged:

- **CLI / `install.sh` installs**: unset `AGMSG_HOME` continues to resolve
  everything relative to `SKILL_DIR`, exactly as today. No behavior change
  for any existing install.
- **Desktop app, when no system install is detected**: unset `AGMSG_HOME`
  falls back to `~/.agmsg/` (a fixed default, not configurable beyond the
  env var). The app first checks for a system install
  (`~/.agents/skills/<cmd>/`, or a well-known set of candidate command
  names) and prefers it when present, so a user running both the CLI and the
  app end up pointed at the same store without configuring anything.

**`driver-registry.sh`'s plugin-trust allowlist stays install-local — it
does not follow `AGMSG_HOME`.** `trusted-plugins` continues to resolve from
`<install_dir>/db/trusted-plugins` (the install's own `SKILL_DIR`) even when
`AGMSG_HOME` is set. Plugin trust is a driver-execution security boundary
(ADR 0002's concern), not message/team data (this ADR's concern), and this
ADR does not extend `AGMSG_HOME`'s reach into it — an install (or the app's
bundled fallback) trusting a plugin does not silently extend that trust to
a different install sharing the same `AGMSG_HOME`, even though they'd share
`db/`, `teams/`, `run/`. `driver-registry.sh` is therefore explicitly
out of scope for the path-resolution change below.

**Naming convention for env vars going forward:**

| Suffix | Meaning |
|---|---|
| `_HOME` | a root directory other paths are computed relative to |
| `_DIR` | a single specific directory |
| `_DIRS` (plural) | a list of directories |
| `_FILE` | a single specific file |
| `_PATH` | **avoid for new variables** — ambiguous (file or directory) |

`AGMSG_STORAGE_PATH` keeps its existing (slightly mislabeled) name —
renaming it would be a breaking change for anyone who has already set it.
New variables (including `AGMSG_HOME`) follow the table above.

## Alternatives considered

- **Hardcode `~/.agmsg/` for the app with no override.** Rejected: a user
  running both the CLI and the app would end up with two divergent stores
  unless the CLI install is *also* pointed at `~/.agmsg/` — which requires an
  override mechanism to exist somewhere. Simplest to make that mechanism
  `AGMSG_HOME` and have both consumers honor it.
- **Make `AGMSG_HOME` the new default root for CLI installs too (change
  `install.sh` to install under `~/.agmsg/` by default).** Rejected for *this*
  ADR — that is the larger #201 skills-CLI migration, not yet designed. This
  ADR only adds the override; it does not change any existing install's
  default location.
- **Reuse `AGMSG_STORAGE_PATH`'s scope for the app (just point it at
  `~/.agmsg/db`) instead of a new root variable.** Rejected: `teams/` and
  `run/` are not under `AGMSG_STORAGE_PATH`'s purview today (it is
  storage-axis-only, per its own doc comment), and the app needs all three
  to point at one place, not three separately-configured ones.
- **Auto-migrate an app-only `~/.agmsg/` store into `~/.agents/skills/<cmd>/`
  the first time a CLI install is detected.** Deferred, not rejected: real
  migration-on-detection is more machinery than this ADR needs to unblock
  the app's standalone mode. Worth a follow-up once #201 lands and CLI
  installs themselves start defaulting to `~/.agmsg/`, at which point the
  two cases (app-only, then-added CLI) naturally converge without a
  migration step.

## Consequences

- Positive: the desktop app can ship as a fully standalone product (no
  `install.sh` required) while staying schema-safe when a CLI install is
  also present, avoiding a repeat of the 2026-06-30 fleet-breaking mismatch
  described above.
- Positive: a documented, consistent env-var naming convention for future
  additions.
- Negative: another env var to document and to keep threaded through every
  script that currently derives paths from `SKILL_DIR` (`storage.sh`,
  `join.sh`, `actas-lock.sh`, `resolve-project.sh`, `config.sh`, and others)
  — this is a real, if mechanical, implementation cost.
- Neutral: `AGMSG_STORAGE_PATH`'s legacy naming is grandfathered rather than
  fixed; new code should not copy its `_PATH` suffix for a directory.

## References

- Supersedes nothing in [ADR 0002](0002-driver-discovery-and-plugin-opt-in.md)
  — that ADR's `AGMSG_HOME` rejection was scoped to type-plugin discovery,
  a different concern from this ADR's data-root override.
- Related: #201 (skills-CLI install migration — the larger direction this
  ADR is a compatible first step toward, not a commitment to it).
