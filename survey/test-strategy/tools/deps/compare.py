#!/usr/bin/env python3
"""compare.py -- static closures vs strace read-sets, per bats file.

usage: python3 -I compare.py <scratchpad-root>

Dynamic set of a test file = tracked repo files it exec'd or opened read-only (kind
exec|read; probes = failed opens are kept apart). Source per file: the '..'-normalized
re-extraction survey/deps/dyn_reads/<b>.tsv when it exists, else the sweep's own
survey/strace/reads/<b>.tsv (which drops every path that contains '..').

Copy-burst cleaning ("clean" sets): a node fixture that does cpSync(repo/scripts, ...)
opens every file under scripts/ once per copy, and strace cannot tell that from a real
read (the sweep only filters cp/rsync/tar...). If >= 100 scripts/ files share one read
count c in a test file, files read exactly c times (and never exec'd) are treated as
copy noise and dropped; files read more than c times keep.

Writes into survey/deps/:
  compare_per_test.tsv, fanin.tsv, compare_summary.json
"""
import collections
import glob
import json
import os
import sys

MODES = ("strict", "call", "loose")


def load_closure(path):
    out = collections.defaultdict(dict)
    with open(path) as fh:
        next(fh)
        for line in fh:
            t, d, via = line.rstrip("\n").split("\t")
            out[t][d] = via
    return out


def load_dyn(path):
    reads, execs, probes, dotdot = {}, set(), set(), set()
    with open(path) as fh:
        for line in fh:
            r = line.rstrip("\n").split("\t")
            if len(r) < 3:
                continue
            if r[1] == "probe":
                probes.add(r[0])
                continue
            if r[1] == "exec":
                execs.add(r[0])
            else:
                reads[r[0]] = int(r[2])
            if len(r) > 3 and r[3] == "1":
                dotdot.add(r[0])
    raw = set(reads) | execs
    counts = collections.Counter(n for f, n in reads.items() if f.startswith("scripts/"))
    noise = set()
    if counts:
        c, k = counts.most_common(1)[0]
        if k >= 100:
            noise = {f for f, n in reads.items() if n == c and f not in execs}
    return raw, raw - noise, probes, dotdot, len(noise)


def prf(s, d):
    i = len(s & d)
    return (i / len(s) if s else 1.0), (i / len(d) if d else 1.0)


def main():
    S = sys.argv[1].rstrip("/")
    D = S + "/survey/deps"
    cl = {m: load_closure(D + "/static_closure_%s.tsv" % m) for m in MODES}
    tests = sorted(cl["strict"])
    dyn = {}
    for p in sorted(glob.glob(S + "/survey/strace/reads/*.tsv")) + sorted(glob.glob(D + "/dyn_reads/*.tsv")):
        b = os.path.basename(p)[:-4]
        t = "tests/%s.bats" % b
        if t not in cl["strict"]:
            continue
        norm = D + "/dyn_reads/%s.tsv" % b
        src = norm if os.path.exists(norm) else p
        if t in dyn and dyn[t]["src"] == "norm":
            continue
        raw, clean, probes, dotdot, nnoise = load_dyn(src)
        dyn[t] = {"src": "norm" if src == norm else "orig", "raw": raw, "clean": clean, "probes": probes,
                  "dotdot": dotdot, "noise": nnoise}
    # whole-tree readers: the test opens most of scripts/ (copy/digest/scan of the tree); their
    # per-file reads say nothing about which files matter, so they are reported apart.
    whole = sorted(t for t in dyn if len(dyn[t]["raw"]) >= 150)
    covered = sorted(t for t in dyn if t not in whole)
    rows, agg = [], collections.defaultdict(float)
    miss = {m: collections.Counter() for m in MODES}
    extra = {m: collections.Counter() for m in MODES}
    for t in covered:
        d = dyn[t]["clean"]
        r = {"test_file": t, "dyn_source": dyn[t]["src"], "n_dyn_raw": len(dyn[t]["raw"]), "n_dyn": len(d),
             "copy_noise": dyn[t]["noise"], "dotdot_recovered": len(dyn[t]["dotdot"])}
        for m in MODES:
            s = set(cl[m][t])
            p_, r_ = prf(s, d)
            r["n_" + m], r[m + "_prec"], r[m + "_recall"] = len(s), p_, r_
            r["miss_" + m] = sorted(d - s)
            for f in d - s:
                miss[m][f] += 1
            for f in s - d:
                extra[m][f] += 1
            agg[m + "_s"] += len(s)
            agg[m + "_i"] += len(s & d)
        r["n_union_call"] = len(set(cl["call"][t]) | d)
        agg["d"] += len(d)
        agg["d_raw"] += len(dyn[t]["raw"])
        rows.append(r)
    cols = ["test_file", "dyn_source", "n_dyn_raw", "copy_noise", "n_dyn"]
    for m in MODES:
        cols += ["n_" + m, m + "_prec", m + "_recall"]
    cols += ["n_union_call", "miss_strict", "miss_call"]
    with open(D + "/compare_per_test.tsv", "w") as fh:
        fh.write("\t".join(cols) + "\n")
        for r in rows:
            out = []
            for c in cols:
                v = r[c]
                out.append("%.3f" % v if isinstance(v, float) else (",".join(v) if isinstance(v, list) else str(v)))
            fh.write("\t".join(out) + "\n")
    fan = collections.defaultdict(lambda: [0, 0, 0, 0, 0])
    for t in tests:
        for i, m in enumerate(MODES):
            for f in cl[m][t]:
                fan[f][i] += 1
    for t in covered:
        for f in dyn[t]["clean"]:
            fan[f][3] += 1
        for f in set(cl["call"][t]) | dyn[t]["clean"]:
            fan[f][4] += 1
    with open(D + "/fanin.tsv", "w") as fh:
        fh.write("file\ttests_strict\ttests_call\ttests_loose\ttests_dyn_of_%d\ttests_call_or_dyn_of_%d\n"
                 % (len(covered), len(covered)))
        for f, v in sorted(fan.items(), key=lambda kv: (-kv[1][1], kv[0])):
            fh.write("%s\t%d\t%d\t%d\t%d\t%d\n" % (f, v[0], v[1], v[2], v[3], v[4]))
    n = len(covered) or 1
    summary = {"tests_total": len(tests), "tests_with_dyn": len(covered) + len(whole),
               "whole_tree_readers": {t: {"n_dyn_raw": len(dyn[t]["raw"]), "n_dyn_clean": len(dyn[t]["clean"]), "n_call": len(cl["call"][t])} for t in whole},
               "tests_compared": len(covered),
               "dyn_norm": sum(1 for t in covered if dyn[t]["src"] == "norm"),
               "tests_with_copy_noise": sum(1 for t in covered if dyn[t]["noise"]),
               "avg_n_dyn_raw": agg["d_raw"] / n, "avg_n_dyn": agg["d"] / n,
               "avg_n_union_call": sum(r["n_union_call"] for r in rows) / n}
    for m in MODES:
        summary[m] = {
            "avg_size_on_covered": agg[m + "_s"] / n,
            "avg_size_all": sum(len(cl[m][t]) for t in tests) / len(tests),
            "micro_precision": agg[m + "_i"] / agg[m + "_s"] if agg[m + "_s"] else None,
            "micro_recall": agg[m + "_i"] / agg["d"] if agg["d"] else None,
            "macro_precision": sum(r[m + "_prec"] for r in rows) / n,
            "macro_recall": sum(r[m + "_recall"] for r in rows) / n,
            "tests_recall_1": sum(1 for r in rows if not r["miss_" + m]),
            "top_miss": miss[m].most_common(30),
            "top_static_only": extra[m].most_common(30),
        }
    summary["probes"] = {t: sorted(dyn[t]["probes"]) for t in covered if dyn[t]["probes"]}
    with open(D + "/compare_summary.json", "w") as fh:
        json.dump(summary, fh, indent=1)
    print("dyn files=%d, whole-tree readers excluded=%d %s; compared=%d (norm=%d, copy-noise cleaned=%d)  dyn avg raw=%.1f clean=%.1f" % (
        len(dyn), len(whole), [w[6:-5] for w in whole], len(covered), summary["dyn_norm"], summary["tests_with_copy_noise"],
        summary["avg_n_dyn_raw"], summary["avg_n_dyn"]))
    for m in MODES:
        x = summary[m]
        print("  %-6s size=%.1f  micro P=%.3f R=%.3f  macro P=%.3f R=%.3f  recall==1: %d/%d" % (
            m, x["avg_size_on_covered"], x["micro_precision"], x["micro_recall"], x["macro_precision"],
            x["macro_recall"], x["tests_recall_1"], len(covered)))


if __name__ == "__main__":
    main()
