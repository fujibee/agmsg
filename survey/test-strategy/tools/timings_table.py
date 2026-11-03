#!/usr/bin/env python3
"""Build a per-file seconds table from bats-timings artifact zips.

Usage: timings_table.py <out.tsv> <artifact-dir> [<artifact-dir> ...]

Each artifact dir holds bats-timings-*.zip files (each containing
bats-timings.tsv, schema 1). For every (file, os) the table keeps the
elapsed seconds of each run that recorded a file_end row, and reports
the max and the count of observations. Shard totals are printed to
stderr per run/os so the partition balance can be checked.
"""
import collections
import io
import os
import sys
import zipfile


def rows(path):
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if not name.endswith(".tsv"):
                continue
            text = z.read(name).decode("utf-8", "replace")
            reader = io.StringIO(text)
            header = reader.readline().rstrip("\n").split("\t")
            for line in reader:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != len(header):
                    continue
                yield dict(zip(header, parts))


def main():
    out = sys.argv[1]
    dirs = sys.argv[2:]
    obs = collections.defaultdict(list)  # (file, os) -> [(run, secs, status)]
    shard_tot = collections.defaultdict(int)
    for d in dirs:
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".zip"):
                continue
            for r in rows(os.path.join(d, fn)):
                if r.get("record") != "file_end":
                    continue
                try:
                    secs = int(r["elapsed_seconds"])
                except ValueError:
                    continue
                base = os.path.basename(r["file"])
                obs[(base, r["os"])].append((r["run_id"], secs, r["status"]))
                shard_tot[(r["run_id"], r["os"], r["shard"])] += secs
    files = sorted({f for f, _ in obs})
    with open(out, "w") as fh:
        fh.write("file\tmacos_max\tmacos_n\tubuntu_max\tubuntu_n\tmacos_all\tubuntu_all\n")
        for f in files:
            mac = obs.get((f, "macOS"), [])
            lin = obs.get((f, "Linux"), [])
            fh.write("\t".join([
                f,
                str(max((s for _, s, _ in mac), default=-1)),
                str(len(mac)),
                str(max((s for _, s, _ in lin), default=-1)),
                str(len(lin)),
                ",".join(str(s) for _, s, _ in mac),
                ",".join(str(s) for _, s, _ in lin),
            ]) + "\n")
    for k in sorted(shard_tot):
        sys.stderr.write("run %s %s shard %s: %d s\n" % (k[0], k[1], k[2], shard_tot[k]))


if __name__ == "__main__":
    main()
