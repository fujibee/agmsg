# tests/test_roster_journal.bats — where the CI time goes

Data: CI run 41607512279 (main @ 64723d6), `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/per-test-41607512279.tsv`. Code read at main @ 551764e (this file, `scripts/internal/roster-sync-driver.sh` and `tests/test_helper.bash` are unchanged since 64723d6). Local runs: Linux, 4 cores, load ~5 (a background strace sweep was running), bats 1.13.0.

## Summary

- 31 tests, **108.4 s macOS / 83.3 s ubuntu**.
- The heaviest tests take almost the same time on both OSes (ratio 1.06-1.27), so the time is **fixed waits**, not process spawning. All of the waits are on the `#821` timeout path of `scripts/internal/roster-sync-driver.sh`:
  - the budget, `AGMSG_ROSTER_SYNC_TIMEOUT_S` (`read -t`, :369; or a `SECONDS` poll, :399-402)
  - a hard-coded **2 s TERM→KILL grace** (`sleep 2 || true`, :458)
  - a hard-coded **5 s "confirm it is gone" loop** (:545-551), which runs to the end whenever the child is still `ours`
  - the tests' own cleanup, `kill; sleep 1; kill -9`, which always waits the full second because the fakes ignore TERM
- Those waits add up to about **48 s per OS across 8 tests**, plus about 1 s in the teardown of test 9.
- Everything else is the per-test fixture (`setup_test_env`) and one `join.sh` per test. `join.sh` is 193 execs and took 0.72 s locally.
- **Test-only changes save about 14 s per OS:** go straight to `kill -9`, use 2 s budgets in the FIFO-mode tests, and poll in teardown instead of sleeping. Making the grace and confirm waits configurable would save about 9.5 s more, but that changes production code and is a riskier trade.

## Where the time goes

These 11 rows are 72.5% of the file's macOS time, and they include every test over 5 s. The "fixed waits" are read off the code; the CI totals line up with them plus about 1-2 s of setup, `join.sh` and driver startup.

| # | title | macOS s | ubuntu s | ratio | driver |
|---|---|---|---|---|---|
| 21 | a number once judged not ours is not re-adopted for KILL (#821) | 13.0 | 12.2 | 1.06 | budget 3 s (L1173) + grace 2 s (driver :458) + **confirm loop 5 s** (driver :545-551: the fake is never KILLed, by design, so it stays `ours` until the deadline) + cleanup `sleep 1` (L1205) = **11 s fixed** |
| 22 | a recycled pid is neither signalled nor read as gone (#821) | 9.6 | 8.1 | 1.18 | budget 4 s (L1314) + grace 2 s + cleanup `sleep 1` (L1361) = **7 s fixed**. The substitution loop is 25 × 0.1 s (L1292-1305) |
| 18 | a numeric but unusable pid is not read as a child that exited (#821) | 9.2 | 8.1 | 1.14 | budget 4 s (L863) + grace 2 s + cleanup `sleep 1` (L878) = **7 s fixed** |
| 17 | an unusable pidfile is not read as a child that exited (#821) | 9.1 | 8.1 | 1.13 | budget 4 s (L784) + grace 2 s + cleanup `sleep 1` (L802) = **7 s fixed** |
| 20 | a TERM already sent is reported, not denied (#821) | 8.2 | 7.1 | 1.15 | budget 3 s (L1071) + grace 2 s + cleanup `sleep 1` (L1109) = **6 s fixed** |
| 15 | roster sync is still bounded when no FIFO can be made (#821) | 7.7 | 6.0 | 1.27 | poll mode: `SECONDS`-based budget 2 (between 1 and 3 s of real wait, depending on where in the second it starts and on the `sleep 1` step, driver :399-402) + grace 2 s = **~4-5 s fixed** |
| 14 | roster sync bounds a local child that never finishes, and releases the lock (#821) | 6.4 | 6.0 | 1.07 | budget 2 s (L586) + grace 2 s = **4 s fixed**. The confirm loop may add up to 1 s if the KILLed fake still reads `ours` on the first check |
| 6 | rename carries a name-only legacy team's placement record to the new name, replacing a stale one (#1403) | 5.7 | 2.9 | 1.99 | process-bound: 5 × `rename.sh` + 2 × `join.sh` + 6 subshells that source `actas-lock.sh`, covering five #1403/#1625 cases in one test |
| 16 | a failing sleep does not drop the lock beside a live child (#821) | 3.5 | 2.6 | 1.30 | poll mode with `sleep` stubbed to fail: a hot spin until the `SECONDS` deadline (budget 2, :399-402). The grace `sleep` fails instantly |
| 9 | roster sync exits on TERM without projecting after releasing the lock | 3.2 | 2.1 | 1.53 | `join.sh` + driver start. The fake's `trap 'exit 0' TERM` (L362) only runs after its current `sleep 1` (L363) returns, so teardown usually still finds it, and teardown's straggler path waits `sleep 1` (L31) |
| 1 | join records one stable identity event per new member | 3.0 | 2.4 | 1.28 | 3 × `join.sh` + 3 journal queries (`sqlite3`) |

Baseline for the rest of the file: a test with no `join.sh` costs 0.56 s on macOS and 0.20 s on ubuntu (test 8). One `join.sh` plus a few queries adds about 0.8 s on both OSes (test 2: 1.35 / 1.00).

## Proposals

### 1. In the per-test cleanup, go straight to KILL (test-only)

- **What to change:** replace `kill $leftover; sleep 1; kill -9 $leftover` with `kill -9 $leftover` at L801-803 (test 17), L877-879 (test 18), L1108-1110 (test 20), L1204-1206 (test 21) and L1360-1362 (test 22).
- **Why it is safe:** every one of these fakes either ignores TERM (`trap '' TERM` at L766, L844, L1166, L1282) or traps it and does not exit (test 20's `_on_term`, L1063-1064). So the TERM never ends anything and the `sleep 1` always runs to the end. The block runs after every assertion, and teardown still reaps by `TEST_SKILL_DIR` (L25-35).
- **Tests:** 17, 18, 20, 21, 22.
- **Estimate: saves 5 s per OS** (macOS and ubuntu): a fixed 1 s in each of the 5 tests.
- **test_only:** yes. **Coverage risk:** none.

### 2. Use a 2 s budget in the FIFO-mode cases (test-only)

- **What to change:**
  - `AGMSG_ROSTER_SYNC_TIMEOUT_S=4` → `2` at L784 (test 17), L863 (test 18) and L1314 (test 22).
  - `=3` → `2` at L1071 (test 20) and L1173 (test 21).
- **Why it is enough:**
  - These five cases install no `mkfifo` stub, so they wait with `read -t`, which honours the budget to the second.
  - The budget only has to cover the wrapper writing its pidfile, plus the first 0.1 s substitution tick (tests 17, 18, 22) or the fake installing its TERM trap (test 20).
  - The 25 × 0.1 s substitution loops (L768, L846, L1292) keep rewriting past a 2 s budget, so test 22's argument still holds: "rewriting until just before the driver's budget expires removes the timing question" (L1284-1290). The loops write only `-s`/`-e` pidfiles, and the driver deletes the pidfile on exit, so nothing gets recreated.
  - Each case has a positive control: the `substituted`/`garbled`/`oob`/`termed` markers and the `ps` call count ≥ 2. A budget that is too short therefore fails loudly; it can never pass silently.
- **Do not lower** tests 14, 15 and 16 (they are already at 2). Tests 15 and 16 poll whole-second `SECONDS` ticks, so a budget of 1 can expire almost immediately, before the wrapper has written its pid. The driver would then read `unknown`, keep the lock, and the tests would fail.
- **Measured locally** (sandbox copy with proposals 1 + 2, under load): test 22 went from **8.0 s to 5.3 s**; test 17 took **5.1 s** and test 20 **5.4 s** (CI today: 9.1 and 8.2 s). All three pass.
- **Tests:** 17, 18, 20, 21, 22.
- **Estimate: saves 8 s per OS** (2 + 2 + 2 + 1 + 1 s of `read -t` budget).
- **test_only:** yes. **Coverage risk:** low. The branch, exit codes and messages under test don't depend on the budget's length. The remaining risk is a flaky failure on a badly overloaded runner, with about 10× headroom over the wrapper's startup.

### 3. Teardown: poll instead of a fixed `sleep 1`, and make test 9's fake respond to TERM (test-only)

- **What to change:**
  - In `teardown()` (L28-34), replace `kill $stragglers; sleep 1; kill -9 $stragglers` with: TERM, then up to 10 × 0.1 s waiting for `pgrep -f "$TEST_SKILL_DIR"` to come back empty, then KILL whatever is left.
  - In test 9's fake (L363), use `while :; do sleep 1 & wait $!; done`. `wait` is interrupted by the trap, so `trap 'exit 0' TERM` takes effect at once. The fake has then usually exited before teardown runs.
- **Tests:** 9, plus any failing case that leaves a straggler.
- **Estimate: saves ~1 s per OS.** Test 9's 3.2 / 2.1 s includes about one teardown `sleep 1`; its fake defers TERM for up to 1 s.
- **test_only:** yes. **Coverage risk:** none. Teardown still escalates to KILL, and test 9 asserts on the driver, not on how fast the fake exits.

### 4. Make the 2 s grace and the 5 s confirm wait configurable (not test-only)

- **What to change:**
  - In `scripts/internal/roster-sync-driver.sh`, read `AGMSG_ROSTER_SYNC_GRACE_S` (default 2) at :458 and `AGMSG_ROSTER_SYNC_CONFIRM_S` (default 5) at :545. Validate both before the lock, exactly like `AGMSG_ROSTER_SYNC_TIMEOUT_S` (:32-55).
  - In the tests, set grace = 1 in tests 14, 15, 17, 18, 21 and 22, and confirm = 1 in test 21. With `SECONDS` granularity the confirm loop then runs 1-2 polls.
- **Leave test 20 at the default grace**, unless its fake also moves to `sleep 1 & wait $!`. Test 20 needs the fake's TERM handler to drop its marker before the KILL decision, and that handler only runs once the current `sleep 1` returns. With a 1 s grace that becomes a race.
- **Estimate: saves ~9.5 s per OS:** 6 × 1 s of grace, plus ~3.5 s from test 21's confirm loop.
- **test_only:** no. **Coverage risk:** medium.
  - The shipped defaults would no longer be what these cases exercise. Test 20 would be the only one still running the 2 s grace, and nothing would run the 5 s confirm wait.
  - The driver's comments (:455-473, :520-545) show that each of these waits was argued over in review, and a new env knob needs its own validation and refusal tests.
- **Alternative I rejected (test-only, test 21):** make the `ps -o args=` stub answer by call number, so the confirm loop sees `unknown` on its second poll and `ours` on the final read. That saves ~4 s, but it ties the test to the exact number of `_roster_inner_state` calls in the driver. It is brittle, and harder to read than the knob.

### 5. Build the shared team once (test-only, lower priority)

- **What to change:**
  - Tests 9, 14, 15, 16, 17, 18, 20, 21 and 22 all start with the same arrange: `join.sh demo alice claude-code /tmp/a`, then `agmsg_roster_append_left` (for example L346-353, L570-575, L740-746).
  - Build `teams/demo` once in `setup_file`, and have each test copy it into its own `TEST_SKILL_DIR` with `cp -Rp`.
- **Estimate: saves ~5 s macOS and ~5 s ubuntu.** Basis: 9 tests × ~0.6 s for `join.sh` (193 execs, 0.72 s locally; about 0.8 s on CI for `join.sh` plus queries, from test 2 vs test 8).
- **test_only:** yes. **Coverage risk:** low-medium.
  - First confirm that `roster-sync-driver.sh` reads only `teams/demo/` (config.json, roster.jsonl), and none of the DB rows or `run/` files that `join.sh` also writes.
  - `member_id` would become identical across tests.
  - This would be the first `setup_file` in `tests/`.

### 6. Looked at, nothing proposed

- **Test 6 (5.7 s):** process-bound. It already merges five scenarios into one test, and splitting it would not reduce the total.
- **Test 16:** its 2 s spin is the property under test: the wait must stay bounded when `sleep` is broken. The budget can't go below 2 (see proposal 2).
- **Shard balance:** the file is 109 s on macOS, about 9% of an average shard (~1199 s), so it isn't worth moving.

## Risks and notes

| package | macOS s | ubuntu s | test-only |
|---|---|---|---|
| today | 108.4 | 83.3 | |
| proposals 1 + 2 + 3 | ~94 (−14) | ~69 (−14) | yes |
| + proposal 4 | ~85 (−9.5) | ~60 (−9.5) | no |
| + proposal 5 | ~80 (−5) | ~55 (−5) | yes |

- All the savings are fixed waits, so they don't depend on runner speed. They are the same on both OSes, which also makes them the most reliable estimates in this survey.
- Proposals 1 and 2 were run locally (tests 17, 20 and 22, under load) and pass. Tests 18 and 21 have the same structure but were not run, to stay inside the local execution budget.
- The file's culture is explicit about measured negative controls (many comments read "measured -- the mutation was not caught"). Proposals 1-3 change no assertion and no branch under test. Proposal 4 is the only one that changes which code path runs, and it needs reviewer agreement on the knobs.
