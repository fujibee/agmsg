# tests/test_agmsgd_daemon_sh.bats — where the CI time goes

**Data.** CI run 41607512279 (main @ 64723d6). Neither this file nor `scripts/daemon.sh`, `scripts/daemon/*` or `tests/test_helper.bash` changed between 64723d6 and 551764e.

**Totals.**
- File time: 220 s macOS / 92 s ubuntu (per-test sum 219.6 / 91.4 s, 37 tests).
- Ten tests are macOS-only (fake launchctl) and skip in 0.12 s on ubuntu: 13, 14, 15, 16, 24, 29, 30, 31, 32, 33. Together they cost 116.6 s on macOS, which is most of the gap between the two OSes.

## Summary

**1. A product bug: every stop or disable of a running daemon takes 5 s or more.**

`_request_stop_over_socket` (`scripts/daemon.sh:781-798`) starts a Node client:

```
const s = net.createConnection(...); setTimeout(done, 5000); s.on("close", done); s.on("error", done)
```

The client never reads the socket, so the stream stays paused. `'end'` and therefore `'close'` never fire, even after the daemon answers `stop_ok` and calls `socket.end()` (`control.mjs` `finish()`). The client only exits at its own 5 s ceiling.

Measured locally (bash 5.2, real daemon):

| step | time |
|---|---:|
| `daemon.sh start` | 611 ms |
| `daemon.sh status` | 171 ms |
| no-op start | 183 ms |
| **`daemon.sh stop`** | **5151 ms** |
| no-op stop | 66 ms |

A replica of the client against a server that answers and ends took **5035 ms as written** and **32 ms with `s.resume()`**. Scripts: `S/survey/deepdive/rsync-cbl-dsh/nodeexp/srv.mjs` and `bench_daemon.sh`.

How much CI time this costs:
- `cmd_stop` (`:813`) and `cmd_disable` (`:1020`) both pay it.
- The ubuntu-run tests pay it 13 times, about 61 of 91 s.
- The macOS run pays it 23 times, about 108 of 220 s.

The 5 s also stretches the daemon's own shutdown. Its `controlHandle.close()` waits for the lingering client until the 1500 ms `STOP_DEADLINE_MS` deadline (`main.mjs` `gracefulStop`, `poll-deadline.mjs:8`).

**2. Test 13 (macOS, 42.3 s): disable on an unverifiable record waits twice.** It waits out `_wait_owner_none` (`daemon.sh:958-967`, 100 × 0.1 s ticks, each also forking `sqlite3`) twice, at `:1021` and `:1031`. That is 20 s nominal, and on macOS it looks closer to 2 × 13-15 s.

**3. Test 29 (macOS) holds a lock on fixed timers.** The lock holder runs `.shell sleep 6` after a `sleep 1` (L865-867), and the test then `wait`s it out (L872).

**4. Everything else is small.** The `status` tests take 0.35-0.6 s. A real `start` is about 0.6 s.

## Where the time goes

The table covers the tests up to 70.3% of macOS time, plus every test over 5 s. "stop(5)" means one stop or disable of a running daemon, which pays the 5 s client ceiling.

| # | title (abridged) | macOS s | ubuntu s | driver |
|---|---|---:|---:|---|
| 13 | enable/disable registers a resident unit (fake launchctl) | 42.28 | skip | enable (real daemon via fake kickstart); disable stop(5); unverifiable-record disable = 2 × `_wait_owner_none` (≥ 2 × 10 s) |
| 12 | stop stops a real daemon, second stop no-op | 20.81 | 19.55 | 3 × (start, status, no-op start, stop(5), no-op stop): 15 s of client ceiling |
| 33 | identical plist no longer loaded is bootstrapped again | 13.59 | skip | enable; stop(5); enable; disable stop(5) |
| 29 | busy op lock fails without stopping the daemon | 13.47 | skip | enable; holder `.shell sleep 6` + `sleep 1`; failed enable (500 ms lock wait); `wait "$holder"` (~4 s); disable stop(5) |
| 30 | a lock held briefly is waited out | 8.94 | skip | holder 2 s + `sleep 0.5`; enable waits the lock out; disable stop(5) |
| 32 | declined launcher is followed by one more start | 8.64 | skip | enable with one declined kickstart (`cmd_start` `sleep 1`, `:753`); disable stop(5) |
| 22 | Windows registration writes UTF-16 task XML | 8.59 | 7.22 | refused enable + enable via fake schtasks (real daemon); disable stop(5) |
| 23 | op lock under CRLF sqlite3 | 8.12 | 6.87 | enable through a `sed -u` sqlite3 wrapper (extra bash+sed per call); disable stop(5) |
| 31 | re-enable with a different Node path | 8.04 | skip | enable; re-enable (already running); disable stop(5) |
| 28 | Windows minute trigger: launcher exits after stop | 7.37 | 6.22 | start; stop(5); launcher run |
| 14 | 2-column meta: status reads, enable/disable upgrade | 7.33 | skip | status; enable; disable stop(5); status |
| 24 | manifest read under /bin/bash 3.2 | 7.27 | skip | enable + disable stop(5) under `/bin/bash` |
| 19 | empty meta.codex_path filled from PATH | 7.12 | 6.23 | start; stop(5); start (left running at the end) |
| 11 | second start is a no-op | 6.76 | 6.11 | start; no-op start; cleanup stop(5) |
| 9 | status reports running | 6.75 | 6.21 | start; status; cleanup stop(5) |
| 17 | disable stops a running daemon before unregistering | 6.57 | 6.24 | start; disable (stop(5) inside), fake systemctl |
| 7 | recorded Node failing the check is replaced | 6.57 | 6.00 | start; cleanup stop(5) |
| 8 | real run against the real entrypoint becomes ready | 6.52 | 5.88 | start; cleanup stop(5) |
| 10 | install that never recorded Node finds it | 6.43 | 5.99 | start; cleanup stop(5) |
| 15 | stale ready state asks the manager to start | 6.29 | skip | kickstart → running; cleanup stop(5) |
| 1-6, 16, 18, 20, 21, 25-27, 34-37 | status / unit / fn-level tests | 0.35-2.6 | 0.26-1.9 | setup floor + a few `sqlite3`/`node` calls |

**Ratios.** The shared tests run at a macOS/ubuntu ratio of 1.05-1.2. That is the signature of a fixed wait, here the 5 s ceiling, not of spawning.

## Proposals

### D1. Fix the stop client so it returns when the daemon answers (product change)

**Change.** In `daemon.sh:789-797`, make the client consume the reply: add `s.resume();`, or a `data` handler, or exit on the `stop_ok` line. Keep `setTimeout(done, 5000)` as the ceiling for a daemon that never answers. The `cmd_stop` poll for `state = none` (`:815-821`) still confirms the stop.

**Tests.** Every test with a stop(5): 7-12, 13, 14, 15, 17, 19, 22, 23, 24, 28, 29-33.

**Savings: about 108 s macOS, 61 s ubuntu.**

Basis: 4.7 s per stop or disable of a running daemon. Locally `stop` took 5.15 s, the fixed client 32 ms, and about 0.3 s remains for the daemon's own shutdown plus the 0.1 s poll.

| | count of stop(5) | saved |
|---|---|---:|
| ubuntu | 13: tests 7, 8, 9, 10, 11 (1 each), 12 (3), 17, 19, 22, 23, 28 (1 each) | ~61 s |
| macOS | those 13 + 13, 14, 15, 24, 29, 30, 31, 32 (1 each) + 33 (2) = 23 | ~108 s |

**test_only:** no (`scripts/daemon.sh`).

**Coverage risk: none.**
- No assertion changes.
- Users benefit too: `agmsg daemon stop`/`disable` currently always waits 5 s.
- The daemon's own shutdown no longer runs into the 1500 ms control-close deadline.
- A cheap guard against regressing this is to check that `run/agmsgd.log` has no `control close failed` line after a stop. A wall-clock assertion would be flaky.

### D1b. Fallback if D1 is deferred: end cleanup-only stops without the socket client

**Change.**
- Tests 7, 8, 9, 10 and 11 end with `bash "$DAEMON" stop >/dev/null 2>&1 || true` (L163, 221, 233, 243, 254). Test 15 does the same (L462).
- Tests 29-33 end with an unasserted cleanup `disable` (L878, 893, 917, 930, 947).
- None of these is asserted. Replace each with: `kill -TERM` the recorded `executor_pid`, then poll `daemon_owner.state` until it is `none`. The daemon handles SIGTERM through the same `doStop("normal")` path (`main.mjs`, `process.on("SIGTERM")`).

**Savings: about 52 s macOS, 23.5 s ubuntu.** That is 11 / 5 stops × 4.7 s.

**test_only:** yes.

**Coverage risk: low.** Only unasserted cleanup changes; the asserted stops in tests 12, 13, 14, 17, 22, 23, 24, 28 and 33 keep the real path. This overlaps D1 completely: do one or the other.

### D2. Test 12: two start/stop cycles instead of three

**Change.** `for iteration in 1 2 3` → `1 2` (L261).

**Savings: about 2.2 s macOS, 1.4 s ubuntu after D1** (6.9 / 6.5 s before D1). Basis: one cycle is about 1.4 s locally (611 + 171 + 183 + ~300 + 66 ms), with macOS assumed about 1.6×.

**test_only:** yes.

**Coverage risk: low.**
- The restart transition (a start after a stop: new gen, new `agmsgd.<gen>.sock`) is still exercised once.
- No comment or commit message explains a third pass. The loop arrived with the feature in 1a595900 (#1529).

### D3. Optional: drop or merge tests 8, 9, 11 into test 12

**Change.** Each is a strict subset of test 12's first iteration, with the same commands and assertions:
- 8: start → `running`
- 9: status → `running` / `exitCode:0`
- 11: no-op start → `already running`

**Savings: about 6 s macOS, 4.5 s ubuntu after D1** (~20 / ~18 s before D1).

**test_only:** yes.

**Coverage risk: low.** The assertions survive in test 12. The cost is triage clarity: the named claims disappear from the TAP output, against this file's convention of one claim per test. Treat it as optional.

### D4. Test 29 (and 30): an on-demand lock holder with a readiness event (macOS-only tests)

**Change.**
- Test 29, L865-872. The holder sends `BEGIN EXCLUSIVE;` and `.print LOCKED`, the same idiom `_with_op_lock` uses at `daemon.sh:161`. It then blocks on a FIFO before `ROLLBACK`.
- The test waits for `LOCKED` instead of `sleep 1`, runs the failing enable, then releases the FIFO and `wait`s.
- Test 30, L886-888: replace `sleep 0.5` with the same readiness wait. Keep the 2 s hold: that duration is what "held briefly, waited out" means, and it must outlast enable's path to the lock.

**Savings: about 4.9 s macOS** (29: about 4 s of `wait "$holder"` + 0.9 s of `sleep 1`; 30: about 0.4 s). None on ubuntu.

**test_only:** yes.

**Coverage risk: none, and the test gets stronger.** The holder now provably holds the lock for the whole failed enable. Today `sleep 1` only assumes it acquired the lock, and `.shell sleep 6` only assumes the enable finishes inside 6 s.

### D5. Test 13: let the test shorten `_wait_owner_none` in the unverifiable-record step (product change, test-only knob)

**Change.** Add an env override for the 100-tick budget in `_wait_owner_none` (`daemon.sh:958-967`), validated the way `remote.sh:3198-3212` validates `AGMSG_TEST_SYNC_START_READY_CEILING`: a plain positive integer, otherwise the production default. Set it to about 5 for the "record from an older version" disable in test 13 (L404-411).

**Savings: about 20-27 s macOS.**
- 2 × 10 s is nominal.
- The 42.3 s total is about 13 s more than the known fixed costs, consistent with each poll tick costing about 0.14 s on macOS (`sqlite3` + `sleep` forks).
- None on ubuntu (test skipped).

**test_only:** no.

**Coverage risk: low.** The test asserts the outcome (`state = none`, exit 0), not the wait length.

**Caveat.** This adds an interface. The codebase refused one for poll intervals (`codex-bridge-launcher.sh:259-261`) but accepted one for this exact "prove the timeout path without paying it" case (`remote.sh:3198-3232`). Leave it to the maintainer.

### D6. Minor: compute the install manifest once per file

**Change.** `_write_completion_record` (L54-92) runs `node -e` to hash all 257 copied scripts in about 26 tests. The result is identical across tests: same tree, fixed `install_id`/`gen`/`version`, and only `created_at` differs. Build it once in `setup_file` and copy it per test.

**Savings: about 3 s macOS, 1.5 s ubuntu.** Basis: 53-87 ms per call locally; macOS Node start-up assumed about 2×.

**test_only:** yes.

**Coverage risk: low.** No test writes into `scripts/` before computing its manifest (the `daemon-fns.sh` writers do it afterwards).

## Risks and notes

**D1 is the change that matters.**
- With D1 the file should drop to about 110 s macOS / 30 s ubuntu.
- With D1 + D4 + D5 it should drop to about 85 s macOS.
- D1 is also a user-visible latency fix. It is the only proposal for this file that touches `scripts/` apart from D5.
- Refresh `.github/scripts/bats-file-seconds.tsv` afterwards for shard balance.

**Test 19 leaks a running daemon.** It ends with a second real `start` and no stop (L564-566). The daemon outlives its `$TEST_SKILL_DIR` until it next polls. That costs no test time, but it is a stray Node process on the runner; a final stop costs about 0.3 s after D1.

**The stop hang was measured locally.**
- The hang and the `s.resume()` fix were measured with a real daemon and with a replica client.
- That CI pays the same 5 s per stop is inferred: start-plus-stop tests cost about 6 s on both OSes, while `start` alone is about 0.6 s.

**Reproduction pitfall.** Running `daemon.sh` under a long `TMPDIR` (the scratchpad path) made agmsgd fail to bind its Unix socket (`bind failed: listen EADDRINUSE …/run/agmsgd.1.sock`), most likely the ~104-108-byte `sun_path` limit. bats' short `/tmp/tmp.*` paths are fine.

**Not proposed.**
- Shortening `_wait_for_ready`, `cmd_stop`'s poll or the agmsgd poll interval: they return early on success.
- Sharing one daemon across tests: each test owns its `install.db` and mutates intent and owner state.
