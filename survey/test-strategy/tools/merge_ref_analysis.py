#!/usr/bin/env python3
"""Did a push-to-main run re-test a tree that a green PR run had already tested?

Usage: merge_ref_analysis.py <repo> <runs.tsv> <since-ISO> > report.txt

A pull_request run tests GitHub's merge ref: the PR head merged into the
base branch as it was at that moment. The listing only carries the head, so
the merge ref is reconstructed as `git merge-tree --write-tree <main tip at
the run's start> <head>`, where "main tip at time t" is the newest
first-parent commit of origin/main whose committer date is <= t (squash
merges are committed at merge time). A push run is a re-test when its
commit's tree equals the reconstructed tree of a green PR run (one that ran
the suite: wall >= 180 s) that finished before the push run started.
"""
import bisect
import collections
import datetime
import subprocess
import sys


def ts(x):
    return datetime.datetime.strptime(x, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def git(repo, *a):
    r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def main():
    repo, runs_tsv, since = sys.argv[1], sys.argv[2], ts(sys.argv[3])
    log = git(repo, "log", "--first-parent", "--format=%H %ct", "origin/main")[1].splitlines()
    mains = sorted((int(t), h) for h, t in (l.split() for l in log))
    times = [t for t, _ in mains]

    def main_at(t):
        i = bisect.bisect_right(times, t) - 1
        return mains[i][1] if i >= 0 else None

    runs = []
    for line in open(runs_tsv):
        p = line.rstrip("\n").split("\t")
        if len(p) < 11 or p[3] != "completed" or p[2] not in ("push", "pull_request"):
            continue
        st, en = ts(p[8]), ts(p[9])
        if st < since - 3 * 86400:
            continue
        runs.append(dict(id=p[0], event=p[2], concl=p[4], sha=p[6], start=st, end=en,
                         wall=en - st, title=p[11] if len(p) > 11 else ""))
    runs.sort(key=lambda r: r["start"])
    trees = {}

    def tree(sha):
        if sha not in trees:
            trees[sha] = git(repo, "rev-parse", sha + "^{tree}")[1]
        return trees[sha]

    for r in runs:
        if r["event"] != "pull_request":
            continue
        base = main_at(r["start"])
        rc, out = git(repo, "merge-tree", "--write-tree", base, r["sha"])
        r["mtree"] = out.splitlines()[0] if rc == 0 and out else None
        r["conflict"] = rc != 0
        r["uptodate"] = git(repo, "merge-base", "--is-ancestor", base, r["sha"])[0] == 0

    prs = [r for r in runs if r["event"] == "pull_request" and r["start"] >= since]
    push = [r for r in runs if r["event"] == "push" and r["start"] >= since]
    green_pr = [r for r in runs if r["event"] == "pull_request" and r["concl"] == "success"
                and r["wall"] >= 180 and r.get("mtree")]
    print("pull_request runs since cutoff: %d (merge-tree conflict/fail: %d; head already contained the main tip: %d)" % (
        len(prs), sum(1 for r in prs if r.get("conflict")), sum(1 for r in prs if r.get("uptodate"))))
    print("push runs since cutoff: %d %s" % (len(push), dict(collections.Counter(r["concl"] for r in push))))
    hit_rows, rows = [], []
    for r in push:
        t = tree(r["sha"])
        h = [g for g in green_pr if g["mtree"] == t and g["end"] <= r["start"]]
        rows.append("%s\t%s\t%.0f\t%s\t%s" % (r["id"], r["concl"], r["wall"], "yes" if h else "no", r["title"][:60]))
        if h:
            hit_rows.append(r)
    ex = [r for r in push if r["wall"] >= 180]
    exh = [r for r in hit_rows if r["wall"] >= 180]
    print("push runs re-testing a tree an earlier green PR run had tested: %d of %d" % (len(hit_rows), len(push)))
    print("  of the %d push runs that ran the suite (>= 180 s): %d re-tests" % (len(ex), len(exh)))
    print("run_id\tconclusion\twall_s\tretest\ttitle")
    print("\n".join(rows))


if __name__ == "__main__":
    main()
