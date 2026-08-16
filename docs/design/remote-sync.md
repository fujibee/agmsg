# Remote sync — the minimum

**Status:** the design being built to. Not implemented yet.

This replaces the onboarding half of `device-pairing.md`, and the remote connect
onboarding design that used to sit beside it — that document was about the
hosted service, so it does not belong in this repository. Two further documents were removed rather than kept as
history: `local-first-onboarding.md`, whose onboarding this document replaces,
and `authentication-result-handoff.md`, a proposal for a seam this design does
not have — see "No authentication" below for what it removes. Their reasoning
is in the git history. Sync itself — Stage 1, read state,
retention gaps, the envelope format — is unchanged and specified elsewhere.

## What a remote is

A place to keep a team so more than one machine can use it. Nothing else.

agmsg works with no server at all. A team is created locally, used locally, and
is complete without ever connecting. Connecting is something you may do later
to a team that already exists. **The server never originates a team**, and the
identity of a local team can never depend on a service that is optional.

That single constraint decides most of what follows.

## Try it on one machine

Everything below can be watched end to end with two installs on one host, no
cloud, no auth. This is the exact path the design was verified on. `<A>` and
`<B>` are two command names you pick — anything but the one your real install
already uses, so this never touches it.

```sh
# 1. A reference server on localhost, backed by Postgres.
cd server && npm ci
DATABASE_URL=postgres://USER:PASS@127.0.0.1:5432/DB PORT=8787 npx tsx src/index.ts &

# 2. Two installs beside your real one — each its own command name and store.
bash install.sh --cmd <A> --agent-type claude-code
bash install.sh --cmd <B> --agent-type claude-code

# 3. On <A>, connect a team you already have. A team from before local ids
#    works: connect mints them, moves the team to its own store, uploads its
#    history, and leaves a sync engine running.
~/.agents/skills/<A>/scripts/remote.sh connect --endpoint http://127.0.0.1:8787 myteam

# 4. On <B>, pull it by name and keep syncing.
~/.agents/skills/<B>/scripts/remote.sh pull --endpoint http://127.0.0.1:8787 myteam

# 5. Send from either side; it reaches the other.
~/.agents/skills/<A>/scripts/send.sh myteam alice bob "hello from machine one"
```

Two things are worth confirming yourself, because they are the whole point: a
team you did **not** connect is untouched in the shared store and still readable,
and the connected team's rows are gone from that shared store — a program that
read the database file directly no longer sees them, by design. Ask the server
for a team's location with `api.sh get teams <team> store` rather than assuming
the path.

## Three things happen, and only three

**Register.** Send the team you have. The server records it and answers.

**Move.** The team's members and its message history go up. The server stores
messages as opaque blobs; `from`, `to`, `body`, and the client's timestamp are
inside the blob, and the server does not read, index, or project them.

**Continue.** From then on new messages flow as they are written.

Machine two runs the same three in reverse: it registers, pulls the team down,
and continues.

## No authentication

Reaching the server is the permission, the same way reaching the filesystem is
the permission locally. It is your server, on your network.

This is the minimum, chosen deliberately and not a placeholder we forgot to
fill. Revisit it once the whole path works end to end.

**What this removes:** per-device credentials, pairing tokens, token purposes,
the exchange→finalize two-call machine, provisional credentials, onboarding
sessions, and the credential handoff between a host and the data plane. The
two-call machine existed to deliver a secret exactly once and confirm it had
been written durably before committing. With no secret, its reason is gone.

## No required keys

`cipher: "none"` is the base, as the envelope spec already says. E2EE remains
available — the `age-v1` profile stays — but distributing keys is the
operator's own problem.

**Encryption protects you from whoever runs the server.** Self-hosting on your
own machine, that is you. It is the reason the hosted service exists, not a
property the reference server owes you.

What this removes is the machinery for making key distribution *convenient*:
the `key request` / `key approve` handshake between two of your machines.
Capability kept, convenience dropped.

### Changing a key

A key has to be replaceable — a leaked one is otherwise permanent, and a member
who leaves otherwise reads everything that follows. The replacement rides the
journal, and the shape is what keeps it small:

**The journal carries the fact of the rotation, never the key.** A
`key_rotated` record names the new epoch and a fingerprint of the key. The key
material itself is handed over the same way the first one is: by whoever rotated
it, out of band.

That one restraint settles both hard parts.

**When machines switch** is decided by the record's place in the server's
sequence — a boundary every machine reads the same way, for the same reason
renames get their order for free. No cutover protocol, and no need to stop the
other machines first.

The record is itself sealed, and which key seals it settles the rest. **A
`key_rotated` is sealed with the epoch immediately before the one it announces,
and the new epoch takes effect from the sequence after the record.** Sealing it
with the new key would make the boundary land one position earlier, and would
cost the thing the announcement exists for: someone holding only the old key
would see an undecryptable blob rather than a reason. A machine should be able to
say "the key changed and I do not have the new one", not merely stop
understanding its own team. The fingerprint is not the key, so reading the
announcement gains a removed member nothing but the fact.

**Two machines can rotate at once, and the sequence decides.** Both seal their
announcement with the same preceding epoch, and both claim the epoch after it;
the first one the server orders is adopted, and a later record claiming an epoch
already taken is ignored. The machine that lost holds a key nobody uses and no
key for the epoch that won — so it halts, exactly as any other machine missing
the current key does, and resumes once it is handed the winner's. Nothing new is
needed to handle it: the rule that a machine without the current key stops is
already the whole mechanism.

Stating the seal as "the preceding epoch" rather than "the old key" is what makes
that work, and it was the more accurate statement to begin with — the property
being relied on is that whoever is *about* to be cut off can still read the
notice.

**Who ends up holding the new key** is settled by leaving it out. Someone who
has been removed still holds the old key, so they can read the announcement —
they learn a rotation happened, and are stopped by it. What they cannot do is
obtain the new key from a stream that never carries it. **A machine that sees
`key_rotated` and holds no matching key halts, and says why.** Putting the
material in the journal would hand it to exactly the party the rotation exists
to exclude.

**What this does not do is make the past unreadable.** Whoever held the old key
keeps whatever they already decrypted. No mechanism recovers that; the guarantee
is "not from here on", and it should be stated that way rather than implied to
be more.

### Rollback resistance is part of this, not an extra

`age-v1` already specifies epoch snapshots: a strictly increasing
`epoch_revision`, a strictly increasing `writer_generation`, the authorized
writer roster for that generation, the full key-epoch history, and
`previous_snapshot_sha256` linking each to the one before. It is designed and
unimplemented, and it belongs in this work.

**The `key_rotated` event does not carry a snapshot, and a machine must not
build one from it.** The event has an epoch, a key id, a fingerprint, and a
time — not the authorized roster, the generation, or the chain digest that make
a snapshot trustworthy. So the snapshot travels the way the key material does:
handed over out of band and taken in through `import`, authority and chain
verified on the way in. The event only says *activate*: when a `key_rotated`
matches the epoch, key id, fingerprint, and boundary of a snapshot already
provisioned, the machine switches to it; when no such snapshot has been
imported, it does the same thing it does for any missing key — it stops. The
fingerprint's job is to confirm that the snapshot in hand is the one the event
names, not to stand in for it.

The tempting argument for deferring it is that a server hiding `key_rotated`
from one machine leaves that machine on the old key, writing what nobody else
can read — isolated, and visibly so. **That covers only the case where machines
disagree.** Shown the same older state, every machine stays consistent with
every other; the roster and the epoch are simply stale, everything presented
decrypts correctly, and nothing looks wrong. Rollback arrives as "everyone
consistently behind", not as a divergence.

Underneath the specific attack, deferring it contradicts the premise.
Encryption here exists so that the server does not have to be trusted. Leaving
history and ordering untestable is a way of saying the server is trusted about
those, and a promise to protect you from whoever runs the server does not
survive being rewound without noticing.

## Identity is minted locally

A team gets a `team_id` and each member a `member_id`, generated **on the
machine that owns them**, once, and never regenerated. Those same ids go to the
server on connect and to the second machine on pull. One id, three places.

Today a local team is a name, and `rename.sh` rewrites every affected message
row when a name changes. That works while there is one copy. Remotely it would
mean **replaying history rewrites to every machine** — the past becomes mutable
and append-only stops holding. Hence ids.

**A team is either wholly id-bearing or wholly name-based; never partly both.**
A team created from now on gets its ids at creation, and a member joining such
a team gets one too. A team that predates ids keeps none — not even for a member
who joins it today — until it connects, at which point the team and every member
it currently has are minted together. Half a roster with ids is the one state
worth ruling out, because every reader would then need to handle both.

**Rewriting stored history happens per team, when that team connects.** Teams
that never connect keep working by name and their rows are not rewritten. On our
own store this would be one team of 5,946 messages out of 6,121 across ten teams,
and 66 distinct agent names to resolve. This is about message rows, not about the
ids above: minting an id costs nothing and touches one small file, while
rewriting history is the expensive, irreversible part that waits for a reason.

## One local team, one remote team

A `team_id` already registered is refused. This is a uniqueness constraint, not
an authorization decision.

Two teams that each have their own history never merge onto one remote — the
same reason git refuses a non-fast-forward push. A second machine is not a
second team: it arrives empty and clones.

## Deliberately out of scope

- **Anyone who can reach the server and knows a `team_id` can pull it.**
  Accepted for the minimum.
- Per-device revocation. There are no per-device credentials to revoke.
- Automated key distribution — including for a rotation. The journal announces
  that a key changed; handing over the new one stays manual, which is what lets
  a rotation exclude somebody.
- The multi-writer cutover protocol. The server's sequence already fixes the
  moment every machine switches.
- Merging two populated teams.

## Removed, not deprecated

`admin team create` and the pairing-token commands are deleted. They are not a
legacy path to keep working: the model where a server operator creates a team
before a user can connect is the one this design exists to replace, and while
the command exists someone will write it into a runbook. That already happened.
