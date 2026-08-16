#!/usr/bin/env python3
"""Drive remote connect with token stdin and a distinct controlling TTY.

Token and age identity bytes are read from private files rather than argv.
The helper waits for the identity prompt and verifies that the terminal echo
flag is off before writing the permanent secret.
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import stat
import subprocess
import sys
import termios
import time


TIMEOUT_SECONDS = 15


def private_bytes(path: str, limit: int) -> bytes:
    file_stat = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_mode & 0o077:
        raise RuntimeError(f"fixture must be a private regular file: {path}")
    with open(path, "rb") as handle:
        value = handle.read(limit + 1)
    if not value or len(value) > limit:
        raise RuntimeError(f"fixture has invalid size: {path}")
    return value


def echo_enabled(fd: int) -> bool:
    return bool(termios.tcgetattr(fd)[3] & termios.ECHO)


def main() -> int:
    if len(sys.argv) not in (5, 6):
        raise RuntimeError(
            "usage: run_remote_connect_tty.py SCRIPT ENDPOINT TOKEN_FILE "
            "(generate|import) [IDENTITY_FILE]"
        )
    script, endpoint, token_path, mode = sys.argv[1:5]
    if mode not in ("generate", "import"):
        raise RuntimeError("mode must be generate or import")
    if mode == "import" and len(sys.argv) != 6:
        raise RuntimeError("import requires an identity file")
    if mode == "generate" and len(sys.argv) != 5:
        raise RuntimeError("generate does not accept an identity file")

    token = private_bytes(token_path, 4096)
    identity = private_bytes(sys.argv[5], 4096) if mode == "import" else None
    master_fd, slave_fd = pty.openpty()
    token_read, token_write = os.pipe()

    def make_controlling_tty() -> None:
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [
            "bash",
            script,
            "connect",
            "--endpoint",
            endpoint,
            "--token-stdin",
            "myteam",
        ],
        stdin=token_read,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        pass_fds=(slave_fd,),
        preexec_fn=make_controlling_tty,
    )
    os.close(token_read)
    os.close(slave_fd)
    os.write(token_write, token)
    os.close(token_write)

    output = bytearray()
    choice_sent = False
    identity_sent = False
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master_fd], [], [], 0.05)
        if readable:
            try:
                chunk = os.read(master_fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                if process.poll() is not None:
                    break
            else:
                output.extend(chunk)

        if not choice_sent and b"[i/g/a]" in output:
            os.write(master_fd, b"g\n" if mode == "generate" else b"i\n")
            choice_sent = True

        if (
            mode == "import"
            and choice_sent
            and not identity_sent
            and b"Paste identity:" in output
        ):
            echo_deadline = time.monotonic() + 2
            while echo_enabled(master_fd) and time.monotonic() < echo_deadline:
                time.sleep(0.01)
            if echo_enabled(master_fd):
                process.kill()
                raise RuntimeError("identity prompt did not disable terminal echo")
            assert identity is not None
            os.write(master_fd, identity + b"\n")
            identity_sent = True

        if process.poll() is not None and not readable:
            break

    if process.poll() is None:
        process.kill()
        process.wait()
        raise RuntimeError("remote connect PTY fixture timed out")

    while True:
        try:
            chunk = os.read(master_fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)
    os.close(master_fd)
    sys.stdout.buffer.write(output)
    return process.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"PTY fixture failed: {error}", file=sys.stderr)
        raise SystemExit(1)
