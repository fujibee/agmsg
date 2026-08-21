# tests/perf — measuring a history-proportional join (#910)

A team with 17,300 messages took over four hours to join and came out unreadable; a team with 50 takes ten seconds and looks fine. That ratio is why the defect survived every development-sized run (#910). This directory exists so the large case can be measured by anyone, repeatedly, on a machine that holds no real data — instead of consuming the one reproduction that exists.

## Run it

```sh
tests/perf/join-harness.sh --sizes 50,1000                 # join a team with history, two sizes, compared
tests/perf/join-harness.sh --scenario push --sizes 50,1000 # connect a local team with history, drain the engine
tests/perf/join-harness.sh --messages 17300 --keep         # one size; keep the run directory
```

Needs `python3`, `node`, `sqlite3`, `jq`, `curl` — what agmsg's remote sync already needs. No server, no container: the history is served by `tests/helpers/mock_remote_server.py` on a loopback port.

Every run prints a per-stage table and writes `summary.json`; with more than one size it also prints a comparison with a growth shape per stage (`linear` / `SUPERLINEAR` / `sublinear` / `negligible` / `n/a`) and a projection to `--project` messages (default 17,300). The raw material is kept: `events.jsonl` (the engine's own event log plus harness phase markers), `pull.stderr.ts` (the bootstrap's progress lines, timestamped on arrival), `state.json` (what the store holds at the end).

## What is measured, and how

**The shipped path, unmodified.** The harness copies `scripts/` into a private directory and runs the product's own commands in it — `remote.sh pull`, the engine (`remote-sync.sh once` / the `run` loop that `connect` starts), `remote-sync.sh reprocess` — with `AGMSG_STORAGE_PATH`, `HOME` and the team registry all inside that directory. It never reads or writes an operator's `~/.agents`, `db/` or `teams/`. No driver is wrapped and no code path is re-implemented: a harness that rewrote the path would be measuring its rewrite.

**Stage times are differences between events the engine itself writes** (`scripts/internal/remote-sync.mjs` `event()`, millisecond timestamps, mirrored to `AGMSG_SYNC_LOG_FILE`), plus the bootstrap's stderr progress lines timestamped on arrival:

| stage | from → to | what sits in between |
|---|---|---|
| `bootstrap.fetch` | stderr `fetching messages after N` → `applying N messages` | `GET /v1/teams/<id>/messages`, one page |
| `bootstrap.apply` | stderr `applying N messages` → `pull.bootstrap.applied` | evaluate (JS) + roster driver apply + storage driver apply |
| `engine.prepare` / `once.prepare` | `capabilities` → `push.prepared` | storage driver prepare (roster prepare in parallel) |
| `engine.post+reconcile` / `once.post+reconcile` | `push.prepared` → `push.ack` | `POST /v1/messages` until the acks are back, **and** the storage driver reconcile of those acks — one stage, because the engine writes the acks through `reconcile` before it emits `push.ack` (`push.reconciled` follows in the same call). Splitting POST from reconcile needs an event at POST completion that the engine does not emit today. |
| `engine.fetch+evaluate` / `once.fetch+evaluate` | previous event → `pull.received` | `GET /v1/messages` + evaluate (JS) |
| `engine.apply` / `once.apply` | `pull.received` → `pull.applied` | storage driver apply |
| `reprocess.total` | phase marker → `reprocess.complete` | driver reprocess pages + evaluate + apply (and two HTTP reads) |

#913 asked for `push.prepared` / POST complete / reconcile complete to split the 359 seconds of a push. This harness gives the first and the last; the middle one does not exist as an event, so POST and reconcile are reported together until it does.

**A missing event fails the run; it is never a zero.** `report.py` declares the events each phase must contain (`EXPECTED`) and exits 2 naming any that did not arrive. A stage whose input was empty (nothing to push, no quarantined rows) is reported as `[not exercised]`, and the comparison says `NOT EXERCISED` rather than `fast`.

**Conclusions are ratios, not numbers.** Two runs of the same input will not produce the same seconds; they will produce the same shape. `compare` classifies each stage by `time ratio / item ratio` between the smallest and largest run, so the verdict (`linear`, `SUPERLINEAR`) survives a loaded machine while the absolute seconds do not.

## Scenarios and coverage

| scenario | exercises | measured stages | does NOT exercise |
|---|---|---|---|
| `join` (default) | `remote.sh pull` of a team whose history lives on the server: bootstrap pages through the storage driver, then one explicit engine cycle and one explicit reprocess | `bootstrap.fetch`, `bootstrap.apply`; `once.*` (empty: fixed costs only); `reprocess.total` with 0 candidates | push, reconcile, reprocess of quarantined rows |
| `push` | a local team seeded with N messages, `remote.sh connect`, the engine's catch-up cycles until a cycle prepares nothing: prepare → POST → reconcile, and the pull side bringing every pushed message straight back (the echo-back #908 observed) | `engine.prepare`, `engine.post+reconcile`, `engine.fetch+evaluate`, `engine.apply` per cycle; then `once.*`, `reprocess.total` (0 candidates) | reprocess of quarantined rows; POST separately from reconcile |

**Not covered: the encrypted path (#916).** #910's 4,100 `unsupported_cipher` rows and the reprocess that should have cleared them — quarantine → `unlock` → `reprocess` on `age-v1` envelopes — is not exercised by either scenario. Both run with `cipher: none`, so `reprocess.total` always reports 0 candidates and is marked not exercised. A run of this harness therefore reproduces the history-proportional apply and push costs of #910 (and the reconcile shape of #912), not the unreadable-after-four-hours end state. Adding an `age-v1` history needs the `age` binary and a sealing step (`scripts/internal/sync-cipher.mjs seal-batch`); that is #916.

**Not reproduced: the total time.** The per-message rate matches #910 (below); the linear projection of it to 17,300 messages is about 1.25 h, and the real join took 4 h 23 min. That 3.5x is not explained by this harness. A run that is linear between two sizes can still hide a term that only appears at scale, so the report also prints the per-page (`bootstrap.apply per page: first … last … drift`) and per-cycle (`engine.apply per cycle`) readings within one run, and `summary.json` keeps the series. Read `ms/msg` at 50 as the rate the shipped path pays today, and the projection as a floor, not as the four hours.

## Synthetic history

`gen-history.py` writes the history the mock serves: `--roster R` `member_joined` mutations first (the roster travels as messages; a join that imports none ends with the empty roster #910 describes), then `--messages N` plain messages between those members, `--body-bytes` each. Deterministic — the same arguments give byte-identical output — so two runs of one size are runs of one input.

The mock serves it through the same paging as the reference server (the fixture paged nothing and answered a connected team with the pull fixture's binding before this; #915 tracks what the old answers may have let existing tests assert): `limit` defaults to 100 and must be 1..1000, the query is `LIMIT limit + 1`, `has_more` is whether a row past the page existed, `next_after` is the last returned sequence or the supplied `after` when the page is empty. That mirrors `server/src/storage.ts` `getMessages` (which both `/v1/messages` and `/v1/teams/<id>/messages` route through, `server/src/app.ts`) and `server/spec/v1.md` "GET /v1/messages".

The `push` scenario seeds its local team through the sqlite driver's own `_sqlite_message_sent_sql` (the INSERT `storage_send` issues, with placeholders filled per row), then verifies the count through `storage_history` before connecting. The seeding is a fixture and is reported separately (`seed`); it is not part of any measured stage.

## Reading a result

From the comparison on one machine (macOS, 2026-08-21), `join`, 50 vs 400 messages:

```
bootstrap.apply   256 ms/msg @50   259 ms/msg @400   linear   x8 items -> x8 time
-> 17,300 would take 1.25 h
```

That is #910's "5 messages per second" read off the shipped path, visible at 50 messages — the point of the table is that the number at 50 predicts the hour at 17,300, and a change that does not move `ms/msg` at 50 has not fixed it.
