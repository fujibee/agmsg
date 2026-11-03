#!/usr/bin/env python3
"""Per-test durations from a tests.yml run-logs zip.

Usage: per_test_from_logs.py <logs.zip> <out.tsv>

Reads every top-level "N_bats (<os> <shard>_<total>).txt" job log. GitHub
prefixes each log line with an ISO timestamp (100 ns precision). bats prints
"ok N name" / "not ok N name" when test N finishes, so test N's duration is
the gap since the previous TAP line of the same file (the plan line "1..M"
for test 1, which therefore also absorbs setup_file). run-bats-timed.sh
prints "bats timing: start <file>" before each file.
"""
import datetime
import re
import sys
import zipfile

TS = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.(\d+)Z (.*)$")
JOB = re.compile(r"^\d+_bats \((macos-latest|ubuntu-latest) (\d+)_(\d+)\)\.txt$")
TAP = re.compile(r"^(ok|not ok) (\d+) (.*)$")


def parse_ts(date, frac):
    base = datetime.datetime.strptime(date, "%Y-%m-%dT%H:%M:%S")
    return base.timestamp() + float("0." + frac)


def main():
    zpath, out = sys.argv[1], sys.argv[2]
    z = zipfile.ZipFile(zpath)
    rows = []
    for name in sorted(z.namelist()):
        m = JOB.match(name)
        if not m:
            continue
        os_name, shard = m.group(1), m.group(2)
        cur_file, last_t = None, None
        for raw in z.read(name).decode("utf-8", "replace").splitlines():
            tm = TS.match(raw)
            if not tm:
                continue
            t = parse_ts(tm.group(1), tm.group(2))
            line = tm.group(3)
            if line.startswith("bats timing: start "):
                cur_file = line.split()[3].rsplit("/", 1)[-1]
                last_t = t
                continue
            if cur_file is None:
                continue
            if re.match(r"^1\.\.\d+$", line):
                last_t = t
                continue
            tp = TAP.match(line)
            if tp:
                status = tp.group(1)
                title = tp.group(3)
                if " # skip" in title:
                    status = "skip"
                dur = t - last_t if last_t is not None else 0.0
                rows.append((os_name, shard, cur_file, tp.group(2), status, "%.3f" % dur, title.replace("\t", " ")[:200]))
                last_t = t
            elif line.startswith("bats timing: end "):
                cur_file = None
    with open(out, "w") as fh:
        fh.write("os\tshard\tfile\ttest_num\tstatus\tseconds\ttitle\n")
        for r in rows:
            fh.write("\t".join(r) + "\n")
    print("tests parsed:", len(rows))


if __name__ == "__main__":
    main()
