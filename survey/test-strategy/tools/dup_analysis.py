#!/usr/bin/env python3
"""Estimate redundant test-file executions across tests.yml runs.

Usage:
  dup_analysis.py --repo R --runs runs.tsv --reads DIR --seconds per-file.tsv
                  --since ISO --out-prefix P [--min-exec-seconds 180]

A test file's execution in run X is counted REDUNDANT when the content of
every file it depends on (its closure) is identical to what some earlier
run had already tested GREEN, where "earlier" means that green run had
finished before X started. The closure of a test file is its dynamic
read-set (strace on Linux: files executed, read, or probed) plus
tests/test_helper.bash and .github/workflows/tests.yml; a test file with no
read-set falls back to "all tracked files under scripts/ and tests/" (never
redundant unless the whole tree matched).

Run classification:
  - executed: wall time (updated_at - run_started_at) >= --min-exec-seconds.
    Shorter runs are docs-only skips or the near-instant run a closed PR
    gets; they ran no test file.
  - green: conclusion == success. Failed runs contribute nothing to the
    green set (per-file pass/fail is not in the run listing).
  - cancelled runs ran part of the suite; they are counted with weight
    min(1, wall / full_wall) where full_wall is the median wall time of the
    green executed runs.
The tree a pull_request run tested is approximated by its head commit (the
merge ref is not in the listing); for an up-to-date branch they are equal.
"""
import argparse
import collections
import csv
import datetime
import hashlib
import os
import statistics
import subprocess
import sys

ALWAYS = ["tests/test_helper.bash", ".github/workflows/tests.yml"]


def ts(s):
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)


def tree_blobs(repo, sha, cache):
    if sha in cache:
        return cache[sha]
    r = git(repo, "ls-tree", "-r", sha)
    if r.returncode != 0:
        cache[sha] = None
        return None
    blobs = {}
    for line in r.stdout.splitlines():
        meta, path = line.split("\t", 1)
        blobs[path] = meta.split()[2]
    cache[sha] = blobs
    return blobs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--runs", required=True)
    ap.add_argument("--reads", required=True)
    ap.add_argument("--seconds", required=True)
    ap.add_argument("--since", required=True)
    ap.add_argument("--out-prefix", required=True)
    ap.add_argument("--min-exec-seconds", type=int, default=180)
    a = ap.parse_args()

    secs = {}
    for r in csv.DictReader(open(a.seconds), delimiter="\t"):
        secs[r["file"]] = (int(r["macos_s_run41607512279"]), int(r["ubuntu_s_run41607512279"]))
    test_files = sorted(secs)

    closure = {}
    for f in test_files:
        p = os.path.join(a.reads, f[:-5] + ".tsv")
        if os.path.exists(p) and os.path.getsize(p) > 0:
            deps = {line.split("\t")[0] for line in open(p) if line.strip()}
            deps.update(ALWAYS)
            deps.add("tests/" + f)
            closure[f] = sorted(deps)
        else:
            closure[f] = None

    since = ts(a.since)
    runs = []
    cols = ["id", "run_number", "event", "status", "conclusion", "head_branch", "head_sha",
            "created_at", "run_started_at", "updated_at", "run_attempt", "title"]
    seen = set()
    for line in open(a.runs):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 11:
            continue
        r = dict(zip(cols, parts + [""] * (12 - len(parts))))
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        if r["event"] not in ("push", "pull_request") or r["status"] != "completed":
            continue
        try:
            start, end = ts(r["run_started_at"]), ts(r["updated_at"])
        except ValueError:
            continue
        if start < since:
            continue
        r["start"], r["end"], r["wall"] = start, end, end - start
        runs.append(r)
    runs.sort(key=lambda r: r["start"])

    executed = [r for r in runs if r["wall"] >= a.min_exec_seconds]
    green_walls = [r["wall"] for r in executed if r["conclusion"] == "success"]
    full_wall = statistics.median(green_walls) if green_walls else 1800.0

    # The tree a run tested: a push run tests its commit; a pull_request run
    # tests GitHub's merge ref, reconstructed as the merge of the head into
    # the main tip at the run's start (falls back to the head on conflict).
    import bisect
    log = git(a.repo, "log", "--first-parent", "--format=%H %ct", "origin/main").stdout.splitlines()
    mains = sorted((int(t), h) for h, t in (l.split() for l in log))
    mtimes = [t for t, _ in mains]
    for r in executed:
        r["tested"] = r["head_sha"]
        if r["event"] == "pull_request":
            i = bisect.bisect_right(mtimes, r["start"]) - 1
            if i >= 0:
                mt = git(a.repo, "merge-tree", "--write-tree", mains[i][1], r["head_sha"])
                if mt.returncode == 0 and mt.stdout.strip():
                    r["tested"] = mt.stdout.split()[0]
    cache = {}
    missing = [r for r in executed if tree_blobs(a.repo, r["tested"], cache) is None]
    executed = [r for r in executed if cache.get(r["tested"]) is not None]

    def key(f, blobs):
        deps = closure[f]
        if deps is None:
            deps = [p for p in blobs if p.startswith("scripts/") or p.startswith("tests/")]
            deps.append(".github/workflows/tests.yml")
        h = hashlib.sha1()
        for d in deps:
            h.update(d.encode())
            h.update(b"\0")
            h.update(blobs.get(d, "-").encode())
            h.update(b"\n")
        return h.hexdigest()

    green = collections.defaultdict(list)  # f -> [(end_time, key)]
    per_file = collections.defaultdict(lambda: collections.Counter())
    tot = collections.Counter()
    by_event = collections.defaultdict(collections.Counter)
    tree_seen_green = []  # (end, tree)
    tree_dup_runs = collections.Counter()
    rows_out = []
    for r in executed:
        blobs = cache[r["tested"]]
        weight = 1.0 if r["conclusion"] != "cancelled" else min(1.0, r["wall"] / full_wall)
        tree = git(a.repo, "rev-parse", r["tested"] + "^{tree}").stdout.strip()
        tree_green_before = any(e <= r["start"] and t == tree for e, t in tree_seen_green)
        if tree_green_before:
            tree_dup_runs[r["event"]] += 1
        red_mac = red_lin = 0.0
        red_n = 0
        for f in test_files:
            k = key(f, blobs)
            r.setdefault("_keys", {})[f] = k
            redundant = any(e <= r["start"] and kk == k for e, kk in green[f])
            m, u = secs[f]
            per_file[f]["exec"] += weight
            tot["exec"] += weight
            tot["exec_mac_s"] += weight * m
            tot["exec_lin_s"] += weight * u
            by_event[r["event"]]["exec"] += weight
            by_event[r["event"]]["exec_mac_s"] += weight * m
            if redundant:
                per_file[f]["redundant"] += weight
                tot["redundant"] += weight
                tot["red_mac_s"] += weight * m
                tot["red_lin_s"] += weight * u
                by_event[r["event"]]["redundant"] += weight
                by_event[r["event"]]["red_mac_s"] += weight * m
                red_mac += weight * m
                red_lin += weight * u
                red_n += 1
        rows_out.append((r["id"], r["event"], r["conclusion"], r["head_sha"][:10], "%.0f" % r["wall"],
                         "%.2f" % weight, str(red_n), "%.0f" % red_mac, "%.0f" % red_lin,
                         "yes" if tree_green_before else "no", r["title"][:60]))
        if r["conclusion"] == "success":
            for f in test_files:
                green[f].append((r["end"], r["_keys"][f]))
            tree_seen_green.append((r["end"], tree))

    with open(a.out_prefix + "-runs.tsv", "w") as fh:
        fh.write("run_id\tevent\tconclusion\thead\twall_s\tweight\tredundant_files\tredundant_mac_s\tredundant_lin_s\ttree_already_green\ttitle\n")
        for row in rows_out:
            fh.write("\t".join(row) + "\n")
    with open(a.out_prefix + "-files.tsv", "w") as fh:
        fh.write("file\texecutions\tredundant\tredundant_pct\tmacos_s_each\tredundant_mac_s\tclosure_size\n")
        for f in sorted(test_files, key=lambda f: -per_file[f]["redundant"] * secs[f][0]):
            e, d = per_file[f]["exec"], per_file[f]["redundant"]
            fh.write("%s\t%.1f\t%.1f\t%.0f\t%d\t%.0f\t%s\n" % (
                f, e, d, 100 * d / e if e else 0, secs[f][0], d * secs[f][0],
                len(closure[f]) if closure[f] else "all"))
    print("runs listed since cutoff: %d; executed: %d; skipped as no-suite (< %ds): %d; head not fetchable: %d" % (
        len(runs), len(executed), a.min_exec_seconds, len(runs) - len(executed) - len(missing), len(missing)))
    print("executed by event/conclusion:", dict(collections.Counter((r["event"], r["conclusion"]) for r in executed)))
    print("median wall of green executed runs: %.0f s" % full_wall)
    print("test-file executions (weighted): %.0f; redundant: %.0f (%.1f%%)" % (
        tot["exec"], tot["redundant"], 100 * tot["redundant"] / max(tot["exec"], 1)))
    print("macOS bats seconds executed: %.0f; redundant: %.0f (%.1f%%)" % (
        tot["exec_mac_s"], tot["red_mac_s"], 100 * tot["red_mac_s"] / max(tot["exec_mac_s"], 1)))
    print("ubuntu bats seconds executed: %.0f; redundant: %.0f (%.1f%%)" % (
        tot["exec_lin_s"], tot["red_lin_s"], 100 * tot["red_lin_s"] / max(tot["exec_lin_s"], 1)))
    for ev, c in by_event.items():
        print("  %s: executions %.0f, redundant %.0f (%.1f%%), macOS s redundant %.0f of %.0f" % (
            ev, c["exec"], c["redundant"], 100 * c["redundant"] / max(c["exec"], 1), c["red_mac_s"], c["exec_mac_s"]))
    print("runs whose whole tree had already passed green before they started:", dict(tree_dup_runs))
    print("test files without a read-set (closure fallback = everything):", sum(1 for f in test_files if closure[f] is None))


if __name__ == "__main__":
    main()
