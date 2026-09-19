#!/usr/bin/env python3
"""Write a synthetic team history for tests/helpers/mock_remote_server.py.

One wire-shaped message per JSONL line, in the shape GET /v1/messages returns
(`id`, `server_seq`, `server_received_at`, `envelope`), so the mock can serve
it through MOCK_PULL_FILE with no translation. The first `--roster` lines are
`member_joined` roster mutations -- the team's members travel as messages, and a
join that imports no roster ends with the empty roster #910 describes -- and the
rest are plain `cipher: none` messages between those members.

Deterministic: the same arguments produce byte-identical output. Wire ids are
UUIDv4-shaped (what the client checks), derived from the seed and the index.
"""
import argparse
import base64
import hashlib
import json
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone

EPOCH = datetime(2026, 1, 1, tzinfo=timezone.utc)


def stamp(at):
    return at.strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def wire_id(seed, index):
    digest = hashlib.sha256(f"{seed}:{index}".encode()).digest()
    return str(uuid.UUID(bytes=digest[:16], version=4))


def blob(payload, sort_keys):
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=sort_keys)
    return base64.b64encode(raw.encode()).decode()


def roster_event(index, at):
    # Same fields, same id shapes, as the mock's own _roster_blob.
    return blob({
        "kind": "member_joined",
        "mutation_id": "018f3f7e-3333-7000-8000-%012d" % (index + 1),
        "member_id": "018f3f7e-4444-7000-8000-%012d" % (index + 1),
        "name": "member-%d" % (index + 1),
        "occurred_at": stamp(at),
    }, sort_keys=False)


def message(sender, recipient, body, at):
    # cipher "none" carries the canonical JSON of the message, base64, the way
    # the client decodes it on import (see the mock's _blob).
    return blob({"body": body, "created_at": stamp(at),
                 "from_agent": sender, "to_agent": recipient}, sort_keys=True)


def seal_all(plain, args):
    """Seal every message through the product's own helper, as a connect does.

    One `seal-batch` call per run: the requests go in on stdin as JSONL in the
    shape scripts/internal/sync-cipher.mjs checks (the same request a
    first-connect backfill makes), and the results come back with an index.
    The ciphertext is not deterministic (age draws a fresh file key), so two
    runs of one size are two inputs byte-wise and one input in every other
    respect: same plaintext, same ids, same sizes.
    """
    requests = "".join(json.dumps({
        "type": "sync_seal", "envelope_v": 1, "cipher": "age-v1",
        "key_id": args.key_id, "recipients": [args.recipient], "max_blob_bytes": 1048576,
        "wire_id": row["id"], "team_id": args.team_id, "protocol_version": 1,
        "projection": {"body": row["body"], "created_at": stamp(row["at"]),
                       "from_agent": row["sender"], "to_agent": row["recipient"]},
    }, separators=(",", ":")) + "\n" for row in plain)
    envelopes = [None] * len(plain)
    if not plain:
        return envelopes
    # seal-batch accepts at most 10,000 requests per invocation; a larger
    # history is sealed in slices of that size.
    limit = 10000
    for start in range(0, len(plain), limit):
        chunk = plain[start:start + limit]
        chunk_requests = "".join(requests.splitlines(keepends=True)[start:start + limit])
        run = subprocess.run([args.node, args.cipher_helper, "seal-batch", str(len(chunk))],
                             input=chunk_requests, capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit(f"gen-history: seal-batch failed ({run.returncode}): {run.stderr.strip()[:400]}")
        for line in run.stdout.splitlines():
            if not line.strip():
                continue
            result = json.loads(line)
            if result.get("type") != "sync_seal_result":
                continue
            if result.get("status") != "ok" or not result.get("envelope"):
                sys.exit(f"gen-history: seal-batch result {result.get('index')} is not ok: {line[:200]}")
            envelopes[start + result["index"]] = result["envelope"]
    missing = [i for i, e in enumerate(envelopes) if e is None]
    if missing:
        sys.exit(f"gen-history: seal-batch returned no envelope for {len(missing)} request(s), first {missing[0]}")
    return envelopes


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--messages", type=int, required=True,
                        help="plain messages to write (after the roster)")
    parser.add_argument("--roster", type=int, default=3,
                        help="member_joined events to lead with (default 3)")
    parser.add_argument("--body-bytes", type=int, default=120,
                        help="approximate body size per message (default 120)")
    parser.add_argument("--seed", default="agmsg-perf",
                        help="seed for wire ids (default agmsg-perf)")
    parser.add_argument("--out", required=True, help="JSONL path to write")
    parser.add_argument("--cipher", choices=("none", "age-v1"), default="none",
                        help="seal the messages (not the roster) as age-v1; needs the four below")
    parser.add_argument("--cipher-helper", help="path to scripts/internal/sync-cipher.mjs")
    parser.add_argument("--node", default="node", help="node binary for the helper")
    parser.add_argument("--key-id", help="the team's current key id (age-v1)")
    parser.add_argument("--recipient", help="the age recipient to seal to (age-v1)")
    parser.add_argument("--team-id", help="the team's UUIDv7 (age-v1)")
    parser.add_argument("--plain-before", type=int, default=0,
                        help="with --cipher age-v1: this many plain (cipher none) messages BEFORE the "
                             "sealed ones, so a pull imports them and the reprocess then runs against "
                             "a store that already holds them (default 0)")
    args = parser.parse_args()
    if args.messages < 0 or args.roster < 1:
        sys.exit("gen-history: --messages must be >= 0 and --roster >= 1")
    if args.cipher == "age-v1" and not all([args.cipher_helper, args.key_id, args.recipient, args.team_id]):
        sys.exit("gen-history: --cipher age-v1 needs --cipher-helper, --key-id, --recipient, --team-id")

    filler = "lorem ipsum dolor sit amet "
    seq = 0
    with open(args.out, "w", encoding="utf-8") as out:
        for index in range(args.roster):
            seq += 1
            at = EPOCH + timedelta(seconds=index)
            out.write(json.dumps({
                "id": wire_id(args.seed, seq),
                "server_seq": str(seq),
                "server_received_at": stamp(at + timedelta(milliseconds=500)),
                "envelope": {"v": 1, "cipher": "none", "key_id": None,
                             "blob": roster_event(index, at)},
            }, separators=(",", ":")) + "\n")
        plain = []
        for index in range(args.plain_before + args.messages):
            seq += 1
            at = EPOCH + timedelta(minutes=1, seconds=index)
            sender = "member-%d" % (index % args.roster + 1)
            recipient = "member-%d" % ((index + 1) % args.roster + 1)
            head = "synthetic message %d " % (index + 1)
            body = (head + filler * (args.body_bytes // len(filler) + 1))[:args.body_bytes]
            plain.append({"seq": seq, "id": wire_id(args.seed, seq), "at": at,
                          "sender": sender, "recipient": recipient, "body": body})
        # Only the tail is sealed; the first --plain-before rows stay readable
        # without the key, which is what lets a pull import them first.
        sealed = plain[args.plain_before:] if args.cipher == "age-v1" else []
        envelopes = seal_all(sealed, args) if sealed else []
        for index, row in enumerate(plain):
            sealed_index = index - args.plain_before
            envelope = envelopes[sealed_index] if args.cipher == "age-v1" and sealed_index >= 0 else {
                "v": 1, "cipher": "none", "key_id": None,
                "blob": message(row["sender"], row["recipient"], row["body"], row["at"])}
            out.write(json.dumps({
                "id": row["id"],
                "server_seq": str(row["seq"]),
                "server_received_at": stamp(row["at"] + timedelta(milliseconds=500)),
                "envelope": envelope,
            }, separators=(",", ":")) + "\n")
    print(f"gen-history: wrote {seq} lines ({args.roster} roster + {args.plain_before} plain + "
          f"{args.messages} {'sealed ' if args.cipher == 'age-v1' else ''}messages) to {args.out}")


if __name__ == "__main__":
    main()
