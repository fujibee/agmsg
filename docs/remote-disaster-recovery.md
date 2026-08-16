# Disaster recovery: unlocking from an authenticated bundle

This page describes `remote.sh unlock --authenticated-bundle-stdin`. It is **not**
part of onboarding, and it is not something to reach for when adding a machine.
For that, see [remote-setup.md](remote-setup.md) — adding a machine uses
`--bundle <file>` with `--confirm-digest <sha256>`, and that path is unchanged.

## Why a second entry point exists

The ordinary import gate asks a human to compare a SHA-256 over a separate live
channel — read it aloud, check it in another app — before any trust or key
material is imported. That comparison is the authority answering "did these bytes
come from the party I think they did".

**In a disaster there is nobody to compare with.** Recovery-key restore is the
route you take when the machine that held the keys is gone. The other end of the
live channel is precisely what was lost; that is why the restore is happening.
The requirement cannot be met, not because it is inconvenient, but because the
counterpart does not exist.

So this mode does not relax the gate. It **switches the authentication authority**
from a live human digest comparison to an upstream AEAD verifier that already ran
over exactly these bytes — in practice, a recovery-vault client that opened the
bundle with a key derived from the recovery key, under an authenticated cipher
whose additional data binds the expected team and vault.

## What remote.sh does and does not guarantee

`remote.sh` still verifies the snapshot chain: the bundle has to be internally
consistent and agree with the epoch history it claims.

**`remote.sh` does not authenticate the input in this mode, and cannot.** It has
no access to the recovery key or the derived key, so it cannot check that any
verifier ran at all. It accepts the caller's assertion. That is a trust
delegation, and it is stated here rather than hidden: the guarantee is only as
good as the program on the other side of the pipe.

Use it only from a program that holds such an authenticator and binds the
expected team and context. If you are typing this flag by hand, you are using the
wrong mode.

## Why stdin and not a file path

The bytes are read from stdin, not from a path, and that is deliberate. A
pathname is not the bytes: if the caller authenticated a file and then handed
over its name, anything with write access could substitute different content
between the authentication and the import. Passing the exact buffer through the
pipe closes that window — what was authenticated and what is imported are the
same bytes, read once.

## What it does NOT give you: plaintext still reaches the disk

It would be easy to read the section above as "so nothing plaintext is written."
That is false, and the difference matters when the secret is a team's key history.

While the unlock runs, `remote.sh` creates a private directory with `mktemp -d`
and `chmod 700`, and writes inside it:

- the bundle bytes taken from stdin — created under `umask 077`, so `0600`
  regardless of the caller's umask, and never briefly wider (a `chmod` after the
  write would leave exactly that window), and
- **the age secret keys extracted from it** — `verify-age-handoff` requires an
  output directory and writes one `identity-<key_id>.key` per epoch at mode
  `0600`, because the import step reads them from there.

So the plaintext that matters is on the filesystem for the duration either way.
Handing the bundle in on stdin does not change that, and could not: the files are
the verifier's output, not the transport. Passing it as a stream is about
something else — that the bytes imported are the bytes the caller authenticated,
with no window in between for a path to be re-pointed.

### What protects it, and what does not

**Protecting:**

- the parent directory at `0700` — this is what actually keeps other users out;
  they cannot traverse it whatever the files inside are set to;
- the file modes at `0600` — a second layer, not the load-bearing one. It matters
  because the first layer should not be the only one: if the directory's mode is
  ever loosened, or the files are copied somewhere flatter, the modes are what is
  left.

**Not protecting:**

- **other processes running as you.** Same-UID access is not restricted by any of
  this. Anything you run while an unlock is in flight can read the directory.
- **anything after `SIGKILL`, a crash, or power loss.** The directory is removed
  by a `trap` on `EXIT INT TERM HUP` — a normal finish and the usual
  interruptions. None of those three run it. Afterwards the directory can survive
  a reboot under the system temp directory with the key material still in it.
  Treat `${TMPDIR:-/tmp}/agmsg-handoff.*` as something to find and remove
  deliberately after an unlock dies that way; "there is a trap" is not the same
  as "nothing is left".

## Contract

- `--bundle <file>` **requires** `--confirm-digest <sha256>`. Unchanged.
- `--authenticated-bundle-stdin` **replaces** that pair. Combining it with
  `--bundle`, `--confirm-digest`, `--snapshot`, or `--identity` is an error, not a
  precedence rule — two authorities disagreeing about which bytes were
  authenticated must not resolve silently.
- Empty or truncated input fails closed. Nothing is imported.
- The courier `fetch` path uses the digest mode and must not use this one: age
  encryption to a recipient is not sender-authenticated, so a server that knows
  the recipient's public key could seal a substitute. There the live-channel
  comparison is load-bearing.
