# agmsg `age-v1` cipher profile

**Status:** proposed (dogfood profile)
**Profile identifier:** `age-v1`
**Envelope version:** `1`

This document pins the first encrypted envelope profile for the agmsg remote
sync protocol. It extends the opaque envelope in
[`server/spec/v1.md`](../../../server/spec/v1.md) without changing the HTTP message
schema or the Stage-1 storage-driver durability boundary.

`age-v1` is a standard binary [age v1 file][age-format], encrypted to native
X25519 age recipients. It deliberately does not define another AEAD layer or a
private age-file variant. This keeps recovery, debugging, and independent audit
possible with the standard `age` CLI and conforming age libraries.

The term **authenticated binding context** is used throughout this profile.
Age's STREAM payload construction provides ciphertext integrity. After
successful age decryption, the reader compares the authenticated plaintext
context with independently trusted envelope and stream metadata. This is not an
age API for external AEAD additional authenticated data, and this profile MUST
NOT describe it as such.

## Fixed identifier and compatibility rule

The meaning of `age-v1` is immutable. An implementation MUST NOT change its
recipient type, binary age-file requirement, plaintext framing, context fields,
canonical encodings, comparison rules, or failure classifications while using
this identifier. An incompatible change requires a new identifier, beginning
with `age-v2`.

Readers either implement this document exactly or treat `age-v1` as
`unsupported_cipher`. There is no profile-content negotiation under the
`age-v1` identifier.

## Outer envelope

An `age-v1` envelope has:

```json
{
  "v": 1,
  "cipher": "age-v1",
  "key_id": "epoch-2026-07-01",
  "blob": "YWdlLWVuY3J5cHRpb24ub3JnL3YxLi4u"
}
```

- `v` MUST be the JSON integer `1`.
- `cipher` MUST be the exact ASCII string `age-v1`.
- `key_id` MUST be a non-null string satisfying the HTTP v1 envelope rules. In
  addition, this profile restricts it to 1–64 ASCII bytes matching
  `[a-z0-9][a-z0-9._-]{0,63}`. It names one immutable recipient-set epoch within
  one stream binding.
- `blob` MUST be canonical padded RFC 4648 base64 of one complete, unarmored,
  binary age v1 file. ASCII armor, concatenated age files, trailing bytes,
  compression, and profile-level padding are forbidden.
- The age header MUST contain one or more native X25519 recipient stanzas.
  Writers MUST use the epoch's X25519 manifest as their only real recipient
  set. Readers MUST ignore only age GREASE stanzas whose tag and arguments
  match the bounded grammar below. GREASE stanzas do not satisfy or weaken the
  X25519 manifest check and MUST NOT trigger plugin, passphrase, SSH, or
  trial-decrypt dispatch. Scrypt, SSH, plugin, and every other non-X25519 stanza
  type are rejected before invoking the age decryptor. Here, "ignore" means
  exclude the stanza from decryption dispatch while retaining its authenticated
  bytes in the complete age header; it does not mean deleting bytes.
- A GREASE stanza tag MUST match `[!-~]{1,8}-grease`. It has zero to four
  arguments, each 1–8 bytes of ASCII VCHAR (`0x21`–`0x7e`), and a 0–100-byte
  body in age's canonical unpadded-base64 wrapping. These are the bounds emitted
  by `age_core::format::grease_the_joint` in Rust `age` 0.12.1. Active age
  namespaces take precedence over that suffix grammar: `scrypt`, `ssh-rsa`,
  `ssh-ed25519`, and every `plugin-` tag are always rejected. Consequently, the
  profile accepts a bounded safe subset of Rust-generated GREASE; a random tag
  that collides with an active namespace is rejected. A stanza outside this
  safe grammar is not treated as GREASE and is rejected.
- A header may contain at most 256 X25519 stanzas, 512 total stanzas, and 65536
  bytes through the terminating header MAC line. Each header line remains
  limited to 4096 bytes. A reader MUST reject the file before decryption when
  any bound is exceeded, when a stanza has no body, or when the header framing
  is malformed.

The decoded age file must fit the smaller of the HTTP protocol blob limit and
the authenticated `max_blob_bytes` capability. The server validates only the
outer envelope and continues to treat the decoded age file as opaque.

## Recipient-set epochs

A `key_id` identifies an immutable set of X25519 recipients and its private
identity material. Changing the recipient set, rotating any identity, or
reusing the label with different key material requires a new `key_id`. A
recipient-set manifest MUST bind the remote `server_instance_id`, `team_id`,
`key_id`, recipient list, and profile identifier and MUST be distributed over
an authenticated out-of-band channel. The server never receives private
identities. A writer MUST encrypt each new envelope to every recipient in the
selected immutable manifest and to no real recipient outside it. The manifest
MUST contain 1–256 distinct recipients; the age header contains exactly one
X25519 stanza for each, in addition to any ignored extension/GREASE stanzas.
Age intentionally hides recipient identity, so a recipient
cannot prove from a ciphertext that the writer included the complete manifest
or excluded an outsider. This is a writer-side obligation. A malicious writer
already holds plaintext and is outside the confidentiality boundary; conforming
implementations MUST still test and fail closed on accidental manifest drift.

### Epoch snapshots and rollback resistance

The manifest and complete key-epoch history are distributed as one
binding-scoped **epoch snapshot**. Each snapshot contains at least:

- `server_instance_id`, `team_id`, and profile identifier;
- a canonical decimal, strictly increasing `epoch_revision`;
- a canonical decimal, strictly increasing `writer_generation`;
- the complete authorized writer roster for that generation;
- the complete effective key-epoch history and referenced recipient manifests;
- `previous_snapshot_sha256`, which is null only for revision `0` and otherwise
  is the lowercase SHA-256 digest of the preceding snapshot's RFC 8785 JCS
  bytes.

The snapshot itself is encoded as RFC 8785 JCS. Its SHA-256 digest and revision
form the trusted checkpoint. Distribution MUST provide both authenticity and
freshness; transport authentication alone is insufficient because a valid old
snapshot can be replayed. An already-provisioned client durably retains its
greatest accepted `(epoch_revision, snapshot_sha256, writer_generation)` and
rejects a lower revision, a same-revision different digest, a broken hash
chain, or a lower writer generation.

The **epoch authority** is an operator-selected management trust root whose
identity is pinned independently of the message server and snapshot payload.
A live freshness confirmation is either a nonce-bound response from that
authority or a human verification of the current revision and digest over a
separate live channel. A cached response bundled with the snapshot is not a
freshness proof. If the authority is unavailable or the confirmation cannot be
verified, writes remain disabled.

A new or reset device MUST obtain the current trusted checkpoint through a live
epoch authority or an explicit operator confirmation made at provisioning
time. An archived snapshot, a valid authenticated download without freshness
proof, or the message server's current cipher policy alone MUST NOT enable
writes. Until the device possesses the complete chain through the confirmed
checkpoint, it remains write-disabled. It may continue transport quarantine,
but messages beyond its verified history coverage remain unprojected. Resetting
local sync state MUST NOT silently reset the retained anti-rollback checkpoint.
At most 4096 epoch snapshots may exist in one binding chain; a mutation that
would exceed this limit MUST fail atomically. A future profile or management
contract may define authority-confirmed prefix compaction, but `age-v1` clients
MUST NOT invent or silently compact a chain.

Each client binding maintains an append-only, sequence-effective key-epoch
history alongside the local security history. Each entry contains a local
epoch revision, `effective_from_seq`, `cipher`, and `key_id`. The first entry is
effective from sequence `1`. A prospective rotation uses an authenticated
capability snapshot's `next_sequence_boundary`, and a message at sequence `S`
uses the greatest revision whose `effective_from_seq <= S`. Same-boundary
changes collapse to the greatest revision. Clients MUST bound this history to
4096 effective entries and import established history when provisioning a new
device; they MUST NOT infer old epochs from the current key alone.

Before creating an encrypted envelope, the writer MUST verify that `age-v1` is
allowed by both the effective server write policy and effective local minimum,
and MUST select the `key_id` effective at the prospective sequence boundary.
On pull, an otherwise valid `age-v1` envelope with a `key_id` different from
the locally pinned epoch at its `server_seq` is a durable `policy_violation`.
It MUST NOT be trial-decrypted, projected, displayed, or marked read.

Rotation and revocation are prospective. Removing a recipient from a later
epoch does not revoke its ability to decrypt ciphertext from an earlier epoch.
Readers SHOULD retain authorized old identities while old messages or durable
quarantine may require them. A missing identity for the expected epoch produces
`pending_key`, not a fallback to `none` or another key.

### Multi-writer cutover protocol

The HTTP v1 server admits `cipher` but does not enforce `key_id`. Therefore a
client-local `next_sequence_boundary` update is not a safe epoch rotation. A
deployment using this profile MUST perform the following barrier across the
complete writer roster, or use a future authoritative server mechanism that
enforces the same sequence-effective key ID:

1. Announce the prospective rotation and quiesce every writer in the current
   authorized writer roster. Quiesced writers may accept local messages, but
   MUST NOT seal a new remote envelope. They may POST only an already-published
   envelope while completing the drain in step 2.
2. Every writer drains and reconciles all envelopes already published under the
   old epoch. An envelope with an unknown POST outcome is retried byte-for-byte
   until acknowledged. It MUST NOT be abandoned or re-encrypted. If any writer
   cannot reach zero outstanding old-epoch envelopes, the rotation aborts.
3. Every writer durably acknowledges the quiesced state and the current
   `epoch_revision`. The coordinator MUST account for the complete roster; a
   timeout or missing writer aborts rather than bypasses the barrier.
4. Fence the old `writer_generation` at the server authorization layer, for
   example by revoking its write credentials. A stale or paused process MUST be
   unable to POST after this point. Shared credentials that cannot distinguish
   or revoke the old generation are insufficient for safe rotation.
5. After the fence is effective, fetch a fresh authenticated capability
   snapshot. Commit the new epoch snapshot with
   `effective_from_seq = next_sequence_boundary`, the new immutable manifest,
   and a greater `writer_generation`. If the boundary is null, rotation fails.
6. Distribute the complete snapshot and new write authorization only to writers
   that verify the checkpoint and install the new epoch. Require durable
   acknowledgements before resuming any writer.
7. Resume writers. Every subsequently sealed envelope uses the new epoch.

This barrier ensures that no old-epoch envelope can receive the first sequence
of the new epoch and that a stale writer cannot disclose post-cutover plaintext
to a removed recipient. Rotation is fail-closed: loss of coordination leaves
writes paused but does not permit downgrade.

## Plaintext frame

Age encrypts exactly one binary plaintext frame. Integers are unsigned,
big-endian, and use the widths shown below. Lengths count bytes, not Unicode
scalar values. No field may be omitted and no trailing byte is allowed.

```text
offset  width       value
0       16          magic = 61 67 6d 73 67 2d 61 67 65 2d 76 31 00 00 00 00
16      4           context_length (u32)
20      variable    canonical authenticated binding context
...     4           message_length (u32)
...     variable    canonical message bytes
```

The 16-byte magic is ASCII `agmsg-age-v1` followed by four zero bytes.
`context_length` MUST equal the exact encoded context length.
`message_length` MUST equal the exact canonical-message length. The frame ends
immediately after the message bytes.

Readers MUST validate every declared length against the bytes remaining before
addition, slicing, or allocation. Integer addition MUST be overflow-safe;
untrusted lengths MUST NOT drive an allocation. The canonical context length is
47–110 bytes. A zero message length, a length exceeding the remaining frame,
or any byte after the declared message is rejected according to the failure
table below.

### Canonical authenticated binding context

The context fields occur once, in this exact order:

```text
width       value
4           protocol_version (u32, MUST equal 1)
16          team_id (RFC 9562 UUID bytes in network order)
16          wire_id (RFC 9562 UUID bytes in network order)
2           cipher_length (u16, MUST equal 6)
6           cipher UTF-8 bytes (ASCII `age-v1`)
2           key_id_length (u16, 1..64)
variable    key_id ASCII bytes
```

`team_id` is the stable remote team/stream ID from the verified HTTP binding,
not a mutable team name or local path. `wire_id` is the outer remote message
UUIDv4, not the local driver UUID. `key_id` and `cipher` are the exact outer
envelope values. The protocol version is the URL/envelope protocol version,
not an age implementation version.

For example, the context length for `key_id = "epoch-1"` is
`4 + 16 + 16 + 2 + 6 + 2 + 7 = 53` bytes.

### Canonical message bytes

The message bytes MUST be RFC 8785 JCS encoding of exactly the same four-field
plaintext object defined for `cipher: "none"` in the HTTP v1 specification:

```json
{"body":"Run the test suite","created_at":"2026-07-20T06:30:00.000000Z","from_agent":"leader","to_agent":"worker-1"}
```

All `none` plaintext validation rules still apply before encryption and after
decryption. The complete framed plaintext and resulting binary age file must
fit the authenticated server limit. Writers MUST check the final encrypted age
file size before durably reserving the envelope.

## Seal and durable retry

The writer performs these steps in order:

1. Select the effective `key_id` and exact recipient-set manifest.
2. Generate a candidate random wire UUIDv4 in private process state. At this
   point it is neither a published remote identity nor a durable reservation.
3. Construct the canonical context and canonical message bytes and encrypt the
   complete frame once as a binary age v1 file.
4. Base64-encode the complete age file canonically.
5. In one storage transaction, durably publish the wire ID and the complete
   exact outer envelope as one indivisible reservation before exposing either
   value to the HTTP engine, logs, export, or another process.

A crash before step 5 publishes nothing. Recovery generates a new private
candidate and may discard any uncommitted ciphertext because the prior wire ID
never became an observable remote identity. A storage design that persists
pre-publication work MUST persist the complete wire ID and exact envelope
atomically; a durable wire-only or `sealing` state is forbidden. Concurrent
sealers for one local message may do redundant work, but only the transaction
winner becomes visible and all callers subsequently emit that winner.

The Stage-1 H1 rule is absolute: every retry, reconciliation attempt, crash
recovery, export, and compaction replay for that wire ID MUST reuse the exact
`v`, `cipher`, `key_id`, and `blob`. A client MUST NOT re-encrypt or re-encode
the same published wire ID, even to the same recipients. A regression test MUST
terminate sealing after ciphertext creation but before atomic publication and
prove that restart neither exposes nor re-encrypts the abandoned private
candidate wire ID.

## Open, binding verification, and failure states

The reader evaluates server policy, local security history, and key-epoch
history before decryption. If policy permits processing and the expected
identity is available, it decrypts the single age file and then:

1. parses the complete frame with overflow-safe length checks;
2. independently reconstructs the expected canonical context from the verified
   `(protocol_version, team_id)`, outer wire ID, outer cipher, and outer
   `key_id`;
3. checks exact context length and compares the complete received context with
   the expected context in constant time;
4. only after a successful comparison, parses and validates the JCS message.

The comparison MUST cover every context byte and MUST NOT stop at the first
difference. After separately requiring equal public lengths, an implementation
MUST use a constant-time equality primitive directly over the two complete
context byte strings. Comparing only hashes, individual fields, or a prefix is
insufficient. Implementations MUST NOT project any message field before this
comparison succeeds.

Failures map to the Stage-1 durable quarantine layer as follows:

| Condition | Durable state |
|---|---|
| Effective policy rejects `age-v1` or the sequence-effective `key_id` differs | `policy_violation` |
| Expected identity is not installed | `pending_key` |
| Age decryption fails with the selected identity | `authentication_failed` |
| Frame/context is truncated, reordered, duplicated, has trailing bytes, or differs from trusted binding metadata | `authentication_failed` |
| Context matches, but the canonical message is invalid | `malformed` |
| Cipher profile is not implemented | `unsupported_cipher` |

`authentication_failed` MUST remain durable for operator inspection and later
reprocessing. It MUST NOT fall back to another identity, `none`, partial
display, local import, or read-state advancement. The transport cursor may
advance only after that blocking outcome is durably quarantined, as specified
by the HTTP v1 three-layer state model.

## Key bootstrap and operational limits

- Recipient public keys, private identities, recipient-set manifests, and epoch
  history are provisioned outside the message server over an authenticated,
  freshness-proving channel. Copying only the current private key is
  insufficient for history or rollback resistance.
- A headless sync process MUST use explicit identity files or an equivalent
  non-interactive secret provider. Interactive passphrases and trial-decrypting
  every installed key are forbidden.
- A native identity file for this profile contains exactly one uppercase
  `AGE-SECRET-KEY-1...` X25519 identity. Empty lines and lines beginning with
  `#` are permitted; surrounding whitespace, multiple identities,
  passphrase-encrypted identities, and `AGE-PLUGIN-...` identities are
  forbidden. Before enabling a configured key epoch, the client MUST derive
  the corresponding public recipient and require it to appear in that epoch's
  immutable manifest.
- Identity files MUST be kept outside remote storage, excluded from logs and
  protected with platform-appropriate file permissions. The reference client
  validates the exact native identity bytes and passes those same bytes to age
  over a private pipe, preventing a path substitution between validation and
  open. HTTP bearer credentials and age identities are separate secrets.
- The profile does not define padding. Team relationship, key epoch, age-file
  length, approximate recipient count and rotation pattern, server arrival
  time, traffic frequency, and sequence remain visible. A `key_id` is public
  metadata and MUST NOT contain a customer name, incident label, timestamp, or
  other sensitive description.
- Because the server cannot read the plaintext, routing, search, and wake remain
  team-wide; recipient projection happens locally after verified decryption.

For manual recovery, first decode the outer base64 to an unarmored age file,
then use a standard CLI without placing identity material itself on argv:

```sh
age --decrypt --identity "$IDENTITY_FILE" message.age > message.frame
```

`message.frame` is the binary frame defined above, not directly printable JSON;
it still requires a conforming frame/context verifier before the message may be
trusted or displayed. Implementations SHOULD include this CLI round trip in
their contract tests.

## Shared conformance vectors

[`age-v1-vectors.json`](vectors/age-v1-vectors.json) is normative test material
for client, driver, and hosted-server integration suites. Its identities are
public test secrets and MUST NEVER be used outside tests. A conforming reader
must cover at least:

1. successful decryption and exact context/message recovery;
2. decryption with the wrong team's identity;
3. same-key trusted team-ID and wire-ID substitution;
4. protocol-version and cipher substitution, plus key-ID substitution both at
   the pre-decrypt epoch-policy gate and after an explicitly matching trusted
   epoch passes that gate;
5. an authenticated plaintext with a truncated or reordered context;
6. zero or overflowing declared lengths and trailing plaintext bytes;
7. duplicate/unknown JCS keys and an otherwise non-canonical message.

Each negative case MUST produce the state recorded in the manifest and MUST NOT
yield a projection. Binding/frame failures are `authentication_failed`;
unsupported profile dispatch is `unsupported_cipher`; a context-valid but
invalid canonical message is `malformed`; an outer key ID that differs from the
sequence-effective trusted epoch is `policy_violation` before decryption. In
the manifest, `envelope_from` means reuse the named vector's envelope
byte-for-byte, `envelope_override` mutates trusted outer metadata,
`binding_override` changes the independently trusted stream binding,
`trusted_epoch_key_id` supplies the sequence-effective epoch policy, and
`identity` selects the named public test identity. The manifest records the
generating age implementation, SHA-256 of every decoded age file and decrypted
frame, and exact expected states. The accompanying verifier independently
checks that provenance and every attack.

[`vectors/age-v1-rust-grease.json`](vectors/age-v1-rust-grease.json) is the
cross-implementation fixture produced by the Rust `age` crate 0.12.1. It pins a
valid header containing one X25519 stanza and one GREASE stanza and MUST decrypt
to the same canonical frame as the primary vector.

Regenerate the randomized ciphertext fixtures with
[`generate-age-v1-vectors.mjs`](vectors/generate-age-v1-vectors.mjs) and verify
the committed fixtures with
[`verify-age-v1-vectors.mjs`](vectors/verify-age-v1-vectors.mjs). Set `AGE_BIN`
when the desired standard `age` executable is not on `PATH`.

[age-format]: https://age-encryption.org/v1
