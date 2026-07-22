#!/usr/bin/env python3
"""Strictly validate a pairing-exchange response before remote.sh mutates
any local state (ADR 0007 review finding B6). Reads the raw response body
on stdin; on success prints one field per line to stdout (credential,
credential_id, server_instance_id, remote_team_id, remote_team_name,
protocol_version, capabilities JSON, write_allowed_ciphers joined by
comma, current_seq or -1 if absent) and exits 0. On any malformed/missing/
wrong-typed field, prints a one-line reason to stderr and exits 1 WITHOUT
printing partial output — callers must not proceed past a non-zero exit
here.

Newline-delimited rather than NUL-delimited deliberately: bash's command
substitution `$(...)` strips embedded NUL bytes from captured output,
which would silently destroy NUL-based field boundaries before the caller
ever sees them. Every field is rejected if it contains a literal newline
(none legitimately should), so newline is safe as the sole delimiter here.

credential_id is validated against a bounded, URL-path-safe character set
because it is spliced directly into the revoke endpoint's path — anything
else risks path/query injection against a malicious or buggy server.
"""
import json
import re
import sys

ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def fail(msg):
    print(f"invalid exchange response: {msg}", file=sys.stderr)
    sys.exit(1)


def req_str(d, key):
    v = d.get(key)
    if not isinstance(v, str) or not v:
        fail(f"missing or invalid '{key}'")
    return v


def main():
    raw = sys.stdin.read()
    try:
        d = json.loads(raw)
    except Exception:
        fail("response body is not valid JSON")
        return
    if not isinstance(d, dict):
        fail("response body is not a JSON object")
        return

    credential = req_str(d, "credential")
    credential_id = req_str(d, "credential_id")
    if not ID_RE.match(credential_id):
        fail("credential_id has an unexpected shape")
    server_instance_id = req_str(d, "server_instance_id")
    remote_team_id = req_str(d, "remote_team_id")

    remote_team_name = d.get("remote_team_name", "")
    if not isinstance(remote_team_name, str):
        fail("remote_team_name has an unexpected type")

    protocol_version = d.get("protocol_version")
    if not isinstance(protocol_version, int) or isinstance(protocol_version, bool):
        fail("protocol_version has an unexpected type")

    caps = d.get("capabilities", {})
    if not isinstance(caps, dict):
        fail("capabilities has an unexpected type")

    ciphers = caps.get("write_allowed_ciphers", [])
    if not isinstance(ciphers, list) or not all(isinstance(c, str) for c in ciphers):
        fail("capabilities.write_allowed_ciphers has an unexpected shape")
    if any("," in c for c in ciphers):
        fail("capabilities.write_allowed_ciphers entries must not contain ','")

    current_seq = caps.get("current_seq")
    if current_seq is not None and (not isinstance(current_seq, int) or isinstance(current_seq, bool)):
        fail("capabilities.current_seq has an unexpected type")

    caps_json = json.dumps(caps)
    fields = [
        credential,
        credential_id,
        server_instance_id,
        remote_team_id,
        remote_team_name,
        str(protocol_version),
        caps_json,
        ",".join(ciphers),
        str(current_seq if current_seq is not None else -1),
    ]
    for f in fields:
        if "\n" in f:
            fail("a response field unexpectedly contains a newline")

    sys.stdout.write("\n".join(fields) + "\n")


if __name__ == "__main__":
    main()
