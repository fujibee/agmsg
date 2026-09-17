#!/usr/bin/env bash
# Portable SHA-1 of stdin, emitting the bare hex digest.
#
# The codex monitor names a per-project socket and request file after a hash of
# the project path. The original `shasum` is a Perl script that ships on macOS
# and most Linux, but NOT in Git for Windows' Git Bash, where it fails with
# "shasum: command not found" — leaving the hash empty so the socket/request
# files never match and the bridge never engages (#130 area, surfaced on the
# windows-latest CI leg).
#
# Fall back through the tools each platform actually has, in a FIXED order so
# every script computes the same digest on a given machine (session-start.sh,
# codex-monitor.sh and codex-bridge-launcher.sh must agree on the name):
#   shasum (macOS/Linux) -> sha1sum (Git Bash/Linux) -> openssl (near-universal).
# On macOS/Linux this returns the exact same value as before (shasum wins), so
# existing socket/request paths are unchanged; only Windows behaviour improves.
agmsg_sha1() {
  if command -v shasum >/dev/null 2>&1; then
    shasum | awk '{print $1}'
  elif command -v sha1sum >/dev/null 2>&1; then
    sha1sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha1 | awk '{print $NF}'
  else
    # cksum is in POSIX and always present; not SHA-1, but a stable per-machine
    # digest is all the socket/request naming needs.
    cksum | awk '{print $1}'
  fi
}

# Portable SHA-256 of stdin, emitting the bare hex digest.
#
# Same absence as above -- `shasum` is not in Git for Windows' Git Bash -- and
# the same fixed order, so a given machine always answers with one tool:
#   shasum -a 256 (macOS/Linux) -> sha256sum (Git Bash/Linux) -> openssl.
#
# THE LAST RESORT IS DIFFERENT ON PURPOSE, and it is the point of this helper.
# agmsg_sha1 ends in `cksum` because its callers name a socket after the digest
# and need only that the same input give the same name on the same machine.
# These callers need the opposite property. The digest is
#
#   * the fingerprint two people read to each other over a separate channel to
#     confirm they are talking to the key they think they are, and
#   * the age-v1 checkpoint that says an epoch snapshot is the snapshot it
#     claims to be.
#
# A non-cryptographic stand-in does not weaken those, it makes them say
# something untrue. So when no tool here can compute SHA-256 this FAILS, and
# every caller is expected to stop rather than carry an empty or substitute
# value forward.
#
# Do not add a `cksum` arm to "make this consistent with agmsg_sha1". The
# inconsistency is the decision.
#
# THE FAILURE IS THE HELPER'S OWN, not the caller's shell options. Written as
# `shasum -a 256 | awk …` this function's status was the status of `awk`, which
# is delighted by the empty input a failed digest hands it — so "this FAILS"
# held only because `key.sh` and `remote.sh` happen to `set -o pipefail` on
# their second line. A caller without it got an empty success and carried it
# into a fingerprint. Each tool is now run as its own command substitution with
# its status checked here, so the refusal travels with the function.
#
# WHICH ARM RUNS IS DECIDED BY PRESENCE, AND A CHOSEN ARM THAT FAILS IS THE END.
# The fallback exists for a tool that is ABSENT, not for one that is broken:
# there is no second attempt after `shasum` is found and then fails. That is
# deliberate — a machine whose `shasum` is broken has something wrong with it
# that a quiet substitution would hide — and it is asserted below, so changing
# it has to be a decision rather than a drift.
#
# The answer is then checked for being 64 lowercase hex. A tool that exits 0 and
# prints a warning, a path, or an empty line has not failed as far as `$?` is
# concerned, and this value is not a label: it is what two people read to each
# other to confirm a key, and what the age-v1 checkpoint pins a snapshot with.
# Lowercase specifically, because all three arms emit lowercase and a fourth
# that did not would leave two machines disagreeing about a fingerprint that is
# "the same".
#
# The two checks overlap on purpose and are not redundant: a tool that exits
# non-zero while still printing a well-formed digest is caught only by the
# status, and one that exits zero while printing anything else only by the
# shape. There is a case for each below.
# The arms and the shape check, without the self-test below -- so the self-test
# can call it without calling itself.
_agmsg_sha256_selected() {
  local raw
  if command -v shasum >/dev/null 2>&1; then
    raw="$(shasum -a 256)" || return 1
    raw="${raw%% *}"
  elif command -v sha256sum >/dev/null 2>&1; then
    raw="$(sha256sum)" || return 1
    raw="${raw%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    raw="$(openssl dgst -sha256)" || return 1
    raw="${raw##* }"
  else
    echo "agmsg: no SHA-256 tool found on PATH (looked for shasum, sha256sum, openssl)." >&2
    echo "One of these is required for key fingerprints and end-to-end-encryption checkpoints." >&2
    return 1
  fi
  case "$raw" in
    *[!0-9a-f]*|'')
      echo "agmsg: the SHA-256 tool on PATH answered with something that is not a digest." >&2
      return 1
      ;;
  esac
  [ "${#raw}" -eq 64 ] || {
    echo "agmsg: the SHA-256 tool on PATH answered with ${#raw} characters, not a 64-hex digest." >&2
    return 1
  }
  printf '%s\n' "$raw"
}

# ASK THE SELECTED TOOL A QUESTION WE KNOW THE ANSWER TO, BEFORE EVERY DIGEST.
#
# `_agmsg_sha256_selected` accepts any 64 lowercase hex, which is the shape of
# a digest and not the proof of one: a tool that exits 0 and prints a plausible
# but wrong value is accepted, and that value then becomes a fingerprint two
# people read to each other, or the checkpoint that says a snapshot is the
# snapshot it claims to be.
#
# The check lives HERE rather than at the callers because the alternative is a
# list of entry points that must be kept complete -- `key.sh` is its own CLI and
# `generate`, `show`, `import` and `rotate` all reach a digest without going
# anywhere near `connect`'s preflight. A list like that is exactly what was
# already missed once.
#
# RUN BEFORE EVERY DIGEST, AND NOT MEMOISED. It was, on one head, keyed on a
# shell variable -- which review took apart twice over. The flag was read
# straight from the environment, so `_AGMSG_SHA256_VERIFIED=1` in a preseeded
# environment meant "already checked" and skipped the check outright: an
# undocumented env override that turned a fail-closed contract off. And it did
# not even work: every production call is `printf | agmsg_sha256` or
# `x="$(agmsg_sha256 …)"`, both subshells, so the flag never reached the parent
# and the self-test ran again anyway. The saving was imaginary and the hole was
# not.
#
# So the cost is stated instead of avoided: one extra digest of a 5-byte input
# per digest taken. The command that takes the most is `key rotate` with an
# accepted rotation to check -- the accepted recipient's fingerprint, the new
# recipient's journal fingerprint, the previous snapshot, and the short
# fingerprint printed at the end: FOUR digests, so eight runs of the tool. Every
# one of them sits beside file and lock work that dwarfs it.
_agmsg_sha256_selftest() {
  local probe
  probe="$(printf '%s' probe | _agmsg_sha256_selected)" || return 1
  if [ "$probe" != 'ba9c736f19e7f60b7f6764adb0b7908c0a2b394e09b6c09863528c7f2bc86095' ]; then
    echo "agmsg: the SHA-256 tool on PATH returned the wrong digest for a known input." >&2
    echo "Its answers cannot be used for key fingerprints or encryption checkpoints." >&2
    return 1
  fi
}

agmsg_sha256() {
  _agmsg_sha256_selftest || return 1
  _agmsg_sha256_selected
}

# True when agmsg_sha256 has something to run. Separated so a caller can ASK
# before it starts, rather than discover it at the digest.
#
# The order matters more than it looks: the first SHA-256 in a `connect --e2ee`
# comes AFTER the team has been registered with the server, so without this the
# operator's first news of a missing tool is a half-finished connect. Same
# category as the `age` check next to it -- a prerequisite of end-to-end
# encryption, not of agmsg -- and asked at the same moment.
# Probed by RUNNING it, not by `command -v`. The question is whether this
# machine can produce a SHA-256, and presence on PATH is only a proxy for that:
# a tool that is installed and fails answers "yes" to the proxy and "no" to the
# question, which is the direction that hurts -- the preflight passes and the
# digest fails later, which is the shape of #861 all over again. Costs two runs
# of the tool -- `agmsg_sha256`'s self-test and this probe's own digest -- on a
# command that is about to make a network round trip.
#
# Nothing more than "can this machine produce one", because the correctness
# question moved into `agmsg_sha256` itself -- a preflight that knows something
# the digest path does not is the shape of #861, and for one head this function
# was the only thing checking the answer while `key.sh` reached a digest by four
# routes that never call it.
agmsg_sha256_usable() {
  printf '%s' probe | agmsg_sha256 >/dev/null 2>&1
}

# Refuse to proceed without one, with the same install guidance shape the age
# preflight uses.
agmsg_require_sha256() {
  if ! agmsg_sha256_usable; then
    echo "agmsg: end-to-end encryption needs a working SHA-256 tool, and this device has none." >&2
    echo "One may be installed: a tool that is present but fails, or answers a known input" >&2
    echo "wrongly, is reported here the same way as one that is absent -- neither can be used." >&2
    echo "agmsg looks for 'shasum', then 'sha256sum', then 'openssl'. Install or repair one:" >&2
    echo "  macOS (Homebrew):      brew install openssl" >&2
    echo "  Debian/Ubuntu:         sudo apt install coreutils" >&2
    echo "  Windows (Git Bash):    ships with Git for Windows; reinstall it if 'sha256sum' is missing" >&2
    return 1
  fi
}
