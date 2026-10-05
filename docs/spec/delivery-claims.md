# Delivery claims and acknowledgement

`delivery-claims-v1` is an optional storage capability. Check the active
driver's `storage_describe` output before using it. The presence of a helper
function does not advertise support. The explicit machine interface refuses
unsupported drivers; compatible inbox adapters report a warning before using
their legacy behavior. JSONL does not currently implement this capability.

This document describes the SQLite implementation and the cooperating delivery
routes. It does not promise exactly-once processing by an external agent.

## Reservation and read state

A claim reserves a message for one `(store, team, recipient)` and returns a
fresh token. The message stays unread. Another cooperating consumer cannot
claim the same message while that reservation is live. The owner string is
diagnostic metadata; changing it does not grant permission to use a token.

Renew the exact token and message IDs immediately before handing off a body.
ACK only after the route's acceptance boundary. ACK validates every supplied
member before recording exact read events, updating the existing read cursor
through its covered prefix, and releasing the acknowledged claims in one
transaction. It also updates the corresponding legacy read markers. A later
message cannot advance the cursor over an earlier unread message.

Release a reservation when delivery was definitely not attempted or was
definitively rejected. A timeout, interrupted write, disconnect, or malformed
response can leave acceptance unknown. Keep that reservation until expiry;
retrying later can duplicate an external effect that already happened.
Suspending a process beyond its lease can also permit another consumer to
claim its messages. Receiver-side deduplication is needed for stronger external
processing guarantees.

The driver stores an ACK receipt for 24 hours after acknowledgement. Retrying
ACK with the same token and IDs succeeds while the receipt remains valid,
including after the original lease would have expired. A read marker alone
does not authorize an ACK retry. Generic callers may ACK part of their batch;
the remaining members stay reserved.

Claims, receipts, and maintenance barriers are local coordination state. They
are not synchronized to remote stores. Existing read events remain part of
the ordinary read-state synchronization contract.

## Machine interface

Run `bash scripts/delivery-claims.sh OPERATION`, write exactly one JSON object
to stdin, and close stdin. Do not construct a shell command from message data.

| Operation | Required fields | Optional fields | Standard output |
| --- | --- | --- | --- |
| `claim` | `team`, `agent`, `owner` | `ttl`, `limit`, `ids`, `max_bytes` | Message records, one JSON object per line |
| `renew` | `team`, `agent`, `owner`, `token`, `ids` | `ttl` | `ok` or `runtime_error` |
| `ack` | `team`, `agent`, `owner`, `token`, `ids` | None | `ok` or `runtime_error` |
| `release` | `team`, `agent`, `owner`, `token`, `ids` | None | `ok` or `runtime_error` |
| `peek` | `team`, `agent` | `limit`, `max_bytes` | Available message records without consuming them |

`ttl` is an integer from 1 through 3600 seconds, defaulting to 60. `limit` is
an integer from 1 through 1000, defaulting to 100. `ids` is an array of unique,
nonempty opaque strings. With `claim`, an explicit ID set is all-or-none and
is not truncated by `limit`. Other mutating operations require a nonempty set.
Keep quotes, Unicode, whitespace, and trailing linefeeds in IDs unchanged.
NUL, invalid UTF-8, unpaired Unicode surrogates, duplicate or unknown object
keys, invalid types, and additional JSON values are rejected.

Claim records contain the normal message fields plus `claim_token`, a
64-character lowercase hexadecimal token, and `claim_expires_at`, Unix seconds
according to the store clock. An empty successful claim produces no records.
Records are returned only after commit and admission checks. If acquisition
fails or its response is lost, a claim may already exist without a disclosed
token. Let that claim expire; do not invent a token or infer authority from
the owner label.

Control success is exit status 0 with one `ok` line. Validation, capability,
admission, and storage errors are nonzero, normally 13; details go to stderr.
Record operations never mix status words into JSON output. A stdout failure
may return a different nonzero status after a database transaction committed.
For an uncertain ACK response, retry only the same token and ID set.

`peek` excludes live claims and valid durable bridge reservations. It is a
readiness snapshot, not permission to deliver. Malformed or ambiguous bridge
state is an error. Ordinary unread and history queries continue to show the
actual read state, including unread messages held by a claim.

## Optional byte-bounded records

The separate `delivery-claims-bytes-v1` capability enables `max_bytes` for
`claim` and `peek`. It requires `delivery-claims-v1`. A driver supporting only
the original capability must refuse this extension explicitly. The storage
entry points are `storage_claim_unread_bounded TEAM AGENT OWNER TTL LIMIT BYTES`
and `storage_list_deliverable_bounded TEAM AGENT LIMIT BYTES`; the original
claim signature retains its exact-ID tail unchanged.

`max_bytes` is an integer from 4096 through 1048576. It cannot be combined with
`ids`, including an empty array. In bounded mode `limit` defaults to 32 and
must be from 1 through 32. The byte limit covers the whole successful JSONL
response, including every terminating linefeed and any terminal status record.

A response may end with exactly one `{"type":"delivery_oversized"}` object.
It means at least one available unread record cannot fit individually. It
contains no message ID, body, or token and must never enter an ACK/release set.
The implementation always reserves this status object's encoded size, so an
individual record's eligibility does not change when its neighbors change.

Individually oversized messages stay unread and unclaimed. Later fitting
messages may progress. Among fitting messages, select an ordered prefix up to
the count and cumulative byte limits; a fitting record deferred by the
cumulative limit is not oversized. `peek` uses the claimed-record size for
admission but returns ordinary messages without claim tokens. It cannot grant
a reservation. The bound limits returned payload size, not database scan time
or arbitrary host resource usage.

Codex inline delivery uses a 1 MiB claim budget and checks the complete turn
prompt against a 2 MiB cap before attempting the write. A locally oversized
prompt releases its not-yet-sent batch and fails visibly. Oversized-only
readiness reports a distinct notification once per bridge process and then
continues ordinary polling; it never starts an empty turn. Metadata-only
notification mode does not use the body-size filter. Oversized messages remain
available through explicit inbox/history access.

## Acceptance boundaries

| Route | When read state can advance |
| --- | --- |
| `inbox.sh` | After its output write succeeds |
| Stop hook | After the prepared hook response is written |
| Generic `watch.sh` body | After output succeeds and ownership is rechecked |
| Codex inline body | After a matching `turn/start` response confirms a valid accepted turn |
| Antigravity stream / TUI | Through the existing protected, complete-batch acknowledgement protocol |
| Notifications, history, PostToolUse readiness | These do not consume message bodies |

A successful stdout write does not prove that a human or model read the
message. A Codex turn acceptance does not prove task completion. Watcher
control acknowledgement does not prove that subsequent process teardown
completed. Detached external-tool execution has its own lifecycle and is not
made durable by an inbox ACK.

Codex distinguishes a matched, definite rejection from an unknown outcome.
Its watchdog and idle notifications do not ACK a body. Once a turn has been
accepted, ACK recovery reuses the same reservation instead of starting another
turn solely to retry acknowledgement.

## Maintenance and protected bridges

Cooperating rename, migration, and deletion operations establish persistent
admission barriers and refuse live claims before changing a store or its
selector. Resume uses the original operation descriptor. Barriers do not
expire automatically; inspect an interrupted operation before recovery.
Every mutating maintenance transaction also checks the exact descriptor,
token, and team membership before writing. Retired SQL cannot act on a
replacement team after recovery finishes.

Recovery fingerprints use the SQLite CLI's SHA3-256 over exact file bytes,
with an explicit `sha3-256:` prefix. Maintenance checks a known input before
taking a recovery lock and before hashing. A CLI without working `sha3()` is
refused; external SHA-256 tools remain an E2EE prerequisite only. Missing,
unreadable, and empty files are distinguished, and an unknown fingerprint
format cannot be adopted as a recovery operation.

SQLite maintenance opts into manual recovery of its registry locks. Success
explicitly releases them. An implicit exit, INT, TERM, or killed wrapper keeps
them: a descendant may still be writing even though the recorded parent is
absent. Before removing the exact operation's lock directory and holder file,
an operator must verify that the holder and all descendants have stopped, then
rerun the identical operation. Do not infer safety from a dead parent PID
alone or clear a database barrier by hand. Even some early failures retain the
lock conservatively; ordinary registry writers retain their existing cleanup.

These barriers do not make ordinary sends, synchronization, or manual file
edits globally atomic with maintenance.

Antigravity keeps its durable delivery state and authenticated private
transport. A protected claim or ACK receipt cannot be mutated through the
generic interface, even after its role-state file has been removed. During
bridge takeover, existing generic owners may ACK or release, but cannot renew
or acquire more work. The bridge waits for them to drain before taking its
protected batch. Unknown delivery state requires the existing explicit
recovery procedure.

Compatibility consumers process at most 1000 messages per team per invocation
or poll. Remaining backlog stays unread for later calls. Watch claims groups
of at most 32 messages. An uncertain group write retains the whole attempted
group; control-containing groups are handled in order under the same token,
and an unattempted suffix can be released separately. Other storage drivers
can retain the legacy interface without claiming reservation guarantees.

Protected SQLite receive keeps the existing 20-record/64 KiB body prefix and
also limits complete encoded records, including fences and linefeeds, to 1 MiB.
An oversized first record is refused without claiming; an oversized later
record ends the prefix. Recovery preserves the exact original set and refuses
saved input or the complete response beyond 4 MiB before replacing claims.
Old state exceeding these bounds remains intact and requires operator review.

Storage drivers and installed transport scripts are trusted implementation
components. Validation checks their result framing and protocol invariants;
it does not authenticate arbitrary replacement code against a second database
read. Persistent message data remains untrusted content.
