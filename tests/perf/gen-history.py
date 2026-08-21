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
    args = parser.parse_args()
    if args.messages < 0 or args.roster < 1:
        sys.exit("gen-history: --messages must be >= 0 and --roster >= 1")

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
        for index in range(args.messages):
            seq += 1
            at = EPOCH + timedelta(minutes=1, seconds=index)
            sender = "member-%d" % (index % args.roster + 1)
            recipient = "member-%d" % ((index + 1) % args.roster + 1)
            head = "synthetic message %d " % (index + 1)
            body = (head + filler * (args.body_bytes // len(filler) + 1))[:args.body_bytes]
            out.write(json.dumps({
                "id": wire_id(args.seed, seq),
                "server_seq": str(seq),
                "server_received_at": stamp(at + timedelta(milliseconds=500)),
                "envelope": {"v": 1, "cipher": "none", "key_id": None,
                             "blob": message(sender, recipient, body, at)},
            }, separators=(",", ":")) + "\n")
    print(f"gen-history: wrote {seq} lines ({args.roster} roster + {args.messages} messages) to {args.out}")


if __name__ == "__main__":
    main()
