# ADR 0001: Storage driver pluginization with dependency-managed plugins

**Status:** accepted
**Date:** 2026-05-30
**Deciders:** @fujibee

## Context

agmsg was scaffolded with a single hard-coded storage layer (SQLite) accessed inline from helper scripts. As contributors and use cases grow, the project needs:

1. A way to swap the storage layer (the immediate motivating example is a JSONL file queried by DuckDB, which is friendlier for `grep`/`tail` inspection and for cross-machine sync via `git`/`rsync`).
2. A pattern for opt-in features that require external binaries the default install does not have (e.g. `duckdb`).

The constraint is that **the default install must remain bash + sqlite3 only** — no new users should be asked to install anything. Anything more capable must be opt-in, with the dependency story handled cleanly.

The same general "swappable driver behind a fixed protocol" shape will eventually apply to per-agent-type runtime adapters (issue [#48](https://github.com/fujibee/agmsg/issues/48)) and to delivery mechanisms (current `monitor`/`turn`/`both`/`off` mode dispatch). This ADR establishes the convention; subsequent ADRs may apply the same convention to the other axes.

## Decision

agmsg adopts a **3-axis driver model**: storage, agent, delivery. Each axis has exactly one active driver at a time, swapped through a common discovery/config/dependency-check protocol but exposing axis-specific operations. This ADR implements axis A (storage); the other axes follow under their own ADRs.

The locked design points are:

1. **Storage uses an append-only event log** (`message_sent`, `message_read`, …) projected by the driver to answer queries. The bundled sqlite driver also retains a **backward-compatible read path** for the legacy `messages` table with a mutable `read` flag, so existing installs do not need to migrate. New writes only target the event log.
2. **Drivers are bash scripts sourced by agmsg core**, exposing axis-prefixed functions (`storage_*`, `agent_*`, `delivery_*`). Subcommand-and-JSONL-pipe drivers (which would allow Python/Go implementations) are deferred until there is concrete demand.
3. **Common protocol is shared across axes; axis-specific functions are not forced into a single interface.** Every driver implements `<axis>_check` and `<axis>_describe`; everything else is per-axis.
4. **Message IDs are UUIDv7.** Existing SQLite integer autoincrement IDs are read as opaque decimal strings. A counter file is rejected.
5. **`AGMSG-DIRECTIVE` is a structured JSON line** (`AGMSG-DIRECTIVE: {...}`) emitted on stdout, parsed by the host agent. Free-text directives are dropped.
6. **`agmsg storage convert` uses staging + atomic flip**: write to a staging store, verify, then atomically update config. The previous driver remains active and intact until the final step.
7. **`storage_check` and `agmsg storage switch` return structured status codes** (`ok`, `missing_deps`, `incompatible_core`, `corrupt_state`, `runtime_error`) so the host agent can react appropriately rather than seeing only "non-zero exit".

agmsg itself never installs dependencies. Drivers emit `AGMSG-DIRECTIVE` lines on stdout when a dependency is missing; the host agent (Claude Code, Codex, Gemini CLI, Antigravity) parses the directive and runs the install command using its own tools, with the user's consent.

The v1 scope is **bundled drivers only**. Third-party plugin drivers (drivers shipped outside agmsg core, dropped into `~/.agents/agmsg/plugins/`) and the loader machinery they require (`plugin.json` parsing, `min_core_version` gating) are deferred until a concrete external driver is wanted. The vocabulary distinction between *bundled driver* and *plugin* is preserved in documentation so the protocol can be extended later without renaming.

The active storage driver is **machine-wide** (recorded in `~/.agents/agmsg/config.json`). Per-project override is deferred.

Vocabulary is **driver** (architectural unit), **plugin** (driver shipped outside core), **storage** (user-facing CLI noun for the storage axis). `backend`, `extension`, `provider`, and `adapter` are not used.

## Alternatives considered

### On mutable records vs event log (decision 1)

- **A. Mutable records (status quo, extended to JSONL).** Keep one row per message with an in-place `read` flag. Rejected: JSONL would need to rewrite the entire file on every `mark_read`, destroying the append-only property that motivated the JSONL+DuckDB option in the first place.
- **B. Event log everywhere, with full migration of existing sqlite installs.** Adopted *almost*. Rejected because the migration burden on existing users (single-machine, but still real) is avoidable: the sqlite driver can keep reading the legacy table while writing new events.
- **C. Event log everywhere, with backward-compatible read path on sqlite.** **Chosen.** The new format is uniform across drivers; existing sqlite data stays readable without explicit user action.

### On driver invocation style (decision 2)

- **A. Sourced bash functions.** **Chosen.** Matches existing agmsg style, lowest overhead, simplest to author.
- **B. Subcommand + JSONL pipe over stdin/stdout.** Cleaner contract, allows non-bash drivers. Rejected as YAGNI: no contributor has asked for a non-bash driver, and the protocol can be added later without breaking the bash one (drivers can wrap a subprocess).

### On interface unification across axes (decision 3)

- **A. One interface for all three axes.** Considered briefly. Rejected after review: storage is CRUD-shaped, agent is runtime-glue-shaped, delivery is lifecycle-shaped. Forcing them through one interface either over-abstracts or leaks axis-specific semantics into the abstract one. Reviewer (aggie-co) made the strongest case for this rejection.
- **B. Common protocol (discovery, config, dep-check, status codes) + axis-specific functions.** **Chosen.**

### On IDs (decision 4)

- **A. Counter file (`~/.agents/agmsg/next_id`).** Rejected: reintroduces the locking complexity the event-log design tried to remove, and worsens future multi-machine stories.
- **B. ULID.** Considered. Functionally equivalent to UUIDv7 for our needs; UUIDv7 chosen because it is an IETF standard and has more cross-language tooling.
- **C. UUIDv7.** **Chosen.**

### On directive format (decision 5)

- **A. Free-text directive parsed by the host agent.** Rejected: brittle, model-dependent, hard to test.
- **B. Structured JSON line with `type` discriminator.** **Chosen.** Trivial to parse, easy to extend with new directive types, and humans can still read it directly.

### On convert safety (decision 6)

- **A. In-place convert.** Rejected: a partial failure leaves the user with half-migrated data and no obvious recovery path.
- **B. Staging + atomic flip.** **Chosen.** Failure leaves the old driver active and intact; rollback is implicit.

### On status codes (decision 7)

- **A. Single non-zero exit on any failure.** Rejected: the host agent cannot distinguish "deps missing, please install" from "data corrupt, do not touch" — both require different reactions.
- **B. Structured status (`ok`, `missing_deps`, `incompatible_core`, `corrupt_state`, `runtime_error`).** **Chosen.** Enables the agentic install flow to succeed only on the right error class.

### On machine-wide vs per-project active driver

- **A. Per-project.** Rejected: increases configuration surface for marginal benefit; users would have to coordinate driver choice across projects with shared teams.
- **B. Machine-wide single active driver.** **Chosen.** Per-project override deferred to a future ADR if demand emerges.

### On vocabulary

- **A. `backend`.** Considered for storage. Rejected as ambiguous (could imply server-side service) and inconsistent with the other axes.
- **B. `extension` / `provider` / `adapter`.** Rejected as imported terminology with mismatched connotations (additive vs swap, cloud-domain bias, GoF-pattern reference).
- **C. `driver` (architectural) + `plugin` (distribution).** **Chosen.** `storage` as a user-facing noun for the axis.

## Consequences

### Positive

- Existing sqlite users see no change: zero migration, zero new dependencies.
- A JSONL+DuckDB driver becomes a small, well-scoped addition rather than a fork of the storage layer.
- The same protocol can be reused for axis B (agent — issue [#48](https://github.com/fujibee/agmsg/issues/48)) and axis C (delivery — future refactor).
- Failure modes are recoverable by construction: dep-check failures do not switch drivers, conversions only flip at the end, status codes give the host agent enough information to react correctly.
- Contributors can ship third-party drivers as plugins under `~/.agents/agmsg/plugins/storage/<name>/` without forking the repo.

### Negative

- Compaction of the event log becomes a long-term obligation; the v1 implementation includes only an internal command, and a user-facing one will be needed eventually.
- Drivers carry their own concurrency story (sqlite via WAL, jsonl-duckdb via lockfile). Inconsistent bugs are possible if a driver author misjudges atomicity.
- Bash sourced functions create namespace coupling; the axis-prefix convention mitigates but does not eliminate the risk. A future migration to subcommand-style drivers would be a non-trivial refactor.
- Plugin loader is deferred. When it lands, the trust model (shell plugins run with user privileges) becomes a real concern that needs an ADR of its own.

### Neutral

- The legacy `messages` table in existing sqlite databases is preserved indefinitely. Disk usage grows slowly until a future compaction tool removes it.
- Message IDs are heterogeneous across the legacy/new boundary (integer strings vs UUIDv7), but the interface treats them as opaque so user-visible queries remain straightforward.

## References

- Epic: [#51](https://github.com/fujibee/agmsg/issues/51)
- Related: [#48](https://github.com/fujibee/agmsg/issues/48) (agent-type driver refactor), [#49](https://github.com/fujibee/agmsg/issues/49) (`AGMSG_STORAGE_PATH` env var)
- Specification: [`docs/spec/driver-interface.md`](../spec/driver-interface.md)
- Concept overview: [`ARCHITECTURE.md`](../../ARCHITECTURE.md)
