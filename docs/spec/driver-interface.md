# Driver Interface Specification

*[日本語](driver-interface.ja.md)*

**Status:** draft (epic [#51](https://github.com/fujibee/agmsg/issues/51))
**Scope:** axis A — storage. The common protocol sections also apply to axes B (agent) and C (delivery) but their axis-specific functions are out of scope here.

This document defines the contract between agmsg core and a storage driver. It is the authoritative source for what any new driver must implement.

**v1 scope:** bundled drivers only. The plugin path (`~/.agents/agmsg/plugins/`), `plugin.json` metadata, and `min_core_version` gating are deferred to a future revision; see §6.

## 1. Common driver protocol

These conventions apply to every driver on every axis.

### 1.1 Driver location

Bundled drivers live at `scripts/drivers/<axis>/<name>`. File-based axes use a single `<name>.sh`; the agent-type ("types") axis uses a directory `scripts/drivers/types/<name>/` holding a `type.conf` manifest plus the type's runtime. Their metadata is implicit and tied to the agmsg core version.

External (non-bundled) drivers are discovered from `<install_dir>/plugins/<axis>/<name>` and from `$AGMSG_PLUGIN_DIRS`, and must be opted into — see [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md).

### 1.2 Calling convention

Drivers are bash scripts that agmsg core `source`s and then calls by function name. Function names are prefixed by axis to avoid collisions: storage drivers expose `storage_*` functions, agent drivers expose `agent_*`, delivery drivers expose `delivery_*`.

Drivers must not pollute the global namespace beyond their prefix and must not define `set -e`/`set -u` semantics; those are the caller's responsibility.

### 1.3 Required common functions

Every driver, on every axis, implements:

| Function | Purpose | Returns |
|---|---|---|
| `<axis>_check` | Verify that all runtime dependencies are present and the driver can activate. May emit an `AGMSG-DIRECTIVE` on stdout when a dependency is missing. | status code (see §1.4) |
| `<axis>_describe` | Print a one-line human-readable description on stdout. | always 0 |

### 1.4 Status codes

Driver functions that can fail report a structured status by exit code **and** by printing the status name on stdout as the last line. The status names are:

| Code | Name | Meaning |
|---|---|---|
| 0 | `ok` | Operation succeeded |
| 10 | `missing_deps` | A required external dependency is not installed. An `AGMSG-DIRECTIVE` describing the install was emitted on stdout. |
| 12 | `corrupt_state` | Driver detected unrecoverable inconsistency in its data store. Manual intervention required. |
| 13 | `runtime_error` | Any other failure. stderr contains the message. |

(Code `11 incompatible_core` is reserved for the future plugin loader; not used in v1.)

Callers may treat any non-zero exit as failure, but the status name is the source of truth for the host agent's reaction.

### 1.6 `AGMSG-DIRECTIVE`

A single line written to stdout, prefixed with `AGMSG-DIRECTIVE: ` followed by a JSON object. The host agent reads, parses, and acts on the directive.

```
AGMSG-DIRECTIVE: {"type":"install_deps","driver":"jsonl-duckdb","commands":["brew install duckdb"],"reason":"duckdb binary not found on PATH"}
```

| Field | Type | Description |
|---|---|---|
| `type` | string | One of `install_deps`, `invoke_monitor`, `stop_task`. Extensible. |
| `driver` | string | The driver name emitting the directive (when applicable) |
| `commands` | string[] | Shell commands the host agent may run, in order. Optional. |
| `reason` | string | Human-readable explanation for the user. |
| `*` | any | Type-specific fields; consult the per-type schema in this document. |

Directives are advisory: the host agent decides whether to surface them to the user, run them automatically, or ignore them.

## 2. Storage driver

### 2.1 Required functions

```
storage_check
storage_describe
storage_init
storage_insert_message <team> <from> <to> <body>
storage_unread <team> <agent> [--limit N]
storage_mark_read <id>
storage_mark_read_batch <id> [<id> ...]
storage_history <team> <agent> [--limit N]
storage_teams
storage_team_members <team>
storage_export <file>
storage_import <file>
```

All functions write structured output (JSONL) to stdout when returning records and follow §1.4 for status. Records always include `id` (UUIDv7 for new writes, opaque string for legacy IDs) and `at` (ISO-8601 UTC).

### 2.2 Event log schema

Bundled drivers represent state as an append-only event log. Each event is one record with a `type` discriminator:

```jsonl
{"type":"message_sent","id":"0192...","team":"agsuite","from":"aggie-cc","to":"aggie-co","body":"...","at":"2026-05-30T19:00:00Z"}
{"type":"message_read","id":"0192...","msg_id":"0192...","agent":"aggie-co","at":"2026-05-30T19:05:00Z"}
{"type":"team_joined","id":"0192...","team":"agsuite","agent":"alice","agent_type":"claude-code","project":"/path","at":"..."}
{"type":"team_left","id":"0192...","team":"agsuite","agent":"alice","at":"..."}
```

Drivers project these events to answer queries. `storage_unread` returns `message_sent` events whose `id` has no corresponding `message_read` for the requesting agent.

### 2.3 Legacy compatibility (sqlite only)

The bundled sqlite driver reads two sources for `storage_unread` and `storage_history`:

1. The legacy `messages` table (rows where `read=0`) for installations that predate the event log refactor
2. The new event log tables for everything written after the refactor

Writes only target the event log. There is no automated migration; legacy rows stay where they are and remain queryable indefinitely.

### 2.4 Identifiers

All IDs generated by drivers must be **UUIDv7** strings. The interface treats IDs as opaque, so drivers reading legacy data (integer autoincrement IDs in sqlite) may pass them through as decimal strings.

UUIDv7 is generated within the driver (e.g. via `python -c "..."`, `uuidgen` on platforms that support v7, or a shell implementation). Drivers must not depend on a counter file.

### 2.5 Concurrency

Drivers are responsible for the concurrency model of their backing store:

- The sqlite driver relies on SQLite's WAL mode.
- The `jsonl-duckdb` driver must use a lockfile around mark-read sequences and around `convert`/`export`/`import`. Single-message appends may rely on POSIX append atomicity for writes ≤ `PIPE_BUF` bytes.

### 2.6 Compaction

The event log grows unbounded. Drivers must implement an internal `storage_compact` function that collapses redundant events (e.g. coalescing `message_read` markers, dropping events for deleted teams). v1 exposes this only as an internal command; a user-facing CLI may follow.

## 3. CLI mapping

| User command | Driver function(s) |
|---|---|
| `agmsg storage` | `storage_describe` of active driver |
| `agmsg storage list` | iterate available drivers, call `<axis>_describe` per driver |
| `agmsg storage switch <name>` | new driver's `storage_check`; on `ok`, update config; on `missing_deps`, propagate directive without switching |
| `agmsg storage convert <to>` | new driver's `storage_check`; if `ok`, current `storage_export` → temp → new `storage_import` → verify → atomic config update |
| `agmsg storage export <file>` | active driver's `storage_export` |
| `agmsg storage import <file>` | active driver's `storage_import` |

## 4. Config

Active driver per axis is recorded in `~/.agents/agmsg/config.json`:

```json
{
  "storage": "sqlite",
  "delivery": { "claude-code": "monitor", "codex": "turn" }
}
```

`storage` is a single string (machine-wide). `delivery` is per agent type because runtimes differ in available delivery mechanisms. `agent` is implicit from the per-invocation `<type>` argument.

## 5. Out of scope (deferred)

- **Plugin loader** — external-driver discovery (`<install_dir>/plugins/`, `$AGMSG_PLUGIN_DIRS`) and the opt-in trust model are now defined by [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md). Still deferred from that loader: `plugin.json` metadata parsing, `min_core_version` gating, and the `incompatible_core` status code.
- **Plugin signing or sandboxing** — orthogonal to the loader; would be addressed when the loader lands.
- **Per-project active driver override** — v1 is machine-wide; future enhancement.
- **Subcommand + JSONL-pipe driver protocol** (language-independent drivers) — deferred until a non-bash driver is actually wanted.
- **Cross-machine storage drivers** (postgres, s3-jsonl) — not blocked by this spec; can be added under the same protocol when needed.
