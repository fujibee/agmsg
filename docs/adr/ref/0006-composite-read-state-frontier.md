# ADR 0006: Composite read-state frontier

**Status:** proposed (dogfood architecture)
**Date:** 2026-07-25
**Deciders:** @fujibee

## Context

Read state must converge across devices without hiding unread local-first
messages. A scalar local cursor cannot represent both a machine-local log and a
remote stream.

For example, local message L is unread at local position 5. Remote message R is
then imported at local position 6 and is already read elsewhere at remote
sequence 10. Assigning remote frontier 10 to local position 6 hides L.
Refusing the assignment but lacking an exact exception redelivers R forever.

Changing this meaning after ship would require a storage migration and would
reinterpret whether historical messages are unread. The frontier model is
therefore an architecture decision; API shapes and concrete limits remain in
the versioned specification.

## Decision

### Compose local and remote coverage

Each store evaluates read coverage from three monotonic facts:

1. a machine-local contiguous `local_position` frontier;
2. a binding-scoped contiguous `remote_server_seq` frontier; and
3. exact read exceptions.

A projected message is read when its own local position is covered, or its
durably mapped server sequence is covered, or its stable exact identity is in
the applicable exact set. Remote coverage is never guessed for an unmapped
local message.

Frontiers advance only through a contiguous prefix without unread holes. A
later read beyond a hole becomes an exact exception. When the hole closes, the
store may compact the newly contiguous prefix and garbage-collect absorbed
exceptions.

### Exact facts use portable identity

For a remote-synchronized message, the portable exact key is `wire_id`, not a
machine-local position. A local-only exact fact uses a stable local message ID.
Publishing or reconciling the durable local-to-wire mapping atomically promotes
or aliases that exact fact to the wire ID. It is eligible for remote upload only
after the mapping has a canonical acknowledged server sequence.

Message import, mapping publication, exact promotion, frontier compaction, and
the cursor transition that depends on them share the storage driver's atomic
boundary. Replay is idempotent.

### Scope local state and remote overlays separately

The local frontier and local exact facts belong to the originating store's
generation, stable local team identity, and member identity. They are never
merged between machines.

The remote frontier and wire exact set belong to the immutable remote binding
and stable member identity. The member anchor survives display-name changes and
installation moves. A remote overlay never becomes the authority for the local
layer merely because both are displayed together.

Remote merge algebra is:

- frontier: `max`;
- exact reads: set union;
- absorbed exact facts: delete only after durable sequence/mapping coverage
  proves they are below the merged frontier.

Read undo is outside this monotonic model and would require a separate
generation or epoch.

### Quarantine and retention do not falsify read coverage

Blocking quarantine is not a projected message and never counts as coverage.
Only successful reprocess/import makes the message eligible for read
projection. If that later import is already below a merged remote frontier, it
may appear read because another device durably reported that fact.

The authenticated retention floor is a minimum remote frontier. It never moves
the local frontier. Exact-set garbage collection still requires a live mapping
or tombstone sequence proving coverage; wire ID alone is insufficient.

### Remote state is finitely representable

The protocol bounds exact facts and paginates remote state. A limit violation
is atomic and identifies a causal offending member so other members and
read-only synchronization can continue. Concrete counts, page shapes, and
recovery operations are specification details, but finite representation and
fail-closed overflow are architecture requirements.

## Failure scenarios that fix the boundary

- **Scalar cursor overwrite.** Mapping remote sequence 10 to local position 6
  hides unread local position 5.
- **Position as portable exact key.** Position 6 on two stores need not name the
  same message, so set union would mark unrelated data read.
- **Quarantine as coverage.** A ciphertext that cannot authenticate or decrypt
  would silently advance user-visible read state before it can be displayed.
- **Floor copied to local cursor.** Retention of a remote prefix would mark
  unrelated local-only messages read.
- **Wire-only exact GC.** Without sequence proof, deleting an exact fact can
  lose an out-of-order read that the frontier does not cover.

## Rejected alternatives

- **One scalar local position.** Rejected by the unread-L/remote-R
  counterexample.
- **One scalar remote sequence.** Rejected because unmapped local messages and
  out-of-order reads still exist.
- **Last-writer-wins read records.** Rejected because delivery order would
  change meaning and allow a stale device to move state backward.
- **Treat transport or decrypt progress as read progress.** Rejected because
  those layers prove different facts.
- **Use mutable display names as the remote key.** Rejected because rename or
  name reuse would transfer another member's read authority.

## Consequences

- Read state converges under retry and reordering through max and set union.
- Storage drivers carry local compaction and exact-promotion logic.
- Out-of-order reads require bounded exact storage until holes close.
- Retention can remove remote payloads without changing local unread meaning.
- Non-monotonic unread/undo needs a future, explicitly versioned model.

## Normative specifications

- [Stage-2 read-state synchronization](../../spec/ref/read-state-synchronization.md)
- [HTTP API v1](../../../server/spec/v1.md)
- [Storage driver interface](../../spec/driver-interface.md)
- [ADR 0005: Remote synchronization contract](0005-remote-sync-contract.md)
