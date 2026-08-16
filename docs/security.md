# Security properties of agmsg remote sync

This document states what the remote-sync protocol protects, what it does not,
and what has not been examined. It follows the structure RFC 3552 (BCP 72) asks
for, because that structure forces the second and third of those to be written
down rather than implied.

It is written for a reviewer who intends to check it. **The central claims — what
is protected, what is not, and why — carry a `file:line` in this repository.**
Some rows of the properties table are summaries and carry no citation; where a
row rests on something other than this tree, it says so in place of one
(`inherited` for a property of the `age` format itself, `assumption` for
something taken as given).

That is a weaker promise than the one this paragraph used to make. The earlier
version said every claim carries a citation and that anything without one is
marked as an assumption. Both halves were false, and the sentence was itself an
uncited claim about the document — the shape this whole document exists to
refuse. A true weak promise is strictly better here: in a security document, a
false statement about its own rigour discredits the parts that are rigorous.

What is NOT claimed: that every sentence below has been individually classified.
Deriving the full claim set and labelling each one is real work and is filed as
`fujibee/agmsg#787`.

If any citation does not say what this document says it says, treat every other
claim here as unverified until re-checked — that is the correct response, and
the reason the citations are here.

Measured on `integration/remote`. Citations resolve at this branch's head. The
only files this branch changes are `docs/security.md` and `docs/security.ja.md`
— no code moves on it — so every `file:line` below points at code that is
identical at the head and at the branch point `452da72`. Verify against
whichever you have.

## Scope

**In scope:** the remote-sync protocol and the reference message server in this
repository — `server/`, `docs/spec/`, `docs/design/`.

**Out of scope:** the hosted service. It is not covered by this document.

**In scope:** the sync client's handling of a received envelope. It lives here
— `scripts/internal/sync-cipher.mjs` and `scripts/internal/remote-sync.mjs` —
and the downgrade question it decides was measured rather than deferred.

## Who the adversary is

RFC 3552 asks for this explicitly, and the claims below are meaningless without
it. Three adversaries are considered, and they are not equally constrained.

**A. The message server.** Honest-but-curious, or fully malicious. It sees every
envelope, stores them, and can replay, reorder, drop, or fabricate anything it
is capable of producing. This is the adversary the `age-v1` profile is aimed at,
and the one the "cannot read, cannot forge" claim is about. It is *not* assumed
to be trustworthy anywhere in this document.

**B. A network attacker between a participant and the server.** Assumed to be
handled by the transport, which is out of this document's scope. Nothing below
depends on the network being confidential — under `age-v1` the envelope's
contents are already protected before transmission, and under `cipher: "none"`
they are not protected at any layer this document covers.

**C. A participant whose identity has been compromised.** Reads everything
addressed to the epochs that identity belongs to, including messages sent before
the compromise. See "On forward secrecy" — this is not mitigated, and rotation
addresses only what comes after.

**Not considered:** an adversary with access to a participant's machine while it
is running, side channels, and traffic analysis beyond the plain statement that
metadata is visible.

## The short version

For a deployment that selects the `age-v1` cipher profile, **the message server
can neither read nor forge a participant's messages.**

Two separate arguments, and the second is the one that usually surprises people:

- **Cannot read.** Decryption requires a private identity. The server holds
  none, and the specification places identities outside it.
- **Cannot forge.** Producing a valid age file requires the recipients'
  **public** keys. With X25519 public-key encryption, "cannot forge without the
  key" means without the *public* key — an unusual property, and the one that
  decides this question. The specification places those outside the server too.

That placement is a **specification requirement**, not an artefact of how the
current server happens to be written:

```
docs/spec/ref/age-v1-profile.md:342-345
  "Recipient public keys, private identities, recipient-set manifests, and
   epoch history are provisioned outside the message server over an
   authenticated, freshness-proving channel. Copying only the current private
   key is insufficient for history or rollback resistance."
```

**And the default profile is not `age-v1`.** See the next section before
reading any of the above as a property of a running deployment.

### The implementation agrees with the specification, and can be checked cheaply

A specification requirement is worth less if the code quietly does something
else, so this was measured rather than assumed. Searching the server's
implementation for anything cryptographic — `age-`, `AGE-SECRET`, `x25519`,
`recipient`, `decrypt`, `privateKey` — returns **seven** hits, and every one of
them is the *string* `"age-v1"` being compared or stored as a profile name:

```
server/src/storage.ts:206     ["none", "age-v1"].includes(envelope.cipher)
server/src/storage.ts:891     ARRAY['none', 'age-v1']::TEXT[]
server/src/storage.ts:921     ARRAY['none', 'age-v1']::TEXT[]
server/src/provision.ts:102   ARRAY['none', 'age-v1']::TEXT[]
server/src/provision.ts:109   ARRAY['none', 'age-v1']::TEXT[]
server/src/protocol.ts:197    cipher_profile: z.enum(["none", "age-v1"])
server/src/storage.ts:269     (a comment)
```

The server treats `cipher` as an opaque label, validated only against a
character pattern:

```
server/src/protocol.ts:13     const cipherPattern = /^[a-z0-9][a-z0-9._-]{0,63}$/;
server/src/protocol.ts:68     cipher: z.string().regex(cipherPattern),
```

What that measures, exactly: **`server/` contains no age vocabulary** — no
implementation, no key interpretation, no decryption path, nothing that names a
recipient stanza.

What it does **not** measure, and the difference matters: the server stores and
forwards opaque blobs. The absence of age-specific words constrains nothing
about the bytes inside a generic buffer, and this search cannot rule out a
server that happens to hold key material it never names. It rules out a server
that *works with* keys.

The claim that keys are not there at all is a **specification requirement**, not
a finding of this grep — `docs/spec/ref/age-v1-profile.md:342-345`, quoted
above. The two support each other and neither replaces the other: the spec says
the keys are provisioned elsewhere, and this search says the code has nothing
that would use them if they arrived.

Reproduce it with one command:

```
grep -rniE '\bage-|AGE-SECRET|x25519|recipient|decrypt|privateKey' server/src --include='*.ts'
```

A hit that is not a profile-name comparison would contradict this section, and
should be treated as contradicting the two claims above it.

## Read this before the properties table

Three facts that a reviewer will otherwise discover on their own, at which point
everything else here is worth less.

### 1. The default is `cipher: "none"`. End-to-end encryption is opt-in.

```
docs/design/remote-sync.md:83-85
  "## No required keys
   `cipher: "none"` is the base, as the envelope spec already says. E2EE
   remains …"
```

Every "cannot read" and "cannot forge" statement in this document is a statement
about a deployment that has selected `age-v1`. A deployment that has not
selected it gets none of them.

### 2. Peer authentication is the operator's responsibility.

Nothing in the protocol binds a key to a person. The handshake that would have
made key distribution convenient was removed deliberately:

```
docs/design/remote-sync.md:93-94
  "What this removes is the machinery for making key distribution
   *convenient*: the `key request` / `key approve` handshake between two of
   your machines."
```

The specification's requirement for an "authenticated, freshness-proving
channel" (cited above) is a requirement **on the operator**. Whether a given
deployment satisfies it cannot be determined from this repository.

### 3. Metadata is not protected.

Who is talking to whom, when, and how much is visible to the server. The
envelope's addressing and timing are how the server routes and orders messages;
they are not encrypted, and no part of the design claims they are.

## Properties

Each row is **provided**, **not provided**, or **out of scope**, for a
deployment that has selected `age-v1`, **against adversary A** (the server)
unless the row says otherwise. "Not provided" means the property is absent and
this is known. "Out of scope" means this document did not examine it — it is not
a weaker way of saying "not provided".

Two rows are about adversary C rather than A, and are marked. No row in this
table is a claim about adversary B.

| Property | Status | Basis |
|---|---|---|
| Confidentiality of message contents | **Provided** | age X25519 encryption; identities are outside the server (`docs/spec/ref/age-v1-profile.md:342-345`) |
| Integrity of message contents | **Provided** | **inherited** — age's own AEAD, a property of the age format rather than of this tree. The profile deliberately adds no second AEAD layer (`docs/spec/ref/age-v1-profile.md:13`), so the guarantee is age's and is checked by reading age, not this repository. The server's digest is *not* the mechanism — see below |
| Unforgeability of message contents | **Provided** | Requires recipients' public keys, which the spec places outside the server (`docs/spec/ref/age-v1-profile.md:342-345`, `:58-63`) |
| Peer authentication | **Not provided** | No key-to-person binding in the protocol (`docs/design/remote-sync.md:93-94`) |
| Metadata confidentiality | **Not provided** | **assumption**, and the easy kind: the server routes and orders by the envelope's addressing and timing, so it reads them. No citation is offered because nothing in the tree states it as a rule — it follows from the server doing its job |
| Forward secrecy (adversary C) | **Not provided** | Recipient sets are per-epoch and immutable (`docs/spec/ref/age-v1-profile.md:88`); an identity that is later compromised decrypts that epoch's history |
| Post-compromise recovery (adversary C) | **Partial, by rotation** | A new epoch is a new recipient set. The journal records the rotation and a fingerprint, never the key (`docs/design/remote-sync.md:103-104`) |
| Downgrade resistance (server-forced) | **Provided by the spec's stanza rules** | Scrypt, SSH, plugin and every other non-X25519 stanza are excluded (`docs/spec/ref/age-v1-profile.md:58-63`) |
| Downgrade resistance (client accepting `cipher: none`) | **Provided by every caller in the tree** | Both `configure` calls pass `--cipher age-v1` and `--minimum-security e2ee-required` together (`scripts/remote.sh:1280`, `:1758`), and there is no third. The refusal is `scripts/internal/remote-sync.mjs:1686`. Removable only by invoking `configure` directly with `plaintext-allowed` |

### On forward secrecy

`age-v1` provides none, and the reason is structural rather than an oversight. A
`key_id` names an **immutable** recipient set:

```
docs/spec/ref/age-v1-profile.md:88
  "A `key_id` identifies an immutable set of X25519 recipients and its private …"
```

An identity compromised at time T decrypts every message addressed to the epochs
that identity belongs to, including those sent before T. Rotation limits the
window going forward; it does not close what is already written.

## `envelopeDigest` is not a signature, and does not need to be

This is the single most likely misreading of the code, so it is closed here
explicitly. The digest is an **unkeyed SHA-256** that the server computes for
itself:

```
server/src/protocol.ts:221-238
  export function envelopeDigest(envelope: Envelope): Buffer {
    …
    return createHash("sha256")
      .update(…)
      .digest();
  }

server/src/storage.ts:307
  const digest = envelopeDigest(message.envelope);

server/src/storage.ts:189
  : record.digest.equals(envelopeDigest(message.envelope));
```

It carries no key, so it authenticates nothing and is trivially recomputable by
anyone holding the envelope. That is not a weakness, because **it is not doing
that job.** Its purpose is at `storage.ts:189`: detecting that the same message
id has been resent with different content, which the server rejects.

The reasoning that leads somewhere wrong is: *the digest has no key → the
contents are unprotected.* The step that fails is the second one. Under
`age-v1`, the contents are protected by age's own AEAD before the server ever
sees them; the digest is a bookkeeping device layered above that, not the thing
standing between an attacker and the plaintext. Under `cipher: "none"` the
contents are not protected — but that is section 1 above, not a property of the
digest.

## Downgrade on receipt: measured, and the answer has two layers

**Question: does a participant configured for `age-v1` accept an injected
`cipher: "none"` envelope?**

The sync client is in this repository — `scripts/internal/sync-cipher.mjs` (819
lines, a full age implementation) and `scripts/internal/remote-sync.mjs`. So
this is answerable here, and it was answered by running it rather than by
reading.

**Layer 1 — the envelope opener does not decide it.** `openEnvelope` dispatches
on the envelope's own `cipher` field and consults no configured profile:

```
scripts/internal/sync-cipher.mjs:718-725
  export async function openEnvelope(input) {
    …
    const profile = cipherProfiles[envelope.cipher];
    if (!profile) throw new CipherStateError("unsupported_cipher", …);
    return profile.open(input);
  }
```

Called directly with a well-formed `cipher: "none"` envelope built from the
repository's own test vectors, it **returns the plaintext projection**. Measured:

```
node -e '… sealEnvelope({…, cipher: "none", key_id: null, recipients: []}) …'
  ACCEPTED — openEnvelope returned the plaintext projection, with no reference
             to any configured profile
```

**Layer 2 — the caller does decide it, and refuses.** The single call site is
guarded, three checks above it:

```
scripts/internal/remote-sync.mjs:1686
  (localPolicy.minimum_security_mode === "e2ee-required" && message.envelope.cipher === "none")
    -> status: "policy_violation", reason: "envelope violates effective policy"
```

So the answer is: **a downgraded envelope is refused, by the pull path's policy
check, not by the cipher layer.** The protection is real and it is one `if`
away from the plaintext — which is worth knowing precisely, because any future
caller of `openEnvelope` that does not replicate that check would accept
injected plaintext silently.

Note also `scripts/internal/remote-sync.mjs:1699`: the check that the configured
profile matches only runs `if (message.envelope.cipher === "age-v1")`. A `none`
envelope does not enter that branch at all. Line 1686 is the whole defence.

### Only one of those two conditions protects you

Line 1686 is a single `if` with three disjuncts, and a reader will take it as
three defences. It is one:

```
scripts/internal/remote-sync.mjs:1684-1686
  !serverPolicy.accepted_envelope_versions.includes(message.envelope.v) ||
  !serverPolicy.write_allowed_ciphers.includes(message.envelope.cipher) ||
  (localPolicy.minimum_security_mode === "e2ee-required" && message.envelope.cipher === "none")
```

The first two read `serverPolicy` — **values the server declares**. Against
adversary A they are worth nothing: a server that wants to inject plaintext
declares a policy that permits plaintext. They are useful for catching
misconfiguration and version drift, not attack.

**The third disjunct is the entire defence against a hostile server**, because
`localPolicy` is the only term in that condition the server does not supply.

### How a deployment ends up on `e2ee-required`

Derived rather than assumed: every call to `remote-sync.sh configure` in the
repository, and the flags each one passes.

```
scripts/remote.sh:1280    --minimum-security e2ee-required --cipher age-v1
scripts/remote.sh:1758    --minimum-security e2ee-required --cipher age-v1
```

Those are the only two, and the search is the whole tree minus `docs/` — the
earlier version of this looked in `scripts/` and `tests/`, which is narrower
than the sentence it was supporting and, worse, reads as "the tests were checked
too" while missing `server/test/`:

```
grep -rn 'remote-sync\.sh' . --exclude-dir=docs --exclude-dir=.git \
  --exclude-dir=node_modules | grep configure

scripts/remote.sh:1280                a caller
scripts/remote.sh:1758                a caller
scripts/internal/remote-sync.mjs:29   a usage string
```

`server/test/sync-client.integration.test.ts` does invoke `remote-sync.sh`
through a generic helper that forwards `...args`, so it could in principle call
`configure`. It does not: `configure` appears zero times in that file.

**So a machine that reaches `age-v1` through any code in this repository
cannot get there without also setting `e2ee-required`** — the two flags are passed together, in both places, and there
is no third place. That is stronger than "the default is safe": there is no
supported way to reach the unsafe combination.

It is still reachable by invoking `remote-sync.sh configure` directly with
`--cipher age-v1 --minimum-security plaintext-allowed`. Nothing forbids that
pairing; it is simply not what any code path here does.

A second machine reaches `age-v1` by a different route, and it was traced rather
than left open. `remote.sh`'s `cmd_pull` copies the team's declared cipher into
the binding (`scripts/remote.sh:916`) without calling `configure` — so at that
moment the machine has `cipher_profile: "age-v1"` and no
`minimum_security_mode` of its own.

It cannot sync in that state. Reading messages requires `unlock`, and
`cmd_unlock` is one of the two callers of `configure`:

```
scripts/remote.sh:1076   cmd_unlock() {
scripts/remote.sh:1280     bash "$SCRIPT_DIR/remote-sync.sh" configure \
scripts/remote.sh:1284       --minimum-security e2ee-required \
scripts/remote.sh:1285       --cipher age-v1
```

So the pull route does not bypass the pairing; it arrives at it one command
later. The other caller, `_remote_configure_keyed_team`
(`scripts/remote.sh:1729`, reached from `:1916`), passes the same two flags.

That is the whole set — the same two callers derived above. Both pass
`--minimum-security e2ee-required` and `--cipher age-v1` as **literals**, not
variables something upstream could set apart, and both sit on the path a machine
must take before it can read anything.

### What that means for the properties table

The row reads **provided by every caller in the tree** — not "out of scope",
and not merely "conditional". There are two callers of `remote-sync.sh
configure` in the whole repository, both pass the pairing as literals, and both
sit on the path a machine must take before it can read anything.

The boundary that remains is narrow and worth naming: this measures callers
**in this repository**. Someone invoking `remote-sync.sh configure` by hand, or
from their own script, can pair `--cipher age-v1` with
`--minimum-security plaintext-allowed`. Nothing forbids that pairing; nothing
shipped here produces it.

## What has not been examined

**The hosted service.** Out of scope.

*(The `minimum_security_mode` question this section used to leave open has been
measured; see "How a deployment ends up on `e2ee-required`" above.)*

## On the age of the specification this cites

`docs/spec/ref/age-v1-profile.md` is marked **"Status: proposed (dogfood
profile)"** and was last touched on 2026-07-27, by the commit that filed it as
reference material — `1a56d8e docs: file superseded work as reference`. It lives
under `ref/`, whose README says plainly: *"Nobody is building toward anything in
a `ref/` directory."*

That is a real reason to distrust it, so the two citations this document leans
on were checked against the code rather than taken on the document's authority:

- **`:342-345` (keys provisioned outside the message server).** Consistent with
  the implementation, and more strongly than the sentence claims: the server has
  no age implementation at all (see "The implementation agrees with the
  specification"). Nothing in `server/` could hold, transit, or use a recipient
  key.
- **`:58-63` (X25519 stanzas only; scrypt, SSH and plugin excluded).** Enforced,
  and not in the server — in the client:

```
scripts/internal/sync-cipher.mjs:277-281
  const activeType = fields[1] === "scrypt" || fields[1] === "ssh-rsa" ||
    fields[1] === "ssh-ed25519" || fields[1].startsWith("plugin-");
  …
  if (!stanzaIsGrease) malformed("age-v1 rejects active non-X25519 recipient stanzas");
```

So both cited requirements hold in code today. A reviewer should still read the
profile document as *proposed*, and should treat any claim in it that this
document does not cite as unchecked — this document verified the two it relies
on, not the whole profile.

## Appendix: OWASP ASVS V6 mapping

Provided as a cross-reference for reviewers who work from ASVS. It is **not**
the spine of this document — the substance is above, and where the two disagree
the sections above are the claim.

| ASVS V6 area | Where this document addresses it |
|---|---|
| V6.1 Data classification | "Read this before the properties table", items 1 and 3 |
| V6.2 Algorithms | Properties table; `docs/spec/ref/age-v1-profile.md:58-63` (X25519 only) |
| V6.2 Integrity | "`envelopeDigest` is not a signature" |
| V6.4 Secret management | `docs/spec/ref/age-v1-profile.md:342-345` (provisioning is outside the server) |
| V6.4 Key rotation | Properties table, post-compromise recovery; `docs/design/remote-sync.md:103-104` |

## How to check this document

Every citation is `path:line`. To verify one, against this branch's head or the
branch point — the code is the same at both:

```
sed -n '342,345p' docs/spec/ref/age-v1-profile.md
sed -n '221,238p' server/src/protocol.ts
```

Line numbers move. If a citation does not land where this says, check the same
file at `452da72` before concluding the claim is wrong — and if it is wrong,
that is worth reporting, because the rest of this document is only as good as
the weakest citation in it.
