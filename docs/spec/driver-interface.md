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

The storage axis is **messages only**: the durable message log and its read /
replay state. The team registry (`teams/<team>/config.json`) and run-state
(pidfiles, actas locks, ready sentinels) are
**not** part of this contract — they stay file-based and form a separate axis
(see [ADR 0003](../adr/0003-storage-axis-driver-abi-and-scope.md)). A storage driver
must implement the *entire* contract below: "this driver does only messages,
that one also does teams" is disallowed, because a partial implementation breaks
the swap-ability the axis exists for.

### 2.1 Required functions

```
storage_check
storage_describe
storage_init
storage_store_exists
storage_send <team> <from> <to> <body>
storage_list_unread <team> <agent> [--limit N]
storage_mark_read_batch <team> <agent> <id> [<id> ...]
storage_read_cursor_get <team> <agent>
storage_read_cursor_consume <team> <agent> <delivery-cursor> [<id> ...]
storage_watch_tip <team:agent> [<team:agent> ...]
storage_watch_after <cursor> <team:agent> [<team:agent> ...]
storage_history <team> [agent] [--limit N]
storage_export <file>
storage_import <file>
storage_compact                # internal; see §2.7
```

Every record carries `id` (UUIDv7 for new writes, an opaque string for legacy
ids) and `at` (ISO-8601 UTC). `storage_send` prints the new message's `id` on a
single line. The `watch_*` pair is defined in §2.2.

`storage_store_exists` answers — by exit code, 0 if a store is already present and
non-trivially initialized, non-zero otherwise — **without creating one**. A read
call-site (inbox / history) uses it to say "no messages yet" in a project that has
never used agmsg, rather than lazily materializing an empty store on a mere read.
It is the driver, not a fixed `messages.db` file check, that knows where its store
lives (sqlite's db file, jsonl's `events.jsonl`, a Redis key, …).

`storage_history`'s `<agent>` is optional: given, it returns only messages where
that agent is the sender or the recipient; omitted (or empty), it returns the
whole team's messages. Both forms are JSONL `message_sent` records. `--limit N`
selects the **most recent N** of the matching set; the output is always in
**time order, oldest→newest** (so a limited query returns the tail of the history,
still chronological — never newest-first). A driver must honour both this
selection (recency) and this ordering so the result is identical across backends.
Read-state is deliberately **not** carried on a history record — it is
recipient-scoped (§2.3), so a consumer that wants a read/unread marker derives it
by cross-referencing `storage_list_unread` for the relevant recipient rather than
from the history record itself.

**stdout framing.** The **control ops** — `storage_check`, `storage_init`,
`storage_mark_read_batch`, `storage_read_cursor_consume`, `storage_compact` —
**must** use the §1.4 convention:
a status name (`ok` / `missing_deps` / `runtime_error` / …) on the last stdout
line, with the matching exit code. The **record-returning ops** —
`storage_send`, `storage_list_unread`, `storage_read_cursor_get`,
`storage_history`, `storage_watch_tip`, `storage_watch_after` — write **data
only** to stdout (JSONL records, or a bare
id / cursor token; one record per line) and signal outcome with the **exit code**
alone: `0` on success, non-zero with a message on **stderr** on failure. They
never emit a §1.4 status name to stdout, so a status word can never be misread as
a record. The trailing `cursor` record of `storage_watch_after` is part of that
data stream (a designated final line), not a status.

`storage_describe` is a **metadata op**, not a control op: it always exits 0 and
writes only its `key=value` registry metadata to stdout — never a §1.4 status
name, which a metadata consumer would otherwise misread.

### 2.2 Delivery cursor (watch / replay)

Live delivery (`watch.sh`, `check-inbox.sh`, and `inbox.sh`) resumes from the
store-owned read frontier instead of re-reading the whole log. Its local
component is an **opaque, driver-issued cursor** in the driver's global message
order, persisted per `(team, agent)`. Core reads it with
`storage_read_cursor_get`, passes it unchanged to `storage_watch_after`, and
commits a successfully displayed scan with `storage_read_cursor_consume`.
**Core never parses, compares, or orders cursors.** This lets one contract serve
sqlite integer positions, Redis stream IDs, and JSONL logical ordinals.

The cursor is opaque to core but constrained for transport: it must be a
**single-line, whitespace-free, printable token** that survives being written to
a run-dir file and passed back as one `argv` argument to the sourced driver.
Native positions that already satisfy this (a sqlite integer `seq`, a Redis
stream id) are used as-is; a driver whose native position carries unsafe
characters (e.g. a JSONL byte offset bundled with metadata) must encode it
(base64url or similar) into a single safe token.

- `storage_watch_tip <pairs...>` — print the cursor for "now" (the current tip of
  the global order) as a single bare line.
- `storage_watch_after <cursor> <pairs...>` — print, as JSONL and in delivery
  order, every `message_sent` after `<cursor>` addressed to one of the
  subscription pairs; then print a final cursor record
  `{"type":"cursor","cursor":"<opaque>"}` as the last line. That trailing cursor
  is the **global tip the driver can safely resume from at call time** (the same
  notion as `storage_watch_tip`) — *not* the cursor of the last matching message.
  It is always emitted, and advances even when zero subscription messages fell in
  the range, so a watcher behind heavy off-subscription traffic does not re-scan
  the same span on every poll. Poll-once: it returns what is currently available
  and exits — core loops on its own interval; a streaming backend may implement
  it as one non-blocking drain.

- `storage_read_cursor_get <team> <agent>` — print the local-position component
  for the pair, defaulting to the driver's zero cursor.
- `storage_read_cursor_consume <team> <agent> <cursor> [ids...]` — atomically
  record the exact displayed IDs, then max-merge the pair's local frontier only
  through the contiguous covered prefix ending no later than `<cursor>`. A
  missing unread message is a hard gap: a later exact read is retained as an
  exception and MUST NOT move the frontier across that gap.

The same pair cursor is shared by inbox and monitor delivery and survives
session termination. A successful empty scan may advance across
off-subscription traffic. A crash before consume re-delivers; a crash after the
atomic consume does not. A one-time driver migration treats pre-cursor backlog
as consumed to avoid a full-history monitor storm; new stores start at zero.

Each `<pair>` is `<team>:<agent>`. Team and agent names cannot contain `:` (the
name rules enforce this); a driver may additionally reject a pair it cannot split
unambiguously.

### 2.3 Event log schema

The bundled drivers represent state as an append-only event log. Each event is
one record with a `type` discriminator — and only these two types live in the
storage axis (team membership does not; see the §2 intro):

```jsonl
{"type":"message_sent","id":"0192...","team":"agsuite","from":"alice","to":"bob","body":"...","at":"2026-05-30T19:00:00Z"}
{"type":"message_read","id":"0192...","msg_id":"0192...","team":"agsuite","agent":"bob","at":"2026-05-30T19:05:00Z"}
```

`storage_list_unread <team> <agent>` returns the `message_sent` events addressed
to `<agent>` in `<team>` that are not covered by the pair's contiguous read
frontier or an exact `message_read` exception. Read-marking is
**recipient-scoped**: a `message_read` names the `(team, agent)` that read the
message, so marking one recipient's copy never affects another's, and re-marking
an already-read id is **idempotent**. The legacy mutable `messages.read_at`
field is compatibility/audit input only; new read progress never mutates it.

**Schema version.** This is **event-log schema v1**. The two event types above
and their fields are the v1 contract. Forward compatibility is a hard rule, not a
courtesy: a projection **must ignore event `type`s it does not recognize and
object fields it does not recognize**. That is the only "version marker" v1 needs
— a later revision may add new optional fields or new event types without a
breaking bump, and a v1 reader stays correct (it skips what it cannot interpret
rather than failing). `export` emits the raw event stream in `seq` order; a v1
`import` accepts the record types it knows and is free to drop ones it does not.
A change that removes or repurposes an existing field is the only thing that
requires a new major schema version.

### 2.4 Legacy compatibility (sqlite only)

The bundled sqlite driver reads two sources for `storage_list_unread` and
`storage_history`:

1. the legacy `messages` table (rows where `read_at IS NULL`) for installs that
   predate the event log, and
2. the event-log tables for everything written after.

Writes target the event log. There is no automated migration; legacy rows stay
queryable indefinitely. Legacy integer ids are passed through as decimal strings
(opaque, per §2.5).

**Known gap — consumers still coupled to the sqlite driver's own schema.**
`rename.sh`/`rename-team.sh` (rewriting a renamed identity across historical
messages) and `api.sh`'s `get teams <team> messages` (which needs
`--before-id` pagination the contract does not expose) currently read/write
the sqlite driver's `messages`/`events` tables directly rather than through a
`storage_*` function, so they only work correctly when sqlite is the active
driver. See [ADR 0003](../adr/0003-storage-axis-driver-abi-and-scope.md)'s
consequences for the tracked follow-up (a rename-across-history op, and a
paginated history op).

### 2.5 Identifiers

IDs that drivers generate for new writes are **UUIDv7** strings. The interface
treats every id as opaque, so a driver reading legacy data (sqlite autoincrement
ints) passes them through as decimal strings. UUIDv7 is generated inside the
driver (`python -c "..."`, a `uuidgen` that supports v7, or a shell
implementation); drivers must not depend on a counter file. The delivery cursor
(§2.2) is a **separate** opaque token from message ids — a driver may build it
from ids, byte offsets, or stream positions.

### 2.6 Concurrency

Drivers own the concurrency model of their backing store:

- the sqlite driver relies on SQLite's WAL mode;
- a `jsonl` / `duckdb` driver uses a lockfile around mark-read sequences and
  around `compact` / `export` / `import`; single appends may rely on POSIX append
  atomicity for writes ≤ `PIPE_BUF` bytes.

### 2.7 Compaction

The event log grows unbounded (append-only), so every record-replaying driver —
and especially a `jsonl` driver that re-reads the whole file per query — needs a
way to bound it. Drivers implement an internal `storage_compact` that collapses
redundant events. v1 exposes this only internally; a user-facing CLI may follow.

`storage_compact` is the load-bearing primitive that keeps a log-based backend in
its fast band, so its behaviour is **contractual**, not best-effort. A conforming
`storage_compact` must satisfy all of:

1. **Idempotent** — `compact` then `compact` again leaves the store identical to a
   single `compact`. Running it repeatedly is always safe.
2. **State-preserving (observable equivalence)** — every contract read
   (`storage_list_unread`, `storage_history`, and the projected state an `export`
   re-imports to) returns the **same result** before and after a `compact`. Only
   the physical footprint (event count / bytes) shrinks; no visible message,
   read-state, or ordering changes.
3. **Read-coalescing** — redundant `message_read` markers for the same
   `(team, agent, msg_id)` collapse to one. This is the primary size win and the
   minimum a driver must do. (`storage_mark_read_batch` is itself write-idempotent,
   so such duplicates do not arise in single-writer use; they come from a racing
   writer or a merged `import`, and compaction is the backstop that cleans them up.)
4. **Monotonic** — `compact` never increases the stored event count.
5. **Cursor-safe (never skip)** — `compact` must **not invalidate a delivery
   cursor (§2.2) already handed out**. A cursor issued before a `compact` must,
   when replayed after it, still deliver every `message_sent` that falls after it
   — none may be skipped. A driver whose physical cursor would be broken by
   compaction (e.g. a `jsonl` byte offset invalidated by a log rewrite) must use a
   **logical, compaction-stable cursor** so that, in the worst case, a stale
   cursor **degrades to at-least-once re-delivery and never to a dropped
   message**. The bundled sqlite driver gets this for free: it never deletes or
   renumbers `message_sent` rows, and it issues cursors from a monotonic
   high-water (`sqlite_sequence`) that a `DELETE`-based compaction cannot move
   backwards.

Compaction must never touch `message_sent` records; it operates only on the
redundant read-state markers layered over them.

### 2.8 Optional Stage-1 remote synchronization extension

A driver that can make remote reconciliation atomic with its local message log
may advertise `capabilities=stage1-sync` from `storage_describe` and implement:

```text
storage_sync_prepare_push <local-team> <server-instance-id> <remote-team-id> <protocol-version> <limit>
storage_sync_reconcile_push <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_apply_pull <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_reprocess <local-team> <server-instance-id> <remote-team-id> <protocol-version> <limit> [<page-after>]
```

The extension is optional: a driver without it remains a conforming local-only
storage driver. Bulk input and output are UTF-8 JSONL on stdin/stdout; only the
non-secret binding identifiers and limits above may use argv. The binding key
is `(server_instance_id, remote_team_id, protocol_version)`, and every local
position is additionally paired with the driver's persistent generation.
The bundled SQLite and JSONL drivers advertise this capability. JSONL uses a
locked snapshot through EOF plus one fsynced append record per transition; its
sync local position is a byte offset paired with the file generation, not its
separate ordinal delivery cursor.

Prepare publishes a wire ID and complete canonical envelope together in one
durable transaction before emitting it and is re-entrant by local position.
Private randomized sealing attempts that fail before publication are abandoned;
recovery never re-encrypts a published wire ID. Reconcile atomically records complete
server acknowledgements and advances only an acknowledged contiguous local
prefix. Apply-pull atomically quarantines unchanged envelopes, reconciles mapped
echoes or imports unmapped wire IDs once, and advances the transport cursor only
after durable local outcomes. Transport, decrypt/import, and read progress are
independent. Reprocess emits blocking quarantine records for explicit policy/key
reevaluation without rewinding transport. It uses the Stage-1 specification's stable
`(server_seq,wire_id)` keyset page and mandatory `sync_reprocess_page` trailer,
so one explicit engine invocation reaches every candidate without an early
permanent failure starving later records. The complete framing, record schemas,
crash boundaries, and future reserved operation names are defined by
[Stage-1 synchronization specification](ref/stage-1-remote-sync.md).

A driver may additionally advertise `stage1-resync` and implement the explicit
operator recovery contract from the
[retention-gap resynchronization specification](ref/retention-gap-resynchronization.md):

```text
storage_sync_resync_status <local-team> <server-instance-id> <remote-team-id> <protocol-version> <accepted-floor>
storage_sync_resync <local-team> <server-instance-id> <remote-team-id> <protocol-version>
```

Status is a strictly read-only cursor/audit lookup; it cannot reserve or seal a
message. Resync atomically records an authenticated, operator-accepted retention
gap and advances only the transport cursor. Together they make result-loss
retry idempotent without exposing driver storage internals. They never make
HTTP 410 an automatic polling recovery and never delete local messages or
independent state layers. The retention-gap specification pins their exact strict JSONL status, input,
audit, and result objects, including canonical sequence arithmetic and
duplicate/unknown-field rejection.

The independent Stage-2 extension from the
[read-state synchronization specification](ref/read-state-synchronization.md) is advertised as
`capabilities=stage1-sync,stage2-read-state` and adds:

```text
storage_sync_prepare_read_state <local-team> <server-instance-id> <remote-team-id> <protocol-version>
storage_sync_apply_read_state <local-team> <server-instance-id> <remote-team-id> <protocol-version>
```

Prepare exports a safe
contiguous remote `server_seq` frontier plus out-of-order exact `wire_id` reads;
apply max-merges the frontier and set-unions exact reads. Local-only exact reads
are promoted from stable local ID to wire ID in the same transaction that
publishes or reconciles the mapping. Neither operation may change transport or
decrypt/import progress. Exact remote state is bounded and paginated, and may
be garbage-collected only after a durable mapping proves that its own sequence
is covered by the merged remote frontier.

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
