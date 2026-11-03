#!/usr/bin/env python3
"""select_sim.py -- replay recent main commits through a "changed files -> affected bats files"
selector and price the selection with measured CI seconds.

usage: python3 -I select_sim.py <repo-root> <scratchpad-root> [n_commits=300]

Selector variants (closures computed once, at HEAD):
  strict : static closure, recursion through source/exec only
  call   : static closure, recursion also through "path handed to a function/unknown command"
  call+dyn: call closure UNION the strace read-set where one exists (Linux only)
Every variant adds the always-run triggers:
  * a changed file that does not exist at HEAD and lives under scripts/, tests/, bin/,
    install.sh/setup.sh/uninstall.sh, package.json -> run everything (its readers cannot be known);
  * .github/workflows/tests.yml or .github/scripts/run-bats-timed.sh / shard-tests.sh -> run everything
    (they change how every test runs, not only the tests that read them);
  * whole-tree readers (tests whose closure or strace set covers >= 150 files) run on any
    change under scripts/.
Cost = macos_max + ubuntu_max seconds per test file from timings-41607512279.tsv
(full run = 7195 s macOS + 4069 s ubuntu).
Writes survey/deps/select_sim.json and select_sim_commits.tsv.
"""
import collections
import glob
import json
import os
import subprocess
import sys

root = sys.argv[1].rstrip("/")
S = sys.argv[2].rstrip("/")
N = int(sys.argv[3]) if len(sys.argv) > 3 else 300
D = S + "/survey/deps"


def load_closure(path):
    out = collections.defaultdict(set)
    with open(path) as fh:
        next(fh)
        for line in fh:
            t, d, _v = line.rstrip("\n").split("\t")
            out[t].add(d)
    return out


cost = {}
with open(S + "/timings-41607512279.tsv") as fh:
    next(fh)
    for line in fh:
        r = line.rstrip("\n").split("\t")
        cost["tests/" + r[0]] = (float(r[1]), float(r[3]))
TOT_M = sum(c[0] for c in cost.values())
TOT_U = sum(c[1] for c in cost.values())

cl = {m: load_closure(D + "/static_closure_%s.tsv" % m) for m in ("strict", "call")}
tests = sorted(cl["call"])
dyn = {}
for p in glob.glob(S + "/survey/strace/reads/*.tsv"):
    b = os.path.basename(p)[:-4]
    norm = D + "/dyn_reads/%s.tsv" % b
    src = norm if os.path.exists(norm) else p
    s = set()
    for line in open(src):
        r = line.rstrip("\n").split("\t")
        if len(r) >= 3 and r[1] != "probe":
            s.add(r[0])
    dyn["tests/%s.bats" % b] = s
cl["call+dyn"] = {t: cl["call"][t] | dyn.get(t, set()) for t in tests}
head_files = set(subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True).stdout.split("\n")) - {""}
# whole-tree readers: strace saw >= 150 repo files (copy / digest / git grep), plus the bats files
# that run a node test which copies or digests scripts/ (patterns.py: test-whole-tree-copy-or-digest)
whole = {t for t in tests if len(dyn.get(t, ())) >= 150}
for line in open(D + "/patterns.tsv"):
    r = line.rstrip("\n").split("\t")
    if len(r) > 2 and r[0] in ("test-whole-tree-copy-or-digest", "test-git-grep", "test-scanner-script"):
        src = r[1]
        # a .bats source is the test itself; a node test (.mjs) counts for the bats files that run it
        whole |= {t for t in tests if t == src or (not src.endswith(".bats") and src in cl["call"][t])}
RUN_ALL_CI = {".github/workflows/tests.yml", ".github/scripts/run-bats-timed.sh", ".github/scripts/shard-tests.sh"}
CODE_PREFIX = ("scripts/", "tests/", "bin/")
CODE_TOP = {"install.sh", "setup.sh", "uninstall.sh", "package.json", "VERSION"}

# reverse index
rev = {m: collections.defaultdict(set) for m in cl}
for m in cl:
    for t in tests:
        for f in cl[m][t]:
            rev[m][f].add(t)

log = subprocess.run(["git", "-C", root, "log", "--first-parent", "-m", "--name-only", "--format=@@%h %ad %s",
                      "--date=short", "-n", str(N), "HEAD"], capture_output=True, text=True).stdout
commits = []
cur = None
for line in log.split("\n"):
    if line.startswith("@@"):
        cur = {"id": line[2:].split(" ", 1)[0], "subject": line[2:], "files": []}
        commits.append(cur)
    elif line.strip() and cur is not None:
        cur["files"].append(line.strip())


def select(mode, files):
    sel, reasons = set(), set()
    for f in files:
        if f in RUN_ALL_CI:
            reasons.add("ci-config")
            return set(tests), reasons
        if f not in head_files and (f.startswith(CODE_PREFIX) or f in CODE_TOP):
            reasons.add("unknown-file")
            return set(tests), reasons
        sel |= rev[mode].get(f, set())
        if f.startswith("scripts/"):
            sel |= whole
    return sel, reasons


rows = []
agg = {m: [] for m in cl}
for c in commits:
    if not c["files"]:
        continue
    rec = {"id": c["id"], "n_files": len(c["files"]), "subject": c["subject"][:100]}
    for m in cl:
        sel, why = select(m, c["files"])
        cm = sum(cost.get(t, (0, 0))[0] for t in sel)
        cu = sum(cost.get(t, (0, 0))[1] for t in sel)
        frac = (cm + cu) / (TOT_M + TOT_U)
        rec[m] = {"n_tests": len(sel), "frac": round(frac, 4), "macos_s": cm, "ubuntu_s": cu, "why": sorted(why)}
        agg[m].append(frac)
    rows.append(rec)


def stats(v):
    v = sorted(v)
    n = len(v)
    return {"commits": n, "mean": round(sum(v) / n, 4), "median": round(v[n // 2], 4),
            "p75": round(v[int(n * 0.75)], 4), "p90": round(v[int(n * 0.9)], 4),
            "share_zero": round(sum(1 for x in v if x == 0) / n, 3),
            "share_ge_80pct": round(sum(1 for x in v if x >= 0.8) / n, 3),
            "share_ge_95pct": round(sum(1 for x in v if x >= 0.95) / n, 3)}


# blast radius of single files: most widely read, and most frequently changed
changed_count = collections.Counter(f for c in commits for f in set(c["files"]))
blast = {}
for f in set(list(changed_count)[:0]) | {f for f, _ in changed_count.most_common(40)} | {
        "scripts/lib/compat.sh", "scripts/lib/storage.sh", "scripts/lib/validate.sh", "scripts/lib/sqlpath.sh",
        "scripts/internal/init-db.sh", "tests/test_helper.bash", "scripts/lib/driver-registry.sh",
        "scripts/lib/instance-id.sh", "scripts/lib/registry-lock.sh", "scripts/lib/type-registry.sh",
        "scripts/lib/actas-lock.sh", "scripts/lib/resolve-project.sh", "scripts/lib/terminal-registry.sh",
        "scripts/drivers/storage/sqlite.sh", "scripts/send.sh", "scripts/watch.sh", "scripts/join.sh"}:
    out = {"changed_in_commits": changed_count.get(f, 0), "exists_at_head": f in head_files}
    for m in cl:
        sel, why = select(m, [f])
        out[m] = {"n_tests": len(sel),
                  "frac": round((sum(cost.get(t, (0, 0))[0] + cost.get(t, (0, 0))[1] for t in sel)) / (TOT_M + TOT_U), 3)}
    blast[f] = out
summary = {"n_commits": len(rows), "range": [rows[-1]["id"], rows[0]["id"]] if rows else None,
           "total_seconds": {"macos": TOT_M, "ubuntu": TOT_U}, "whole_tree_readers": sorted(whole),
           "whole_tree_seconds": {"macos": sum(cost.get(t, (0, 0))[0] for t in whole),
                                  "ubuntu": sum(cost.get(t, (0, 0))[1] for t in whole)},
           "stats": {m: stats(agg[m]) for m in cl},
           "commits_run_all": {m: sum(1 for r in rows if r[m]["why"]) for m in cl},
           "blast_radius": dict(sorted(blast.items(), key=lambda kv: -kv[1]["call+dyn"]["frac"]))}
with open(D + "/select_sim.json", "w") as fh:
    json.dump(summary, fh, indent=1)
with open(D + "/select_sim_commits.tsv", "w") as fh:
    fh.write("commit\tn_files\tstrict_tests\tstrict_frac\tcall_tests\tcall_frac\tcalldyn_tests\tcalldyn_frac\trun_all_reason\tsubject\n")
    for r in rows:
        fh.write("%s\t%d\t%d\t%.3f\t%d\t%.3f\t%d\t%.3f\t%s\t%s\n" % (
            r["id"], r["n_files"], r["strict"]["n_tests"], r["strict"]["frac"], r["call"]["n_tests"], r["call"]["frac"],
            r["call+dyn"]["n_tests"], r["call+dyn"]["frac"], ",".join(r["call+dyn"]["why"]), r["subject"].replace("\t", " ")))
print(json.dumps(summary["stats"], indent=1))
print("run-all commits:", summary["commits_run_all"], "range:", summary["range"])


# ---- restricted to the test files that have a strace read-set (and are not whole-tree readers):
# how much tighter would a dynamic-only selector be than the static one, on the same tests?
cov = sorted(t for t in dyn if t in cost and t not in whole)
cov_tot = sum(cost[t][0] + cost[t][1] for t in cov)
res = {"static_call": [], "dyn_only": [], "union": []}
for c in commits:
    if not c["files"]:
        continue
    ci = any(f in RUN_ALL_CI or (f not in head_files and (f.startswith(CODE_PREFIX) or f in CODE_TOP)) for f in c["files"])
    fs = set(c["files"])
    for name, sets in (("static_call", cl["call"]), ("dyn_only", {t: dyn[t] | {t} for t in cov}),
                       ("union", cl["call+dyn"])):
        sel = set(cov) if ci else {t for t in cov if sets[t] & fs}
        res[name].append(sum(cost[t][0] + cost[t][1] for t in sel) / cov_tot)
restricted = {"tests": len(cov), "ci_seconds": cov_tot, "stats": {k: stats(v) for k, v in res.items()}}
summary["restricted_to_dyn_covered"] = restricted
with open(D + "/select_sim.json", "w") as fh:
    json.dump(summary, fh, indent=1)
print("restricted to %d dyn-covered tests (%.0f s):" % (len(cov), cov_tot))
for k, v in restricted["stats"].items():
    print("  %-12s mean=%.3f median=%.3f p75=%.3f share>=80%%=%.3f" % (k, v["mean"], v["median"], v["p75"], v["share_ge_80pct"]))
