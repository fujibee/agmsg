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

credential_id, server_instance_id, and team_id (remote_team_id) are all
pinned to canonical lowercase UUIDv7. The credential identifier is also
spliced into the revoke endpoint's path, so accepting a looser value here
would both split client/server validation and risk path/query injection.

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

UUIDV7_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
CIPHER_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
SEQUENCE_RE = re.compile(r"^(0|[1-9][0-9]*)$")
MAX_SEQUENCE = 9_223_372_036_854_775_807
SUPPORTED_PROTOCOL_VERSIONS = (1,)
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
ALLOWED_TOP_LEVEL_KEYS = {
    "credential", "credential_id", "server_instance_id", "remote_team_id",
    "remote_team_name", "protocol_version", "capabilities",
}
ALLOWED_CAPABILITY_KEYS = {
    "protocol_version", "server_instance_id", "team_id", "team_name",
    "accepted_envelope_versions", "write_allowed_ciphers", "policy_revision",
    "effective_from_seq", "max_blob_bytes", "current_seq",
    "next_sequence_boundary", "min_available_seq", "policy_history",
}
POLICY_KEYS = {
    "policy_revision", "effective_from_seq", "accepted_envelope_versions",
    "write_allowed_ciphers",
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


def req_sequence(d, key, label=None):
    value = d.get(key)
    if (
        not isinstance(value, str)
        or not SEQUENCE_RE.match(value)
        or int(value) > MAX_SEQUENCE
    ):
        fail(f"capabilities.{label or key} is not a canonical sequence")
    return value


def validate_policy_set(value, label):
    if (
        not isinstance(value, list)
        or not all(isinstance(item, str) and CIPHER_RE.match(item) for item in value)
        or len(value) != len(set(value))
    ):
        fail(f"capabilities.{label} has an unexpected shape")
    return value


def validate_envelope_versions(value, label):
    if (
        not isinstance(value, list)
        or not value
        or not all(
            isinstance(item, int) and not isinstance(item, bool)
            and 0 <= item <= 0xFFFFFFFF for item in value
        )
        or len(value) != len(set(value))
    ):
        fail(f"capabilities.{label} has an unexpected shape")
    return value


def main():
    raw_bytes = sys.stdin.buffer.read(MAX_RESPONSE_BYTES + 1)
    if len(raw_bytes) > MAX_RESPONSE_BYTES:
        fail("response body exceeds its byte limit")
    try:
        raw = raw_bytes.decode("utf-8")
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
    if not UUIDV7_RE.match(credential_id):
        fail("credential_id must be a canonical lowercase UUIDv7")
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

    for field in (credential, credential_id, server_instance_id, remote_team_id, remote_team_name):
        if re.search(r"[\x00-\x1f\x7f]", field):
            fail("a response field unexpectedly contains a control character")

    caps = d.get("capabilities", {})
    if not isinstance(caps, dict):
        fail("capabilities has an unexpected type")
    unknown_caps = set(caps.keys()) - ALLOWED_CAPABILITY_KEYS
    if unknown_caps:
        fail(f"unrecognized capabilities field(s): {', '.join(sorted(unknown_caps))}")

    if (
        caps.get("protocol_version") != protocol_version
        or caps.get("server_instance_id") != server_instance_id
        or caps.get("team_id") != remote_team_id
        or caps.get("team_name") != remote_team_name
    ):
        fail("capabilities binding does not match the exchange response")

    current_seq = req_sequence(caps, "current_seq")
    min_available_seq = req_sequence(caps, "min_available_seq")
    policy_revision = req_sequence(caps, "policy_revision")
    effective_from_seq = req_sequence(caps, "effective_from_seq")
    max_blob_bytes = req_sequence(caps, "max_blob_bytes")
    if not 1 <= int(max_blob_bytes) <= 1_048_576:
        fail("capabilities.max_blob_bytes is outside the protocol limit")
    if int(min_available_seq) > int(current_seq):
        fail("capabilities retention floor exceeds current_seq")
    next_boundary = caps.get("next_sequence_boundary")
    if current_seq == str(MAX_SEQUENCE):
        if next_boundary is not None:
            fail("capabilities next_sequence_boundary must be null at exhaustion")
    elif (
        not isinstance(next_boundary, str)
        or not SEQUENCE_RE.match(next_boundary)
        or int(next_boundary) != int(current_seq) + 1
    ):
        fail("capabilities next_sequence_boundary is inconsistent")

    versions = validate_envelope_versions(
        caps.get("accepted_envelope_versions"), "accepted_envelope_versions"
    )
    ciphers = validate_policy_set(caps.get("write_allowed_ciphers"), "write_allowed_ciphers")
    history = caps.get("policy_history")
    if not isinstance(history, list) or not history or len(history) > 4096:
        fail("capabilities.policy_history has an unexpected shape")
    prior_revision = -1
    prior_boundary = 0
    for entry in history:
        if not isinstance(entry, dict) or set(entry.keys()) != POLICY_KEYS:
            fail("capabilities.policy_history entry has an unexpected shape")
        revision = req_sequence(entry, "policy_revision", "policy_history.policy_revision")
        boundary = req_sequence(entry, "effective_from_seq", "policy_history.effective_from_seq")
        entry_versions = validate_envelope_versions(
            entry.get("accepted_envelope_versions"), "policy_history.accepted_envelope_versions"
        )
        entry_ciphers = validate_policy_set(
            entry.get("write_allowed_ciphers"), "policy_history.write_allowed_ciphers"
        )
        if int(revision) <= prior_revision or int(boundary) <= prior_boundary:
            fail("capabilities.policy_history is not canonical ascending")
        prior_revision = int(revision)
        prior_boundary = int(boundary)
    if history[0]["effective_from_seq"] != "1":
        fail("capabilities.policy_history must begin at sequence 1")
    if next_boundary is not None and prior_boundary > int(next_boundary):
        fail("capabilities.policy_history starts beyond the next sequence boundary")
    final = history[-1]
    if (
        final["policy_revision"] != policy_revision
        or final["effective_from_seq"] != effective_from_seq
        or final["accepted_envelope_versions"] != versions
        or final["write_allowed_ciphers"] != ciphers
    ):
        fail("capabilities current policy does not match policy_history")

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
        current_seq,
    ]
    for f in fields:
        # Reject every ASCII control character (0x00-0x1F, 0x7F), not
        # just newline (E3) — a raw tab/CR/etc. reaching a downstream
        # hand-built JSON string (e.g. the credential file) that only
        # escapes backslash/quote produces invalid JSON, discovered only
        # when that file is next read. Rejecting here means a
        # conforming server payload never contains one in the first
        # place, on top of any downstream escaping fix.
        if re.search(r"[\x00-\x1f\x7f]", f):
            fail("a response field unexpectedly contains a control character")

    sys.stdout.write("\n".join(fields) + "\n")


if __name__ == "__main__":
    main()
