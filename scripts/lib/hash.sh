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
