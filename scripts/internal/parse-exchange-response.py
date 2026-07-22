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
else risks path/query injection against a malicious or buggy server; its
exact format isn't pinned by any approved spec (pairing/credential
exchange is this ADR's own addition), so a conservative bounded charset
is the right baseline. server_instance_id and team_id (remote_team_id),
by contrast, ARE pinned: the approved sync HTTP v1 spec (server/spec/v1.md
@ d1a74db) requires both to be a canonical LOWERCASE UUIDv7 (RFC 9562) —
validated here as such, not left to a loose bounded charset, since an
invalid binding must never reach a local commit.

This same validator is also used to re-check a previously-saved pending
record before resuming a commit from it (ADR 0007 review finding R5) — a
pending file is not inherently more trustworthy than a fresh response.

Duplicate JSON object keys and unrecognized fields are both rejected
(ADR 0007 review finding D4): plain `json.loads` silently keeps only the
LAST occurrence of a duplicated key with no signal that a duplicate ever
existed, which a malicious/buggy server could use to smuggle a value past
a naive review of "the response has the right fields" — and would
otherwise vanish for good once re-serialized (e.g. by the pending-file
writer). An exact top-level and `capabilities` field allow-list closes
the same gap for fields this validator doesn't otherwise look at.
"""
import json
import re
import sys

ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
UUIDV7_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
SUPPORTED_PROTOCOL_VERSIONS = (1,)
ALLOWED_TOP_LEVEL_KEYS = {
    "credential", "credential_id", "server_instance_id", "remote_team_id",
    "remote_team_name", "protocol_version", "capabilities",
}
ALLOWED_CAPABILITY_KEYS = {
    "accepted_envelope_versions", "write_allowed_ciphers", "policy_revision",
    "effective_from_seq", "max_blob_bytes", "current_seq",
    "next_sequence_boundary", "min_available_seq", "policy_history",
}


def fail(msg):
    print(f"invalid exchange response: {msg}", file=sys.stderr)
    sys.exit(1)


def _no_duplicate_keys(pairs):
    seen = set()
    out = {}
    for k, v in pairs:
        if k in seen:
            fail(f"duplicate JSON key '{k}'")
        seen.add(k)
        out[k] = v
    return out


def strict_loads(raw):
    """json.loads that rejects any object with a duplicate key, at any
    nesting depth (object_pairs_hook runs for every object, not just the
    top level)."""
    return json.loads(raw, object_pairs_hook=_no_duplicate_keys)


def req_str(d, key):
    v = d.get(key)
    if not isinstance(v, str) or not v:
        fail(f"missing or invalid '{key}'")
    return v


def main():
    raw = sys.stdin.read()
    try:
        d = strict_loads(raw)
    except SystemExit:
        raise
    except Exception:
        fail("response body is not valid JSON")
        return
    if not isinstance(d, dict):
        fail("response body is not a JSON object")
        return

    unknown = set(d.keys()) - ALLOWED_TOP_LEVEL_KEYS
    if unknown:
        fail(f"unrecognized field(s): {', '.join(sorted(unknown))}")

    credential = req_str(d, "credential")
    credential_id = req_str(d, "credential_id")
    if not ID_RE.match(credential_id):
        fail("credential_id has an unexpected shape")
    server_instance_id = req_str(d, "server_instance_id")
    if not UUIDV7_RE.match(server_instance_id):
        fail("server_instance_id must be a canonical lowercase UUIDv7")
    remote_team_id = req_str(d, "remote_team_id")
    if not UUIDV7_RE.match(remote_team_id):
        fail("remote_team_id must be a canonical lowercase UUIDv7")

    remote_team_name = d.get("remote_team_name", "")
    if not isinstance(remote_team_name, str):
        fail("remote_team_name has an unexpected type")

    protocol_version = d.get("protocol_version")
    if not isinstance(protocol_version, int) or isinstance(protocol_version, bool):
        fail("protocol_version has an unexpected type")
    if protocol_version not in SUPPORTED_PROTOCOL_VERSIONS:
        fail(f"unsupported protocol_version {protocol_version!r}")

    caps = d.get("capabilities", {})
    if not isinstance(caps, dict):
        fail("capabilities has an unexpected type")
    unknown_caps = set(caps.keys()) - ALLOWED_CAPABILITY_KEYS
    if unknown_caps:
        fail(f"unrecognized capabilities field(s): {', '.join(sorted(unknown_caps))}")

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
