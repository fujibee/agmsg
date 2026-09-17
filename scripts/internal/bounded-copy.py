#!/usr/bin/env python3
"""Copy stdin to stdout only when the complete stream fits a byte limit."""

import sys


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        raise SystemExit(2)
    limit = int(sys.argv[1])
    value = sys.stdin.buffer.read(limit + 1)
    if len(value) > limit:
        print("bounded stream exceeds its byte limit", file=sys.stderr)
        raise SystemExit(1)
    sys.stdout.buffer.write(value)


if __name__ == "__main__":
    main()
