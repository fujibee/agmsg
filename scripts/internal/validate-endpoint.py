#!/usr/bin/env python3
"""Strictly validate a --endpoint value (ADR 0007 review finding R2).

A naive shell glob/prefix check (`case $endpoint in http://127.0.0.1*)`)
is bypassable: `http://127.0.0.1.evil.com`, `http://localhost.evil.com`,
and `http://localhost@evil.com` (userinfo trick — the real host is
evil.com) all match a bare string-prefix test while actually pointing
somewhere else, silently sending the token/credential to that host in
plaintext. This does real structural URL parsing instead: scheme must be
exactly "https", OR exactly "http" with the parsed hostname (never the
raw string) equal to one of the loopback literals AND no userinfo/port
trickery involved.

Exits 0 (silent) if <endpoint> (argv[1]) is acceptable; exits 1 with a
one-line reason on stderr otherwise.
"""
import sys
from urllib.parse import urlsplit

LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def fail(msg):
    print(f"agmsg: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        fail("internal error: validate-endpoint.py needs exactly one argument")
        return
    endpoint = sys.argv[1]

    try:
        parts = urlsplit(endpoint)
    except Exception:
        fail("--endpoint could not be parsed as a URL")
        return

    if parts.scheme == "https":
        if not parts.hostname:
            fail("--endpoint has no host")
        return

    if parts.scheme == "http":
        if parts.username is not None or parts.password is not None:
            fail("--endpoint must not contain userinfo (user@ or user:pass@)")
        if parts.hostname not in LOOPBACK_HOSTS:
            fail(
                "--endpoint must be https:// (plaintext http:// would send the "
                "token/credential unencrypted) — loopback (127.0.0.1/localhost/::1) "
                "is the only exception, and only for the exact hostname"
            )
        return

    fail("--endpoint must start with https://")


if __name__ == "__main__":
    main()
