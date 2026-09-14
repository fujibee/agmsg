#!/usr/bin/env python3
"""Emit one atomic process identity snapshot on macOS.

libproc's BSD process record includes the parent pid, state, and a
microsecond-resolution start timestamp. Keeping these values in one kernel
snapshot avoids the torn identity that separate ps calls can produce.
"""
import ctypes
import errno
import struct
import sys

PROC_PIDTBSDINFO = 3
PROC_BSDINFO_SIZE = 136
STATE_ZOMBIE = 5


def main(pid):
    try:
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        libproc.proc_pidinfo.restype = ctypes.c_int
        buf = ctypes.create_string_buffer(PROC_BSDINFO_SIZE)
        size = libproc.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buf, PROC_BSDINFO_SIZE)
    except OSError:
        return 2
    if size == 0 or (size < 0 and ctypes.get_errno() == errno.ESRCH):
        return 1
    if size < PROC_BSDINFO_SIZE:
        return 2
    raw = buf.raw
    ppid = struct.unpack_from('<I', raw, 16)[0]
    status = struct.unpack_from('<I', raw, 4)[0]
    sec = struct.unpack_from('<Q', raw, 120)[0]
    usec = struct.unpack_from('<Q', raw, 128)[0]
    if not sec or usec >= 1_000_000:
        return 2
    state = 'Z' if status == STATE_ZOMBIE else 'R'
    print(f'{ppid}\t{state}\tdarwin:{sec}:{usec:06d}')
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        raise SystemExit(2)
    raise SystemExit(main(int(sys.argv[1])))
