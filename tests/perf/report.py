#!/usr/bin/env python3
"""Turn one harness run's event log into per-stage seconds, and compare runs.

    report.py ts                       stdin -> stdout, each line prefixed with
                                       an ISO-8601 UTC millisecond timestamp
    report.py summarize --work DIR ... events.jsonl (+ pull.stderr.ts) -> summary.json
    report.py compare A.json B.json    ratio table and conclusions across sizes

Every stage time here is a DIFFERENCE BETWEEN TWO EVENTS the engine itself
wrote (scripts/internal/remote-sync.mjs `event()`, millisecond timestamps) or a
harness marker. Nothing is measured by wrapping a driver, so the path measured
is the shipped one.

The rule that makes those differences trustworthy: an event that did not
arrive is a FAILURE, never a zero. Each phase declares the events it expects
(EXPECTED below); a missing one exits 2 and names itself. A stage whose input
was empty (0 candidates, 0 pages) is reported as not exercised, not as fast.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

PROJECT_DEFAULT = 17300   # the team in #910

# --- shared -------------------------------------------------------------------


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def parse_iso(value):
    # 2026-08-21T08:31:22.123Z -> epoch seconds (float). The engine writes
    # toISOString(); the harness writes the same shape.
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
        tzinfo=timezone.utc).timestamp()


def cmd_ts():
    # stdout is the timestamped copy the report reads; progress lines are also
    # echoed to stderr so a long pull can be watched while it runs -- 75 minutes
    # that end in one number cannot be told from 75 minutes that stalled.
    out = sys.stdout
    for line in sys.stdin:
        out.write(f"{now_iso()} {line}")
        out.flush()
        if " fetching messages after " in line or " applying " in line:
            sys.stderr.write(f"join-harness:   {line.strip()}\n")
            sys.stderr.flush()


# --- summarize ----------------------------------------------------------------

# Events each phase MUST contain, per scenario. A phase missing one of these
# fails the report. The conditional ones (push.ack / push.reconciled only exist
# when something was pushed; bootstrap pages only on a bootstrap) are checked in
# code below, where the condition can be read off the other events.
EXPECTED = {
    "join": {
        "pull": ["pull.bootstrap.snapshot", "pull.bootstrap.applied"],
        "once": ["capabilities", "push.prepared", "pull.received", "pull.applied"],
        "reprocess": ["reprocess.complete"],
    },
    "unlock": {
        "pull": ["pull.bootstrap.snapshot", "pull.bootstrap.applied"],
        "unlock": ["configured", "reprocess.complete"],
        "once": ["capabilities", "push.prepared", "pull.received", "pull.applied"],
        "reprocess": ["reprocess.complete"],
    },
    "push": {
        "seed": ["harness.seed"],
        "engine": ["capabilities", "push.prepared", "push.posted", "push.ack", "push.reconciled",
                   "pull.received", "pull.applied"],
        "once": ["capabilities", "push.prepared", "pull.received", "pull.applied"],
        "reprocess": ["reprocess.complete"],
    },
}

FETCHING = re.compile(r"^(\S+) agmsg: \[\d+s\] fetching messages after ")
APPLYING = re.compile(r"^(\S+) agmsg: \[\d+s\] applying (\d+) messages")


class Stage:
    def __init__(self, name, unit):
        self.name = name
        self.unit = unit          # "msg" | "page" | "cycle" | "candidate"
        self.seconds = 0.0
        self.items = 0            # messages moved through this stage
        self.calls = 0            # pages / cycles / invocations summed
        self.note = ""
        self.exercised = True

    def add(self, seconds, items=0, calls=1):
        self.seconds += seconds
        self.items += items
        self.calls += calls

    def as_dict(self):
        per = (self.seconds * 1000.0 / self.items) if self.items > 0 else None
        return {"seconds": round(self.seconds, 3), "items": self.items,
                "unit": self.unit, "calls": self.calls,
                "ms_per_item": None if per is None else round(per, 3),
                "exercised": self.exercised, "note": self.note}


def load_events(path):
    events = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(f"report: {path}:{number}: not JSON: {error}")
            if "at" not in record or "event" not in record:
                raise SystemExit(f"report: {path}:{number}: no at/event: {line[:80]}")
            record["_t"] = parse_iso(record["at"])
            events.append(record)
    events.sort(key=lambda record: record["_t"])
    return events


def load_stderr(path):
    fetching, applying = [], []
    if not os.path.exists(path):
        return fetching, applying
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = FETCHING.match(line)
            if match:
                fetching.append(parse_iso(match.group(1)))
                continue
            match = APPLYING.match(line)
            if match:
                applying.append((parse_iso(match.group(1)), int(match.group(2))))
    return fetching, applying


def phase_windows(events):
    """[(phase, start_t, end_t)], from harness.phase markers, in order."""
    markers = [e for e in events if e["event"] == "harness.phase"]
    windows = []
    for index, marker in enumerate(markers):
        end = markers[index + 1]["_t"] if index + 1 < len(markers) else float("inf")
        windows.append((marker["phase"], marker["_t"], end))
    return windows


def in_window(events, start, end):
    return [e for e in events if start <= e["_t"] < end and e["event"] != "harness.phase"]


def cycles_of(events):
    """Split an engine window into cycles: each starts at a `capabilities` event."""
    cycles, current = [], None
    for event in events:
        if event["event"] == "capabilities":
            current = [event]
            cycles.append(current)
        elif current is not None:
            current.append(event)
    return cycles


def measure_cycle(cycle, stages, missing, label):
    """Stage times inside ONE engine cycle, from its event sequence."""
    by = {}
    for event in cycle:
        by.setdefault(event["event"], []).append(event)
    cap = by["capabilities"][0]
    prepared = by.get("push.prepared", [])
    if not prepared:
        missing.append(f"{label}: push.prepared")
        return
    prepared = prepared[0]
    stages["prepare"].add(prepared["_t"] - cap["_t"], prepared.get("count", 0))
    pushed = prepared.get("count", 0)
    last = prepared
    if pushed > 0 and "push.blocked" not in by:
        acks = by.get("push.ack", [])
        reconciled = by.get("push.reconciled", [])
        if not acks:
            missing.append(f"{label}: push.ack (push.prepared count={pushed})")
        if not reconciled:
            missing.append(f"{label}: push.reconciled (push.prepared count={pushed})")
        posted = by.get("push.posted", [])
        if acks and not posted:
            # push.ack is emitted only after the reconcile driver has run, and
            # push.reconciled follows it in the same call -- so without the
            # POST-completion event the two stages cannot be told apart, and
            # pretending otherwise would report the log's write latency as
            # "reconcile". The engine emits push.posted at that boundary; a
            # cycle that acked without it is unreported, not fast.
            missing.append(f"{label}: push.posted (push.ack arrived without the POST-completion event)")
        if acks and reconciled and posted:
            count = len(acks[0].get("acks", []))
            stages["post"].add(posted[0]["_t"] - prepared["_t"], count)
            stages["reconcile"].add(acks[0]["_t"] - posted[0]["_t"], count)
            last = reconciled[0]
    received = by.get("pull.received", [])
    applied = by.get("pull.applied", [])
    # Every cycle pulls at least one page -- the pull loop in cycle() always
    # runs once -- so a cycle with no pull.received is a cycle whose pull side
    # went unreported, not a quiet one. Checked per cycle: the phase-level
    # EXPECTED set would be satisfied by any one cycle's pages and hide this.
    if not received:
        missing.append(f"{label}: pull.received (a cycle always pulls at least one page)")
    if not applied:
        missing.append(f"{label}: pull.applied (a cycle always pulls at least one page)")
    if len(received) != len(applied):
        missing.append(f"{label}: pull.received={len(received)} but pull.applied={len(applied)}")
    for page_received, page_applied in zip(received, applied):
        count = len(page_received.get("messages", []))
        stages["fetch+evaluate"].add(page_received["_t"] - last["_t"], count)
        stages["apply"].add(page_applied["_t"] - page_received["_t"], count)
        last = page_applied


def summarize(args):
    events_path = os.path.join(args.work, "events.jsonl")
    if not os.path.exists(events_path):
        raise SystemExit(f"report: no events at {events_path}")
    events = load_events(events_path)
    windows = phase_windows(events)
    if not windows:
        raise SystemExit("report: events.jsonl holds no harness.phase markers")
    phases = {name: in_window(events, start, end) for name, start, end in windows}
    phase_wall = {name: (min(end, events[-1]["_t"]) - start) for name, start, end in windows}
    expected = EXPECTED[args.scenario]
    missing = []
    for phase, names in expected.items():
        if phase not in phases:
            missing.append(f"phase '{phase}' never started (no harness.phase marker)")
            continue
        have = {e["event"] for e in phases[phase]}
        for name in names:
            if name not in have:
                missing.append(f"{phase}: {name}")
    errors = [e for e in events if e["event"] in ("cycle.error", "fatal", "cycle.refused")]
    tolerated = []
    if args.scenario == "unlock":
        # `remote.sh unlock` runs `key.sh import`, whose _key_confirmed_epoch
        # probes the LOCAL age snapshot chain with `remote-sync.sh
        # export-age-snapshot ... >/dev/null 2>&1` and treats a non-zero exit
        # as "no chain here yet" (scripts/key.sh, "Non-zero (and silent) when
        # there is no chain to read"). On a machine that has never held the
        # key -- machine B, by construction -- that probe fails with this exact
        # message, and remote-sync.mjs main() still mirrors its `fatal` into
        # AGMSG_SYNC_LOG_FILE even though the caller discarded both streams.
        # It is the product's own tolerated probe, not a failed stage: it lands
        # in the unlock phase before `configured`, and unlock went on to
        # configure, reprocess and start the engine. Anything else stays an
        # error.
        window = next(((start, end) for name, start, end in windows if name == "unlock"), None)
        configured_at = min((e["_t"] for e in phases.get("unlock", []) if e["event"] == "configured"),
                            default=None)
        if window and configured_at is not None:
            probe = [e for e in errors if e["event"] == "fatal" and
                     e.get("message") == "team does not have one canonical initial age epoch" and
                     window[0] <= e["_t"] < configured_at]
            # Exactly one: key.sh import probes once. A second identical fatal
            # in that window is not the probe, and fail-closed means it stays an
            # error rather than riding along with the one that is.
            if len(probe) == 1:
                tolerated = probe
                errors = [e for e in errors if e is not probe[0]]

    stages = {}
    summary = {
        "scenario": args.scenario, "messages": args.messages, "roster": args.roster,
        "preloaded": args.preloaded,
        "page": args.page, "generated_at": now_iso(), "work": os.path.abspath(args.work),
        "phase_wall_seconds": {k: round(v, 3) for k, v in phase_wall.items()
                               if k != "done"},
    }

    # --- bootstrap (join and unlock) --------------------------------------
    if args.scenario in ("join", "unlock") and "pull" in phases:
        pull = phases["pull"]
        applied = [e for e in pull if e["event"] == "pull.bootstrap.applied"]
        fetching, applying = load_stderr(os.path.join(args.work, "pull.stderr.ts"))
        fetch = stages["bootstrap.fetch"] = Stage("bootstrap.fetch", "msg")
        apply = stages["bootstrap.apply"] = Stage("bootstrap.apply", "msg")
        if not (len(applied) == len(applying) == len(fetching)):
            missing.append(
                f"pull: {len(applied)} pull.bootstrap.applied events, but stderr shows "
                f"{len(fetching)} 'fetching' and {len(applying)} 'applying' lines "
                "(the bootstrap's own progress lines are the only timestamp before "
                "each page's apply; without them fetch and apply cannot be told apart)")
        else:
            for (t_apply, count), t_fetch, done in zip(applying, fetching, applied):
                fetch.add(t_apply - t_fetch, count)
                apply.add(done["_t"] - t_apply, count)
        total = sum(e.get("messages", 0) for e in applied)
        expected_total = args.messages + args.roster + args.preloaded
        if total != expected_total:
            missing.append(f"pull: bootstrap applied {total} messages, history holds {expected_total}")
        # Per page, in order: a stage that is linear between two SIZES can
        # still grow within one run (cost per row rising with the store), and
        # only the page series shows that. First/last ms per message is the
        # one-line reading; the series is in summary.json.
        pages = [{"messages": count, "apply_seconds": round(done["_t"] - t_apply, 3),
                  "ms_per_msg": round((done["_t"] - t_apply) * 1000.0 / count, 2) if count else None}
                 for (t_apply, count), done in zip(applying, applied)] \
            if len(applied) == len(applying) else []
        summary["bootstrap"] = {"pages": len(applied), "messages": total,
                                "wall_seconds": round(phase_wall.get("pull", 0), 3),
                                "page_series": pages}
        apply.note = "evaluate (JS) + roster driver + storage driver apply, per page"
        fetch.note = "GET /v1/teams/<id>/messages, per page"

    # --- engine catch-up (push only) -------------------------------------
    if args.scenario == "push":
        window = []
        for name in ("connect", "engine"):
            window.extend(phases.get(name, []))
        window.sort(key=lambda e: e["_t"])
        for name in ("prepare", "post", "reconcile", "fetch+evaluate", "apply"):
            stages["engine." + name] = Stage("engine." + name, "msg")
        engine_stages = {k[len("engine."):]: v for k, v in stages.items() if k.startswith("engine.")}
        cycles = cycles_of(window)
        cycle_series = []
        for index, cycle in enumerate(cycles, 1):
            before = {k: (v.seconds, v.items) for k, v in engine_stages.items()}
            measure_cycle(cycle, engine_stages, missing, f"engine cycle {index}")
            cycle_series.append({k: {"seconds": round(v.seconds - before[k][0], 3),
                                     "items": v.items - before[k][1]}
                                 for k, v in engine_stages.items()})
        prepared = [e for e in window if e["event"] == "push.prepared"]
        drained = bool(prepared) and prepared[-1].get("count", 0) == 0 and \
            any(e.get("count", 0) > 0 for e in prepared)
        timed_out = any(e["event"] == "harness.timeout" for e in events)
        if not drained and not timed_out:
            missing.append("engine: never reached a push.prepared with count 0 after pushing "
                           "(the drain marker); the harness should have waited for it")
        if not any(e.get("count", 0) > 0 for e in prepared):
            missing.append("engine: no push.prepared with count > 0 -- nothing was pushed")
        summary["engine"] = {
            "cycles": len(cycles), "drained": drained, "timed_out": timed_out,
            "pushed": sum(e.get("count", 0) for e in prepared),
            "acked": sum(len(e.get("acks", [])) for e in window if e["event"] == "push.ack"),
            "pulled_back": sum(len(e.get("messages", [])) for e in window
                               if e["event"] == "pull.received"),
            "batched_events": sum(1 for e in window if e["event"] == "push.batched"),
            "split_events": sum(1 for e in window if e["event"] == "push.split"),
            "wall_seconds": round(phase_wall.get("connect", 0) + phase_wall.get("engine", 0), 3),
            "cycle_series": cycle_series,
        }
        seed = [e for e in phases.get("seed", []) if e["event"] == "harness.seed"]
        if seed:
            summary["seed"] = {"messages": seed[0].get("count"), "seconds": seed[0].get("seconds")}
        engine_stages["prepare"].note = "driver prepare (+ roster prepare in parallel), per cycle"
        engine_stages["post"].note = "POST /v1/messages until the acks are back (push.prepared -> push.posted), per cycle"
        engine_stages["reconcile"].note = "driver reconcile of the acks (push.posted -> push.ack), per cycle"
        engine_stages["fetch+evaluate"].note = "GET /v1/messages + evaluate (JS); echo-back of own pushes"
        engine_stages["apply"].note = "driver apply of the echo-back page"

    # --- the unlock's reprocess (unlock only) -----------------------------
    if args.scenario == "unlock" and "unlock" in phases:
        stage = stages["unlock.reprocess"] = Stage("unlock.reprocess", "candidate")
        window = phases["unlock"]
        configured = [e for e in window if e["event"] == "configured"]
        complete = [e for e in window if e["event"] == "reprocess.complete"]
        if configured and complete:
            done = complete[0]
            count = done.get("count", 0)
            stage.add(done["_t"] - configured[0]["_t"], count)
            summary["unlock"] = {k: done.get(k) for k in ("count", "imported_count", "blocking_remaining")}
            summary["unlock"]["wall_seconds"] = round(phase_wall.get("unlock", 0), 3)
            if count != args.messages:
                missing.append(f"unlock: reprocess saw {count} candidates, the history holds {args.messages} sealed messages")
            if done.get("imported_count") != count:
                missing.append(f"unlock: reprocess imported {done.get('imported_count')} of {count} candidates "
                               "(the key was handed, so every row should import)")
            stage.note = ("remote-sync.sh reprocess as run by unlock: driver reprocess pages + "
                          "age-v1 open (JS) + driver apply, incl. 2 HTTP reads; no per-page event, so "
                          "the split between select / decrypt / apply is not available")
        elif configured and not complete:
            stage.exercised = False
            stage.note = "reprocess never completed"

    # --- one explicit cycle -----------------------------------------------
    if "once" in phases:
        for name in ("prepare", "post", "reconcile", "fetch+evaluate", "apply"):
            stages["once." + name] = Stage("once." + name, "msg")
        once_stages = {k[len("once."):]: v for k, v in stages.items() if k.startswith("once.")}
        cycles = cycles_of(phases["once"])
        if len(cycles) != 1:
            missing.append(f"once: expected exactly 1 capabilities event, saw {len(cycles)}")
        for cycle in cycles[:1]:
            measure_cycle(cycle, once_stages, missing, "once")
        for name in ("post", "reconcile"):
            if once_stages[name].calls == 0:
                once_stages[name].exercised = False
                once_stages[name].note = "nothing to push in this cycle: stage not exercised"

    # --- reprocess ----------------------------------------------------------
    if "reprocess" in phases:
        stage = stages["reprocess.total"] = Stage("reprocess.total", "candidate")
        complete = [e for e in phases["reprocess"] if e["event"] == "reprocess.complete"]
        marker = next(w for w in windows if w[0] == "reprocess")
        if complete:
            done = complete[0]
            stage.add(done["_t"] - marker[1], done.get("count", 0))
            summary["reprocess"] = {k: done.get(k) for k in
                                    ("count", "imported_count", "blocking_remaining")}
            if done.get("count", 0) == 0:
                stage.exercised = False
                stage.note = ("0 quarantined candidates: stage not exercised "
                              "(the walk ran, the re-evaluation did not)")
            else:
                stage.note = "driver reprocess pages + evaluate + apply, incl. 2 HTTP reads"

    # --- state, errors, verdict -------------------------------------------
    state_path = os.path.join(args.work, "state.json")
    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as handle:
            summary["state"] = json.load(handle)
    summary["stages"] = {name: stage.as_dict() for name, stage in stages.items()}
    summary["errors"] = [{k: v for k, v in e.items() if not k.startswith("_")} for e in errors]
    summary["tolerated"] = [{"event": e["event"], "message": e.get("message"), "at": e["at"],
                             "why": "key.sh import's export-age-snapshot probe on a machine with no chain"}
                            for e in tolerated]
    summary["missing"] = missing
    summary["ok"] = not missing and not errors

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print_summary(summary)
    if errors:
        print(f"\nENGINE ERRORS ({len(errors)}): the run is not a clean measurement", file=sys.stderr)
        for error in errors[:10]:
            print("  " + json.dumps({k: v for k, v in error.items() if not k.startswith("_")})[:300],
                  file=sys.stderr)
    if missing:
        print(f"\nMISSING EVENTS ({len(missing)}): a stage without its event is unmeasured, "
              "not fast", file=sys.stderr)
        for item in missing:
            print("  - " + item, file=sys.stderr)
    return 0 if summary["ok"] else 2


def fmt_seconds(value):
    return f"{value:9.3f}"


def print_summary(summary):
    print(f"\n== {summary['scenario']}  messages={summary['messages']}  "
          f"roster={summary['roster']}  page={summary['page']}")
    for key in ("bootstrap", "engine", "seed", "unlock", "reprocess"):
        if key in summary:
            print(f"   {key}: " + ", ".join(f"{k}={v}" for k, v in summary[key].items()
                                          if not k.endswith("_series")))
    # Drift is read between FULL pages / cycles only. A page carries a fixed
    # cost (a bash + sqlite spawn or two) on top of its per-row cost, so the
    # three-message tail page of a 2,003-message pull reads 500 ms/msg where
    # the thousand-message pages read 275 -- and "drift x1.8" would then be the
    # page size, not the store. Full = the largest page/cycle seen.
    pages = summary.get("bootstrap", {}).get("page_series") or []
    rated = [p for p in pages if p["ms_per_msg"] is not None]
    full = [p for p in rated if p["messages"] == max(p["messages"] for p in rated)] if rated else []
    if len(full) >= 2:
        print(f"   bootstrap.apply per full page ({full[0]['messages']} msgs): "
              f"first {full[0]['ms_per_msg']:.1f} ms/msg, last {full[-1]['ms_per_msg']:.1f} ms/msg "
              f"over {len(full)} of {len(rated)} pages"
              f" (drift x{full[-1]['ms_per_msg'] / max(full[0]['ms_per_msg'], 0.01):.2f})")
    elif len(rated) >= 2:
        print(f"   bootstrap.apply per page: {len(rated)} pages but only one full-size page; "
              "no drift reading (a short page's fixed cost would masquerade as drift)")
    cycles = summary.get("engine", {}).get("cycle_series") or []
    rated = [c["apply"] for c in cycles if c.get("apply", {}).get("items")]
    full = [c for c in rated if c["items"] == max(c["items"] for c in rated)] if rated else []
    if len(full) >= 2:
        first = full[0]["seconds"] * 1000 / full[0]["items"]
        last = full[-1]["seconds"] * 1000 / full[-1]["items"]
        print(f"   engine.apply per full cycle ({full[0]['items']} msgs): first {first:.1f} ms/msg, "
              f"last {last:.1f} ms/msg over {len(full)} of {len(rated)} cycles (drift x{last / max(first, 0.01):.2f})")
    elif len(rated) >= 2:
        print(f"   engine.apply per cycle: {len(rated)} cycles but only one full-size cycle; no drift reading")
    print(f"   phase wall: " + ", ".join(f"{k}={v}s" for k, v in summary["phase_wall_seconds"].items()))
    print(f"\n   {'stage':<24}{'seconds':>10}{'items':>8}{'calls':>7}{'ms/item':>10}  note")
    for name, stage in summary["stages"].items():
        per = "-" if stage["ms_per_item"] is None else f"{stage['ms_per_item']:.2f}"
        flag = "" if stage["exercised"] else "[not exercised] "
        print(f"   {name:<24}{fmt_seconds(stage['seconds']):>10}{stage['items']:>8}"
              f"{stage['calls']:>7}{per:>10}  {flag}{stage['note']}")
    if "state" in summary:
        print("\n   end state: " + json.dumps(summary["state"], sort_keys=True))
    print("\n   verdict: " + ("OK" if summary["ok"] else "INCOMPLETE (see below)"))


# --- compare ------------------------------------------------------------------

def classify(small, large):
    """Shape of a stage's growth between two sizes. Ratio-based so the verdict
    does not move when the absolute numbers do."""
    if not small["exercised"] or not large["exercised"]:
        return "n/a", "not exercised"
    if small["items"] == 0 or large["items"] == 0:
        return "n/a", "no items"
    if large["seconds"] < 0.2 and small["seconds"] < 0.2:
        return "negligible", "both under 0.2s"
    item_ratio = large["items"] / small["items"]
    if item_ratio <= 1.0:
        return "n/a", "sizes do not grow"
    time_ratio = large["seconds"] / max(small["seconds"], 0.001)
    k = time_ratio / item_ratio
    detail = f"x{item_ratio:.0f} items -> x{time_ratio:.0f} time"
    if k > 2.0:
        return "SUPERLINEAR", detail
    if k < 0.5:
        return "sublinear", detail
    return "linear", detail


def compare(args):
    runs = []
    for path in args.summaries:
        with open(path, encoding="utf-8") as handle:
            runs.append(json.load(handle))
    runs.sort(key=lambda run: run["messages"])
    if len({run["scenario"] for run in runs}) != 1:
        raise SystemExit("report compare: summaries are from different scenarios")
    scenario = runs[0]["scenario"]
    sizes = [run["messages"] for run in runs]
    names = [name for name in runs[0]["stages"] if all(name in run["stages"] for run in runs)]
    print(f"\n== compare {scenario}: sizes {', '.join(str(s) for s in sizes)}   "
          f"(projection to {args.project} messages uses the largest run's ms/item)")
    head = f"   {'stage':<22}" + "".join(f"{'s@' + str(s):>12}" for s in sizes) + \
        "".join(f"{'ms/i@' + str(s):>12}" for s in sizes) + f"{'shape':>13}  detail"
    print(head)
    conclusions = []
    small, large = runs[0], runs[-1]
    for name in names:
        cells = "".join(f"{run['stages'][name]['seconds']:>12.3f}" for run in runs)
        per = "".join(
            f"{'-' if run['stages'][name]['ms_per_item'] is None else format(run['stages'][name]['ms_per_item'], '.2f'):>12}"
            for run in runs)
        shape, detail = classify(small["stages"][name], large["stages"][name])
        print(f"   {name:<22}{cells}{per}{shape:>13}  {detail}")
        big = large["stages"][name]
        if shape == "SUPERLINEAR":
            conclusions.append(f"{name}: {detail} -- grows faster than the history; "
                               f"the dev-size run cannot predict the prod-size run")
        elif shape == "linear" and big["ms_per_item"] is not None:
            projected = big["ms_per_item"] * args.project / 1000.0
            conclusions.append(f"{name}: {big['ms_per_item']:.1f} ms/{big['unit']} "
                               f"-> {args.project:,} would take {human(projected)}")
        elif shape == "n/a" and not big["exercised"]:
            conclusions.append(f"{name}: NOT EXERCISED by this scenario ({big['note']})")
    ok = all(run["ok"] for run in runs)
    for run in runs:
        wall = sum(run["phase_wall_seconds"].values())
        print(f"   total wall @{run['messages']}: {human(wall)}"
              + ("" if run["ok"] else "   <-- INCOMPLETE run"))
    if small["messages"] > 0 and large["messages"] > small["messages"]:
        wall_small = sum(small["phase_wall_seconds"].values())
        wall_large = sum(large["phase_wall_seconds"].values())
        ratio = wall_large / max(wall_small, 0.001)
        item_ratio = large["messages"] / small["messages"]
        conclusions.insert(0, f"end to end: x{item_ratio:.0f} messages -> x{ratio:.0f} wall time "
                           f"({human(wall_small)} -> {human(wall_large)})")
    print("\n   conclusions:")
    for line in conclusions:
        print("   - " + line)
    if not ok:
        print("\n   (at least one run was INCOMPLETE: its numbers are not a measurement)")
    return 0 if ok else 2


def human(seconds):
    if seconds < 60:
        return f"{seconds:.1f}s"
    if seconds < 3600:
        return f"{seconds / 60:.1f} min"
    return f"{seconds / 3600:.2f} h"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ts")
    s = sub.add_parser("summarize")
    s.add_argument("--work", required=True)
    s.add_argument("--scenario", choices=("join", "push", "unlock"), required=True)
    s.add_argument("--messages", type=int, required=True)
    s.add_argument("--roster", type=int, required=True)
    s.add_argument("--page", type=int, required=True)
    s.add_argument("--preloaded", type=int, default=0,
                   help="unlock: plain messages served before the sealed ones (imported by the pull)")
    s.add_argument("--out", required=True)
    c = sub.add_parser("compare")
    c.add_argument("summaries", nargs="+")
    c.add_argument("--project", type=int, default=PROJECT_DEFAULT)
    args = parser.parse_args()
    if args.command == "ts":
        cmd_ts()
        return 0
    if args.command == "summarize":
        return summarize(args)
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
