# tests/perf — measuring a history-proportional join (#910)

A team with 17,300 messages took over four hours to join and came out unreadable; a team with 50 takes ten seconds and looks fine. That ratio is why the defect survived every development-sized run (#910). This directory exists so the large case can be measured by anyone, repeatedly, on a machine that holds no real data — instead of consuming the one reproduction that exists.

## Run it

```sh
tests/perf/join-harness.sh --sizes 50,1000                 # join a team with history, two sizes, compared
tests/perf/join-harness.sh --scenario push --sizes 50,1000 # connect a local team with history, drain the engine
tests/perf/join-harness.sh --scenario unlock --sizes 50,400 # pull an age-v1 team without its key, unlock, measure the reprocess
tests/perf/join-harness.sh --scenario unlock --messages 400 --preloaded 5000   # same, against a store that already holds 5,000 imported rows
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
| `engine.post` / `once.post` | `push.prepared` → `push.posted` | `POST /v1/messages` until the acks are back |
| `engine.reconcile` / `once.reconcile` | `push.posted` → `push.ack` | storage driver reconcile of the acks (the engine writes them through `reconcile` before it emits `push.ack`; `push.posted` is the event at POST completion that makes the boundary visible, #913) |
| `engine.fetch+evaluate` / `once.fetch+evaluate` | previous event → `pull.received` | `GET /v1/messages` + evaluate (JS) |
| `engine.apply` / `once.apply` | `pull.received` → `pull.applied` | storage driver apply |
| `unlock.reprocess` | `configured` → `reprocess.complete` | the reprocess `remote.sh unlock` runs over every quarantined row: driver reprocess pages + age-v1 open (JS) + driver apply (and two HTTP reads). No per-page event exists inside `reprocessCycle`, so the split between select, decrypt and apply is not available — only the per-row total |
| `reprocess.total` | phase marker → `reprocess.complete` | an explicit `remote-sync.sh reprocess` after the scenario (0 candidates in every scenario: fixed cost only) |

`push.prepared` → `push.posted` → `push.ack` are the three timings #913 asked for to split the 359 seconds of a push. A cycle whose `push.ack` arrives without a `push.posted` is reported as missing, not as a zero-length POST.

**A missing event fails the run; it is never a zero.** `report.py` declares the events each phase must contain (`EXPECTED`) and exits 2 naming any that did not arrive. A stage whose input was empty (nothing to push, no quarantined rows) is reported as `[not exercised]`, and the comparison says `NOT EXERCISED` rather than `fast`.

**Conclusions are ratios, not numbers.** Two runs of the same input will not produce the same seconds; they will produce the same shape. `compare` classifies each stage by `time ratio / item ratio` between the smallest and largest run, so the verdict (`linear`, `SUPERLINEAR`) survives a loaded machine while the absolute seconds do not.

## Scenarios and coverage

| scenario | exercises | measured stages | does NOT exercise |
|---|---|---|---|
| `join` (default) | `remote.sh pull` of a team whose history lives on the server: bootstrap pages through the storage driver, then one explicit engine cycle and one explicit reprocess | `bootstrap.fetch`, `bootstrap.apply`; `once.*` (empty: fixed costs only); `reprocess.total` with 0 candidates | push, reconcile, reprocess of quarantined rows |
| `push` | a local team seeded with N messages, `remote.sh connect`, the engine's catch-up cycles until a cycle prepares nothing: prepare → POST → reconcile, and the pull side bringing every pushed message straight back (the echo-back #908 observed) | `engine.prepare`, `engine.post`, `engine.reconcile`, `engine.fetch+evaluate`, `engine.apply` per cycle; then `once.*`, `reprocess.total` (0 candidates) | reprocess of quarantined rows |
| `unlock` | a second private install ("machine A") runs `connect --e2ee` to mint the team's age key and `key.sh handoff`; the history is sealed to that key through `sync-cipher.mjs seal-batch`; machine B pulls it with no key (every message `unsupported_cipher`, engine halted — #910's end state), then `remote.sh unlock --bundle` confirms the handed authority and runs the reprocess over every quarantined row. `--preloaded M` serves M plain messages first, so the pull imports them and the reprocess runs against a store that already holds M | `bootstrap.fetch`, `bootstrap.apply` (quarantining); `unlock.reprocess` with N candidates; then `once.*`, `reprocess.total` (0 candidates) | the split inside the reprocess (select / decrypt / apply); push |

**The encrypted path (#916) is the `unlock` scenario.** #910's 4,100 `unsupported_cipher` rows and the reprocess that should have cleared them — quarantine → `unlock` → `reprocess` on `age-v1` envelopes — is what `--scenario unlock` runs, with `age` and `age-keygen` on PATH. `join` and `push` run with `cipher: none`, so their `reprocess.total` always has 0 candidates and is marked not exercised; only `unlock.reprocess` measures a reprocess that re-evaluates rows. What no scenario gives is the split inside that reprocess — `reprocessCycle` emits no per-page event, so select, decrypt and apply cannot be told apart from the log; adding one is the same shape as `push.posted` (an event plus a reader).

**Reproduced: the pull. Not reproduced: the reprocess.** The real four hours split in two on the engine's own timeline: a pull-bootstrap of 17,300 messages at 204 ms/msg (59 min), then a reprocess of the quarantined rows at 934 ms/msg (3 h 25 min, and it died at 13,200 of 17,300). This harness measures the first segment and matches it — 227–300 ms/msg here on a loaded machine, flat from page 1 to page 18 of a 17,300-message pull, so the pull side is linear and the development-size rate predicts the production-size hour. The second segment is `--scenario unlock`'s `unlock.reprocess` (#916): the same quarantine → unlock → reprocess path over N sealed rows, reported as a per-row cost. `join` alone does not cover it, and a 1.25 h `join` projection is not "the join". Within one run the report prints first-page vs last-page (`bootstrap.apply per full page … drift`) and first-cycle vs last-cycle (`engine.apply per full cycle`) so a term that grows with the store would show as drift; `summary.json` keeps the series.

## Synthetic history

`gen-history.py` writes the history the mock serves: `--roster R` `member_joined` mutations first (the roster travels as messages; a join that imports none ends with the empty roster #910 describes), then `--messages N` plain messages between those members, `--body-bytes` each. Deterministic — the same arguments give byte-identical output — so two runs of one size are runs of one input.

The mock serves it through the same paging as the reference server (the fixture paged nothing and answered a connected team with the pull fixture's binding before this; #915 tracks what the old answers may have let existing tests assert): `limit` defaults to 100 and must be 1..1000, the query is `LIMIT limit + 1`, `has_more` is whether a row past the page existed, `next_after` is the last returned sequence or the supplied `after` when the page is empty. That mirrors `server/src/storage.ts` `getMessages` (which both `/v1/messages` and `/v1/teams/<id>/messages` route through, `server/src/app.ts`) and `server/spec/v1.md` "GET /v1/messages".

The `push` scenario seeds its local team through the sqlite driver's own `_sqlite_message_sent_sql` (the INSERT `storage_send` issues, with placeholders filled per row), then verifies the count through `storage_history` before connecting. The seeding is a fixture and is reported separately (`seed`); it is not part of any measured stage.

## Isolating ciphertext duplication in apply (#957)

```sh
python3 tests/perf/apply-blob.py --baseline /path/to/baseline-checkout --out /tmp/apply-blob-run
```

This narrower benchmark copies both versions' scripts into private installs and creates synthetic SQLite stores through the baseline driver. It seeds 1,000 imported messages with 4,096-byte blobs and 100 pending messages, then applies the already-evaluated pending page at blob widths of 120, 4,096, and 16,384 bytes. Incoming projections remain 120 bytes, so only the incoming ciphertext width changes. These are storage fixtures, not valid age ciphertext; use the `unlock` scenario above for real encryption/decryption coverage. No operator store or key is read.

Five repetitions alternate before/after order. Each starts with a fresh backup of the same seed and verifies exact stored blobs, import counts, legacy mirrors, and idempotent replay. `apply_ms_per_message` times the unwrapped production adapter, including shell/JQ processing and SQLite. A separate, untimed wrapper captures the emitted SQL and counts copies of the first message's unique blob. `sqlite_batch_ms_per_message` replays that captured batch through the real `sqlite3 -bail` on another fresh backup: it includes process startup, parsing, statement execution, and commit, **not parsing alone**. Fixture construction, capture, replay verification, and idempotency checks are outside both reported timers. `metadata.json`, `results.jsonl`, the SQL batches, and all databases remain under `--out`.

Use `--messages`, `--preloaded`, `--blob-bytes`, and `--repetitions` to change the fixture. Run measurements without other local test/harness jobs; absolute times on a shared machine remain noisy. This measures post-decryption apply, not end-to-end reprocess or the production store's unexplained latency.

For an optional compilation/execution split of the captured SQL:

```sh
python3 tests/perf/profile-apply-sql.py --run /tmp/apply-blob-run --library /path/to/libsqlite3.so --out /tmp/apply-sql-profile
```

Supply a shared library matching the measured CLI's SQLite version; a version mismatch is refused. Record the source ID and any build differences as well: matching versions do not guarantee identical builds, and a CLI can link SQLite statically. This runs each captured statement in order on a fresh seed backup, separately timing the C API calls to [`sqlite3_prepare_v2`](https://www.sqlite.org/c3ref/prepare.html), `sqlite3_step`, and `sqlite3_finalize`, through Python `ctypes`. Preparation includes parsing, query planning, and bytecode generation, not just tokenization. Execution includes the commit. Timers include the foreign-function call overhead but exclude the surrounding Python loop, file reads, connection open/close, and fixture setup. These are library-call measurements, **not a profile of the running production shell**, and cannot replace the adapter and CLI measurements above. The default 20 repetitions alternate variant order and verify imported counts and matching quarantine/mapping blobs.

## Reading a result

From the comparison on one machine (macOS, 2026-08-21), `join`, 50 vs 400 messages:

```
bootstrap.apply   256 ms/msg @50   259 ms/msg @400   linear   x8 items -> x8 time
-> 17,300 would take 1.25 h
```

That is #910's "5 messages per second" read off the shipped path, visible at 50 messages — the point of the table is that the number at 50 predicts the hour at 17,300, and a change that does not move `ms/msg` at 50 has not fixed it.
