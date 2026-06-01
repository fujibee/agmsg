# Architecture

This document describes the internal shape of agmsg — the mental model a contributor needs before reading the code or the interface spec. For *what* to implement, see [`docs/spec/`](docs/spec/). For *why* a decision was made, see [`docs/adr/`](docs/adr/).

## Goal

A cross-agent messaging primitive that works between any combination of Claude Code, Codex, Gemini CLI, Antigravity, and future agent runtimes — with no daemon, no network, no shared cloud. Messages move through local files on a single machine; receivers are notified through whatever hook or streaming mechanism their host runtime provides.

The default install must work with **bash + sqlite3 only**. Any feature beyond that is opt-in and may require additional dependencies that the user agrees to install.

## The 3-axis driver model

agmsg is built around three orthogonal axes, each of which has exactly one **driver** active at a time. A driver is a swappable implementation behind a fixed protocol.

| Axis | What it abstracts | Bundled drivers |
|---|---|---|
| **storage** | Where messages and team state live, and how they are queried | `sqlite` (default), `jsonl-duckdb` |
| **agent** | Per-runtime differences (hook formats, settings file locations, monitor tool availability) | `claude-code`, `codex`, `gemini`, `antigravity`, `copilot` |
| **delivery** | How a recipient is notified that a message arrived | `monitor`, `turn`, `both`, `off` |

The three axes are independent: any storage driver can be paired with any agent driver and any delivery mode. They share a common discovery/config/dependency-check protocol (see the spec) but expose axis-specific operations.

## Driver vs plugin

- **driver** is the architectural unit. Both bundled implementations and user-installed ones are drivers.
- **plugin** is a distribution distinction: a driver that ships outside agmsg core, dropped into a user-controlled directory.

Bundled drivers live under `scripts/drivers/<axis>/`. Inside `scripts/`, the top-level `.sh` files are directly-invokable commands; subdirectories group implementation code by category (`drivers/` for axis drivers, `lib/` for shared helpers).

The plugin path (`~/.agents/agmsg/plugins/<axis>/<name>/`) is reserved for a future enhancement and is not implemented in v1. Until a concrete external driver is wanted, all drivers ship bundled. Both are discovered and loaded through the same protocol.

agmsg does not use the terms *backend*, *extension*, *provider*, or *adapter*. `storage`, when written in user-facing documentation and CLI, is a synonym for "storage driver".

## Dependency management

Drivers may require external tools (e.g. the `jsonl-duckdb` storage driver needs `duckdb` on `$PATH`). agmsg never installs those tools itself. Instead:

1. When a driver is activated or its `check` subcommand is invoked, it inspects its environment.
2. If a dependency is missing, the driver emits a **machine-readable `AGMSG-DIRECTIVE`** line on stdout describing what to install and how.
3. The host agent (Claude Code, Codex, etc.) reads the directive and runs the install command, with the user's consent, using its own tools.
4. On the next agmsg invocation, the dependency check passes and the driver activates.

This keeps agmsg itself minimal and platform-agnostic. The host agent is already trusted with file and shell access, so dependency installation is naturally its responsibility.

The same `AGMSG-DIRECTIVE` mechanism is used for other host-agent-coordinated actions (e.g. telling Claude Code to invoke its Monitor tool when delivery mode is set to `monitor`).

## Failure semantics

Switching a storage driver is the most consequential action agmsg takes. The protocol prioritizes leaving the system in a recoverable state:

- A dep-check failure during `agmsg storage switch` does **not** change the active driver. The user is prompted with the directive and given a fallback.
- A `convert` always writes to a staging store first, verifies it, then performs the atomic config flip. The previous driver remains active and intact until the final step.
- Status codes are structured (`ok`, `missing_deps`, `incompatible_core`, `corrupt_state`, `runtime_error`) so the host agent can react appropriately rather than treating every non-zero exit identically.

## Storage shape

Storage drivers expose CRUD-like operations to the rest of agmsg (insert a message, list unread for an agent, mark read, query history). Internally, the bundled drivers represent state as an **append-only event log** (`message_sent`, `message_read`, etc.). Mutable status — most importantly the read flag — is derived by projection over the event stream rather than by in-place updates.

The sqlite driver retains a backward-compatible read path for the legacy `messages` table with an inline `read` column, so existing installs continue to work without migration. New writes go to the event log; reads union both sources.

Message identifiers are **UUIDv7** strings. The interface treats them as opaque so existing sqlite databases with integer autoincrement IDs remain readable.

## Vocabulary

| Term | Meaning |
|---|---|
| **driver** | Swappable implementation of a fixed protocol on one axis |
| **plugin** | A driver distributed outside agmsg core |
| **bundled driver** | A driver shipped inside agmsg core |
| **storage** | The storage axis, or its active driver, in user-facing contexts |
| **AGMSG-DIRECTIVE** | A JSON line emitted on stdout instructing the host agent to take a specific action |
| **host agent** | The runtime invoking agmsg scripts (Claude Code, Codex, Gemini CLI, Antigravity, …) |
| **event log** | The append-only record of message lifecycle events that bundled storage drivers project queries over |

## See also

- [`docs/spec/driver-interface.md`](docs/spec/driver-interface.md) — the formal contract a driver must satisfy
- [`docs/adr/`](docs/adr/) — historical record of design decisions
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to propose changes
