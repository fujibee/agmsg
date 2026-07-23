#!/usr/bin/env python3
"""Strictly validate an authenticated credential-revoke response."""

import datetime
import json
import re
import sys

UUIDV7_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$")
EXPECTED_KEYS = {
    "protocol_version", "server_instance_id", "team_id", "credential_id",
    "revoked", "revoked_at",
}
MAX_BODY_BYTES = 65_536


def fail(message):
    print(f"invalid revoke response: {message}", file=sys.stderr)
    raise SystemExit(1)


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key '{key}'")
        result[key] = value
    return result


def main():
    if len(sys.argv) != 4:
        fail("expected server_instance_id, team_id, and credential_id")
    expected_server, expected_team, expected_credential = sys.argv[1:]
    raw = sys.stdin.buffer.read(MAX_BODY_BYTES + 1)
    if len(raw) > MAX_BODY_BYTES:
        fail("response body exceeds its byte limit")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicate_keys)
    except SystemExit:
        raise
    except Exception:
        fail("response body is not strict UTF-8 JSON")
    if not isinstance(value, dict) or set(value) != EXPECTED_KEYS:
        fail("response object has an unexpected shape")
    if value["protocol_version"] != 1 or value["revoked"] is not True:
        fail("protocol_version or revoked flag is invalid")
    for key, expected in (
        ("server_instance_id", expected_server),
        ("team_id", expected_team),
        ("credential_id", expected_credential),
    ):
        actual = value.get(key)
        if not isinstance(actual, str) or not UUIDV7_RE.fullmatch(actual) or actual != expected:
            fail(f"{key} does not match the connected binding")
    timestamp = value.get("revoked_at")
    if not isinstance(timestamp, str) or not TIMESTAMP_RE.fullmatch(timestamp):
        fail("revoked_at is not canonical UTC")
    try:
        parsed = datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        fail("revoked_at is not a real UTC timestamp")
    if parsed.strftime("%Y-%m-%dT%H:%M:%S.%fZ") != timestamp:
        fail("revoked_at is not canonical UTC")


if __name__ == "__main__":
    main()
