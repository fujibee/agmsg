#!/usr/bin/env python3
"""Validate the final HTTP response block's v1 protocol header."""

import re
import sys

MAX_HEADER_BYTES = 65_536
STATUS_RE = re.compile(r"^HTTP/\S+ ([0-9]{3})(?: |$)")


def fail(message):
    print(f"invalid protocol response header: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    raw = sys.stdin.buffer.read(MAX_HEADER_BYTES + 1)
    if len(raw) > MAX_HEADER_BYTES:
        fail("header block exceeds its byte limit")
    try:
        text = raw.decode("iso-8859-1")
    except UnicodeDecodeError:
        fail("header block is not decodable")

    blocks = []
    current = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if line == "":
            if current:
                blocks.append(current)
                current = []
            continue
        current.append(line)
    if current:
        blocks.append(current)

    final = None
    for block in blocks:
        match = STATUS_RE.match(block[0]) if block else None
        if not match:
            fail("malformed HTTP status line")
        if int(match.group(1)) >= 200:
            final = block
    if final is None:
        fail("no final HTTP response block")

    values = []
    for line in final[1:]:
        if line[:1] in (" ", "\t") or ":" not in line:
            fail("malformed response header field")
        name, value = line.split(":", 1)
        if name.lower() == "agmsg-protocol-version":
            values.append(value.strip())
    if values != ["1"]:
        fail("Agmsg-Protocol-Version must occur exactly once with value 1")


if __name__ == "__main__":
    main()
