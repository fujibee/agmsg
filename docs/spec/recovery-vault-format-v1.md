# agmsg `recovery-vault-format-v1`

**Status:** draft, for mentor-cc/co1 review — NOT final. Two items are
explicitly marked OPEN below and must resolve before this status can change.

**Profile identifier:** `recovery-vault-format-v1`
**Envelope version:** `1`

This document pins the wire format of the agmsg Recovery Vault: a
server-stored, server-blind bundle of a user's local team keys, recoverable
on a fresh device via a `recovery-key-v1` key
([`recovery-key.py`](../../scripts/internal/recovery-key.py)) or opened
automatically on an already-provisioned device via a device-local wrap. It
follows the same envelope discipline as
[`age-v1-profile.md`](age-v1-profile.md) and reuses its **authenticated
binding context** technique rather than inventing a new one: age provides no
external-AAD API, so binding fields are placed in the authenticated plaintext
and independently reconstructed and compared by the reader after decryption.

## Why this exists, and what it does not do

The vault is a convenience for machine loss. It is never on the hot path —
message send/receive uses local team-key files (0600) directly and never
touches the vault or the VDK. The recovery key does not encrypt messages; it
only opens the vault, which holds the team keys. See
[[recovery-vault-key-hierarchy]] for the full layer diagram and prior-art
comparison (LUKS/KMS/age/1Password all use the same envelope/KEK-DEK shape).

## Layer structure

```
bundle (all local teams, all key epochs — the actual backup payload)
  ^ encrypted with the VDK, treated as an age X25519 identity
VDK identity material
  ^ wrapped once per slot: recovery-key slot, device-local slot, (future:
    enterprise escrow) — each slot is a SEPARATE small age file, never
    multiple recipients folded into one age file
vault blob (opaque, padded) -> PUT to the vault service, server-blind
```

Two encryption operations, not one: the **bundle seal** (VDK -> bundle) and
each **slot wrap** (slot secret -> VDK identity material) are independent age
files with independent binding contexts. A reader unseals in two steps:
resolve one slot to recover the VDK identity, then use that identity to open
the bundle.

## Outer vault record

```json
{
  "v": 1,
  "format": "recovery-vault-format-v1",
  "vault_id": "<uuidv4>",
  "account_id": "<opaque account identifier, server-assigned>",
  "vault_service_id": "<uuidv4, identifies the vault service instance this record was sealed against>",
  "bundle": "<base64 of one complete, unarmored, binary age v1 file>",
  "vdk_wraps": [
    {
      "slot_id": "<uuidv4>",
      "slot_type": "recovery_key" | "device_local",
      "wrap_profile": "age-x25519-v1",
      "kdf_profile": "hkdf-sha256-v1" | null,
      "kdf_params": { "...": "..." } | null,
      "salt": "<base64, present iff kdf_profile requires one>" | null,
      "wrapped_vdk": "<base64 of one complete, unarmored, binary age v1 file>",
      "created_generation": 1
    }
  ]
}
```

- `vdk_wraps` MUST be a list, never a single `wrapped_vdk` field — this is
  the load-bearing reason the field exists in this shape at all (koit
  2026-07-25: v1 does not implement reissue, but v1 MUST guarantee reissue
  stays possible without a breaking format change; see
  [[recovery-vault-key-hierarchy]] point 1). A `slot_type` MAY repeat in
  principle (e.g. two device-local slots for two machines) but `recovery_key`
  slots SHOULD number exactly one per `created_generation` — enforced by the
  writer, not by this schema.
- `kdf_profile`/`kdf_params`/`salt` are `null` for a `device_local` slot
  (the device KEK is used directly, no password-like secret to stretch) and
  non-null for a `recovery_key` slot.
- `created_generation` is the recovery-key generation this slot was created
  under (see reissue semantics below); it is NOT a per-slot version — every
  slot alive after a reissue that generated a fresh VDK shares the new
  generation number.
- The server validates only this outer record's shape (field presence,
  types, size bounds) and treats `bundle` and each `wrapped_vdk` as opaque,
  exactly as the HTTP v1 server treats an `age-v1` blob.

### `account_id` / `vault_id` / `vault_service_id` — why three identifiers

Mirrors the existing `server_instance_id`/`remote_team_id` anti-confusion
pattern already used by `remote.sh`'s ADR 0007 binding (a client must not
silently accept ciphertext produced under a different server's identity).
Here:

- `account_id`: which user account this vault belongs to.
- `vault_id`: which vault (a user has exactly one recovery vault per
  account today, but the identifier is independent from day one so a future
  multi-vault case is additive, not a breaking rename).
- `vault_service_id`: which vault-service deployment sealed this record —
  deliberately analogous to `server_instance_id`, and deliberately NOT the
  same field, so a vault sealed against one deployment can be told apart
  from one sealed against another even if `account_id`/`vault_id` collide
  across deployments (e.g. staging vs. production, or a future self-hosted
  vault service).

`server_instance_id` (the *messaging* server identity, already defined by
ADR 0007) is data-plane identity and is deliberately kept OUT of this outer
binding context — see "Inner binding context" below for where it belongs.
Putting it in the outer context would mean a data-plane server migration
alone (independent of any actual vault compromise or account event) could
make an otherwise-valid vault permanently un-unsealable.

## Plaintext frame (both the bundle age file and every wrap age file)

Same discipline as `age-v1-profile.md` §"Plaintext frame": one binary
plaintext frame, unsigned big-endian integers, no omitted field, no trailing
byte.

```text
offset  width       value
0       16          magic (see below, differs for bundle vs. wrap)
16      4           context_length (u32)
20      variable    canonical authenticated binding context
...     4           payload_length (u32)
...     variable    canonical payload bytes
```

Two magics distinguish the two frame kinds so a bundle file can never be
mistaken for a wrap file (or vice versa) even if both happen to decrypt
successfully under a key that shouldn't apply to that role:

- bundle frame magic: ASCII `agmsg-vault-bundle-v1` + zero-pad to 16 bytes.
- wrap frame magic: ASCII `agmsg-vault-wrap-v1` + zero-pad to 16 bytes.

### Outer binding context (bundle frame)

```text
width       value
4           protocol_version (u32, MUST equal 1)
16          account_id (RFC 9562 UUID bytes in network order)
16          vault_id (RFC 9562 UUID bytes in network order)
16          vault_service_id (RFC 9562 UUID bytes in network order)
2           format_length (u16, MUST equal 25)
25          format UTF-8 bytes (ASCII "recovery-vault-format-v1")
```

### Inner binding context (per-team-entry, inside the bundle's payload)

The bundle payload is not flat key material — it is itself a canonical
structure, one entry per (team, epoch), each entry individually bound so a
malicious/corrupted vault service cannot splice an entry from one team's
history into another's:

```text
width       value
16          server_instance_id (RFC 9562 UUID bytes in network order)
16          team_id (RFC 9562 UUID bytes in network order, = remote_team_id)
2           key_id_length (u16, 1..64)
variable    key_id ASCII bytes
2           identity_length (u16)
variable    native age identity file bytes (see age-v1-profile.md's
            "native identity file" rule — exactly one AGE-SECRET-KEY-1...
            identity, no passphrase-encrypted or plugin identity)
```

Exact canonical encoding of the entry list (JCS-of-array-of-objects vs. this
fixed binary layout) is an OPEN drafting detail, not yet pinned — flagging
here rather than guessing, since getting the bundle payload's own framing
wrong is exactly the kind of hard-to-reverse mistake this document exists to
avoid. Candidate: RFC 8785 JCS array, same choice `age-v1-profile.md` made
for its message bytes, for auditability with a plain JSON viewer after
manual `age --decrypt`.

### Wrap binding context (wrap frame)

```text
width       value
4           protocol_version (u32, MUST equal 1)
16          vault_id (RFC 9562 UUID bytes in network order)
16          slot_id (RFC 9562 UUID bytes in network order)
1           slot_type_tag (u8: 1 = recovery_key, 2 = device_local)
4           created_generation (u32)
```

`wrapped_vdk`'s payload bytes are the VDK's native age identity file (same
"exactly one identity, no passphrase/plugin" rule as above) — i.e. a wrap
age file's plaintext, once decrypted and binding-verified, IS the VDK
identity used to decrypt the bundle. There is no separate "VDK format";
the VDK's only representation is a native age identity.

## Recipient derivation per slot type

- **`device_local`**: recipient = a per-device X25519 keypair. The private
  half lives in the OS secure store (Keychain/Credential Manager/Secret
  Service), never in the vault record, never in config/argv/env/logs/temp
  files. Device slots deliberately stay off the vault service entirely (not
  even as a wrap slot referencing an opaque device ID) — see
  [[recovery-vault-key-hierarchy]]: putting them in the server-visible
  record would let the server count how many devices a user has. **No
  biometric / user-presence requirement on this key** (koit ruling): the
  vault reseals on every team-add/key-rotation, and prompting each time
  would mean "Touch ID every time you create a team." Reserve biometry for
  rare explicit actions like displaying the recovery key.
- **`recovery_key`**: recipient = an X25519 identity deterministically
  derived from the `recovery-key-v1` secret via `kdf_profile`. mentor-cc
  2026-07-25 (their own judgement, not yet co-reviewed — see OPEN item
  below): `hkdf-sha256-v1`, i.e. plain `HKDF-SHA256(ikm=recovery key secret,
  info=<domain string, TBD>)` truncated/expanded to an X25519 scalar, with
  no memory-hard step. Rationale: memory-hard KDFs (Argon2id/scrypt) exist
  to slow brute-force against a *low-entropy, human-chosen* secret; the
  input here is already a 120-bit CSPRNG output, against which brute-force
  is infeasible regardless of KDF cost, so the memory-hardness buys nothing
  and only adds implementation surface. This directly supersedes an earlier
  Argon2id pin from co and MUST get an explicit co verdict before it can be
  treated as settled — until then this profile's `kdf_profile` field is
  deliberately free to hold either value across recovery-key slots created
  at different times, which the versioned-list structure already supports
  without a breaking change either way.
- `age -p` (passphrase/scrypt) recipients are explicitly NOT used anywhere
  in this profile: they cannot coexist with other recipients in one age
  file (moot here since every slot is already its own file, but still
  disqualifying on its own) and are designed for interactive TTY entry,
  which this profile's headless/backgrounded reseal flow cannot rely on
  (see "Seal once, retry the network only" below). Every slot in this
  profile is a standard non-interactive X25519 age recipient/identity, full
  stop.

## Reissue semantics (not implemented in v1; MUST remain possible)

Per koit's decision, recorded in [[recovery-vault-key-hierarchy]]:
reissuing the recovery key MUST generate a **fresh VDK** and re-encrypt the
bundle under it (`created_generation` increments, a new `recovery_key` slot
wraps the new VDK, old slots referencing the old VDK become unable to open
the new bundle). Reusing the same VDK and only re-wrapping it (the cheaper
alternative) is explicitly rejected: it cannot cut off a leaked recovery
key, since the old key would still open an old bundle revision that itself
contains the (unchanged) VDK, which also opens the new revision. This
document does not yet specify the reissue procedure itself (v1 ships
without it) but the four format-level guarantees koit pinned to keep it
retrofittable later are all satisfied by the shapes above:

1. Room for multiple wrappings — `vdk_wraps` is a list. ✅.
2. KDF parameters recorded in the blob — in the wrap slot's own header
   (`kdf_profile`/`kdf_params`/`salt`), never inside the VDK-encrypted
   interior (that would be circular: you need the params before you can
   unwrap). ✅.
3. Previous vault revisions retained server-side (retention/admission
   policy below) — this is the one guarantee this document cannot itself
   satisfy; it is a vault-service (cloud-side) requirement. ⚠ tracked, not
   an OSS-format concern.
4. The server stores nothing derived from the recovery key — correct here:
   the server sees only `wrapped_vdk` ciphertext and the wrap slot's public
   header fields, never anything derived from the recovery-key secret
   itself (no verification hash, no derived recipient stored separately
   from the age header it's already embedded in). ✅.

## Retention / admission (vault service, informative here)

Recorded for completeness since it interacts with the reissue guarantee
above; authoritative version and enforcement live in the vault service, not
this OSS-side format document:

- Retain a version if `committed_at >= now() - 365d` **OR** it is among the
  newest 20 (union, never "keep only latest N" — see
  [[recovery-vault-key-hierarchy]] for why a takeover attacker could
  otherwise push out the legitimate version with overwrites).
- Max 10 successful new versions per rolling 24h; per-account 1 GiB
  retained-ciphertext quota; rolling-24h 64 MiB ingress budget. Over any
  limit: reject, alert, never silently delete history.

## Seal once, retry the network only

Same correctness requirement as `age-v1-profile.md`'s durable-retry rule,
restated for the vault: the local outbox persists the **sealed** bundle
ciphertext (and sealed wrap files) and retries only the PUT. It MUST NOT
hold a pending marker and re-seal on each retry. Re-sealing changes the
age STREAM nonce, which changes the ciphertext, which changes the request
fingerprint an idempotent-retry check depends on — an ordinary network
retry would then 409 instead of converging on the already-stored result.
Side benefit: the OS key store (for the `device_local` slot) is touched
exactly once per actual key change, not once per retry, so flaky
connectivity cannot multiply into repeated Keychain/Credential
Manager/Secret Service ACL prompts (see OPEN item below). Multiple local
changes that pile up while offline MAY be coalesced into one seal (with a
fresh `created_generation`-scoped operation), but an already-sealed,
not-yet-acknowledged operation is never re-sealed.

## Failure states

Mirrors `age-v1-profile.md`'s table; `slot` below means "the slot currently
being tried," not the whole record:

| Condition | Durable state |
|---|---|
| `vault_service_id` in the record differs from the effective one | `policy_violation` — do not attempt any slot |
| Recovery key check-digit fails (`recovery-key-v1` parse) | rejected before this format is ever touched |
| No usable slot present for the available secret (e.g. no `device_local` slot on this device, no recovery key supplied) | `pending_key` |
| Slot age-decryption fails with the derived/loaded identity | `authentication_failed` for that slot only — a reader MUST try the next candidate slot rather than aborting the whole record |
| Wrap frame/context truncated, reordered, or mismatched vs. trusted `(vault_id, slot_id, slot_type, created_generation)` | `authentication_failed` |
| Wrap succeeds but the recovered VDK identity fails to open `bundle` | `authentication_failed` at the bundle layer — durable, MUST NOT retry other slots (they all wrap the same VDK for one `created_generation`; a bundle-layer failure indicates record corruption or a generation mismatch between `bundle` and every current slot, not a wrong slot choice) |
| Bundle opens, but an inner team entry's binding context mismatches | `authentication_failed` for that entry only; other entries MAY still project |
| `format` field is not `recovery-vault-format-v1` or `v` is not `1` | `unsupported_cipher` |

## OPEN items (block "final" status)

1. **KDF choice for `recovery_key` slots**: `hkdf-sha256-v1` is
   mentor-cc's own proposal, explicitly not yet co-reviewed, and explicitly
   overturns an earlier Argon2id pin. Needs a co verdict.
2. **Device-local OS keystore behavior**: needs hands-on verification
   (macOS `security` CLI ACL-prompt behavior under repeated non-interactive
   invocation and whether `-T` trusted-app pinning suppresses it; Linux
   secret-service absence handling — must fail explicit
   unsupported/locked, never silently fall back to plaintext; Windows
   DPAPI equivalent). Tracked as its own task; blocks the `device_local`
   slot implementation, not the `recovery_key` slot or the bundle format
   itself.
3. **Bundle payload canonical encoding** (JCS array vs. fixed binary
   layout for the inner team-entry list) — flagged inline above, not yet
   decided.
