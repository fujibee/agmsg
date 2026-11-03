#!/usr/bin/env python3
"""Map an `strace -f -e trace=execve,openat` log to repo files a bats file used.

Usage: extract_reads.py <repo-root> <trace-file>   (TSV on stdout)

Output rows: <repo-relative path> <TAB> <kind> <TAB> <count>
  kind = exec   the file was execve()d (a script run directly)
         read   opened read-only, successfully, by a process that is not a
                pure file-copying/listing tool (so cp -R of scripts/ in
                setup_test_env does not count as a read of every script)
         probe  an open of a mappable path that failed (ENOENT etc.)

Paths are mapped to repo files in two ways:
  - absolute paths under <repo-root> are made relative;
  - paths under a temp copy (setup_test_env copies scripts/ into a mktemp
    dir; install tests copy the tree into a sandbox HOME) are mapped by
    taking the suffix that starts at a repo top-level name and keeping it
    only if that suffix is a file that exists in the repo.
Processes are attributed by the last successful execve of the pid; a pid
seen before any execve (a forked bash subshell) counts as bash.
"""
import collections
import os
import re
import subprocess
import sys

EXCLUDE_EXE = {
    "cp", "rsync", "tar", "install", "cpio", "find", "ls", "stat", "rm",
    "chmod", "chown", "mv", "ln", "mkdir", "touch", "du", "readlink",
    "realpath", "dirname", "basename", "mktemp", "rmdir", "ditto",
}

LINE = re.compile(r"^(\d+)\s+(execve|openat)\((.*)\)\s+=\s+(-?\d+)(.*)$")
EXEC_ARGS = re.compile(r'^"((?:[^"\\]|\\.)*)"')
OPEN_ARGS = re.compile(r'^[^,]+,\s*"((?:[^"\\]|\\.)*)",\s*([A-Z_|]+)')


def repo_files(root):
    out = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True, check=True)
    return set(out.stdout.split("\n")) - {""}


def build_mapper(root, files):
    root = root.rstrip("/") + "/"
    tops = sorted({f.split("/", 1)[0] for f in files})

    def mapper(path):
        if path.startswith(root):
            rel = path[len(root):]
            return rel if rel in files else None
        if not path.startswith("/"):
            return path if path in files else None
        parts = path.split("/")
        for i in range(1, len(parts)):
            if parts[i] in tops:
                cand = "/".join(parts[i:])
                if cand in files:
                    return cand
        return None

    return mapper


def main():
    root, trace = sys.argv[1], sys.argv[2]
    files = repo_files(root)
    mapper = build_mapper(root, files)
    exe = {}
    counts = collections.Counter()
    with open(trace, errors="replace") as fh:
        for raw in fh:
            m = LINE.match(raw)
            if not m:
                continue
            pid, call, args, rc = m.group(1), m.group(2), m.group(3), int(m.group(4))
            if call == "execve":
                am = EXEC_ARGS.match(args)
                if not am:
                    continue
                path = am.group(1)
                if rc == 0:
                    exe[pid] = os.path.basename(path)
                    rel = mapper(path)
                    if rel:
                        counts[(rel, "exec")] += 1
                continue
            om = OPEN_ARGS.match(args)
            if not om:
                continue
            path, flags = om.group(1), om.group(2)
            if "O_WRONLY" in flags or "O_RDWR" in flags or "O_CREAT" in flags:
                continue
            if "O_DIRECTORY" in flags:
                continue
            who = exe.get(pid, "bash")
            if who in EXCLUDE_EXE:
                continue
            rel = mapper(path)
            if not rel:
                continue
            counts[(rel, "read" if rc >= 0 else "probe")] += 1
    for (rel, kind), n in sorted(counts.items()):
        print("%s\t%s\t%d" % (rel, kind, n))


if __name__ == "__main__":
    main()
