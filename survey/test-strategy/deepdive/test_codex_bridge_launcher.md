# tests/test_codex_bridge_launcher.bats — where the CI time goes

**Data.** CI run 41607512279 (main @ 64723d6). Neither this file nor `scripts/drivers/types/codex/codex-bridge-launcher.sh` changed between 64723d6 and 551764e.

**Totals.** File time is 268 s macOS / 202 s ubuntu; the per-test sum is 257.5 / 201.2 s over 39 tests, 2 of which are Windows-only skips.

## Summary

The time here is fixed waits, not process spawning. The slow tests run at a macOS/ubuntu ratio of only 1.1-1.4: they take about as long on both OSes because they wait out lifetimes and sleeps that the code under test does not need.

1. **`run_launcher` (L208-220) waits out a 6 s parent.** It ties the dispatcher's lifetime to `sleep 6` and runs the dispatcher in the foreground.
   - Every caller waits the full 6 s, plus the dispatcher's next poll tick (`POLL_STEPS=(0.3 0.6 1.2 2)`, `codex-bridge-launcher.sh:271-278`), even though the thing under test (the bridge's argv in `$CAPTURE`) appears in about 1 s.
   - Callers expecting *no* bridge (tests 4, 5) then also sit through a 3 s `$CAPTURE` poll (L216-219) that has to run out.
   - 11 tests use it: 1-10 and 13.
2. **Tests 11 and 12 wait out two `sleep 10` parents** (L336-339, L372-375) after their only assertion, which ran at about 1 s.
3. **Tests 27-32 sleep a fixed 3 s** (L860, 882, 894, 906, 918, 936) to "give the reaper a chance". Nothing shows the reaper actually ran, so on a slow runner they can pass without testing anything.
4. **Test 14 waits out a `sleep 6` parent** (L391, L401-402) after the record change it is testing has already happened.
5. **Per-test floor of about 1.5 s macOS / 1.05 s ubuntu** (test 33, which only evals a function).
   - `setup()` runs `join.sh` for every test (about 0.6 s locally).
   - In `teardown`, a child launcher sitting in `sleep` with `trap 'exit 0' INT TERM` (`:127`, `:150`) only exits once that sleep ends. bash defers trapped signals while a foreground child runs: a `sleep 2` loop took 1.7 s to honour TERM, and 11 ms once its `sleep` child was signalled.

**The file already contains the right shape.** `run_launcher_until_capture` (L190-203, used by tests 18/19) gives the dispatcher a long lifetime and stops it as soon as the bridge launch is observable. Its comment explains why a *short* lifetime is not equivalent. Test 18 costs 3.98 / 2.70 s, against 8.5-10.3 / 7.5-8.9 s for the `run_launcher` callers.

## Where the time goes

The table covers the tests that make up the first 70.9% of macOS time, plus every test over 5 s.

| # | title (abridged) | macOS s | ubuntu s | driver |
|---|---|---:|---:|---|
| 4 | leaves a role without a recorded live thread unsubscribed (#150) | 15.13 | 10.48 | `run_launcher`: 6 s parent + ≤2 s dispatcher poll lag + 3 s capture wait that must run out (no capture is expected) |
| 5 | leaves a role with a foreign-project record unsubscribed (#150) | 14.66 | 10.55 | same as 4. The dispatcher prints "waiting without dispatch" each tick (`:324`) |
| 12 | stale dispatcher reclamation remains singleton | 14.22 | 11.99 | two `sleep 10` parents waited out after the assertion. The stale barrier adds a few 50 ms ticks |
| 11 | only one dispatcher runs per project | 13.33 | 11.85 | two `sleep 10` parents waited out after the assertion |
| 1 | binds the recorded thread (#350) | 10.29 | 7.78 | `run_launcher` 6 s parent + poll lag. The capture is there in about 1 s |
| 13 | request pair selects the matching recorded thread | 10.21 | 8.49 | `run_launcher` (positive and negative halves) |
| 8 | replaces a stale role pidfile | 10.04 | 7.96 | `run_launcher &`, then `wait` for its full 6 s (L281, L293) after the pidfile flip was already observed |
| 2 | passes the actas owner | 9.93 | 8.89 | `actas-claim.sh` + `run_launcher` |
| 9 | dispatches only the role recorded for this seat (#1280) | 9.59 | 8.30 | second `join.sh` + 2 records + `run_launcher` (positive and negative) |
| 6 | writes the bound-thread file (#350) | 9.58 | 7.67 | `run_launcher` |
| 10 | preserves team and name when app-server is empty | 9.44 | 7.65 | `run_launcher` |
| 17 | a role added mid-loop is used only after its request (#466) | 9.38 | 6.93 | deliberate `sleep 3` (commented at L574-577) + event waits whose speed is set by the product's 2 s backoff |
| 14 | role record update keeps child scoped | 8.75 | 7.20 | `sleep 6` parent waited out after the `thread-after` launch |
| 7 | ignores a stale request app-server URL | 8.75 | 7.46 | `run_launcher` |
| 3 | passes the storage override as a workspace root | 8.51 | 7.66 | `run_launcher` |
| 27 | live bridge with no lease left alone (#937) | 6.99 | 5.58 | fixed `sleep 3` (L860) |
| 28 | truncated lease not killed (#937) | 6.94 | 5.58 | fixed `sleep 3` (L882) |
| 16 | re-registered role gets a fresh child (#485) | 6.86 | 5.24 | already event-driven (`wait_for_child_count`); speed set by the product's poll backoff |
| 31 | duplicated-key lease not killed | 6.84 | 5.56 | fixed `sleep 3` (L918) |
| 15 | replacement dispatcher does not double children (#485) | 6.81 | 3.61 | already event-driven; many `ps \| grep \| awk` samples (ratio 1.89) |
| 30 | unknown-extra-key lease not killed | 6.60 | 5.57 | fixed `sleep 3` (L906) |
| 29 | foreign-host lease not killed | 6.36 | 5.58 | fixed `sleep 3` (L894) |
| 32 | mismatched start token not killed | 5.19 | 5.57 | fixed `sleep 3` (L936) |
| 33-38 | lease schema / start token units | ~1.5 | ~1.05 | per-test floor only: `setup` (`join.sh`, mock bridge) + teardown |

**Local evidence.** Measured on the same container, bash 5.2.21; scratch files are in `S/survey/deepdive/rsync-cbl-dsh/sb/tests/cbl*.bats`.

| test | original | variant | under a prompt-reaping subreaper |
|---|---:|---:|---:|
| 1 | 7.44 s | V1, `run_launcher_until_capture`: 3.99 s | 2.67 s |
| 27 | 6.57 s | V27, event instead of `sleep 3`: 3.71 s | 2.92 s |
| 4 | — | V4, 3 observed decisions: 3.27 s | — |
| 11 | — | V11, parents stopped after the assertion: 4.04 s | — |

- **Teardown phases** for V1/V27 under the subreaper: 0.54 s. Waking the launcher's `sleep` with `pkill -P` brought that to 0.19 s.
- **The container slows teardown down.** Its PID 1 reaps orphaned zombies only every 1-2 s; a test orphan stayed `Z` for about 1.3 s. That adds about 1.8 s to every local teardown of a test whose child launcher was nohup'd. CI's systemd/launchd reap promptly. The CI-like numbers above come from running bats under `S/survey/deepdive/rsync-cbl-dsh/subreaper.py` (PR_SET_CHILD_SUBREAPER).

## Proposals

### C1. Make the positive `run_launcher` callers event-driven (tests 1, 2, 3, 6, 7, 8, 9, 10, 13)

**Change**

- Use `run_launcher_until_capture` (L190-203), or a variant that takes a predicate, in place of `run_launcher`. It runs a long `sleep 30` lifetime, waits for the observable, then stops the parent and waits for the dispatcher.
- Each test waits for what it actually asserts:
  - test 6: `codex-bridge.team.alice.thread` holds `rec-thread-1`
  - test 7: the `.appserver` file
  - These are written right after the bridge's `nohup` (`:960-961`), so `$CAPTURE` alone is almost but not quite a guarantee.
- Tests 9 and 13 have a negative half (`! grep … bob`, `! grep … alice`). They should also wait for a second capture line (the child relaunches its exited mock bridge about 1 s later, `:962-963`), or check that no second-role child exists, before stopping. That proves a full child cycle passed.
- Test 8 runs its own parent and dispatcher, and stops the parent right after the pidfile flip and the `kill -0` (L283-291) instead of `wait`ing out `run_launcher` (L293).

**Savings:** about 47 s macOS, 45 s ubuntu.

Basis: the new cost per test is taken from test 18 (3.98 / 2.70 s), which uses the same helper. Tests 2, 9 and 13 get extra allowance (+0.5 s for actas, +1.2 s for the settle).

| test | macOS saved (s) | ubuntu saved (s) |
|---|---:|---:|
| 1 | 6.3 | 5.1 |
| 2 | 5.4 | 5.7 |
| 3 | 4.5 | 5.0 |
| 6 | 5.6 | 5.0 |
| 7 | 4.75 | 4.8 |
| 8 | 6.0 | 5.3 |
| 9 | 4.4 | 4.4 |
| 10 | 5.4 | 4.95 |
| 13 | 5.0 | 4.6 |

**test_only:** yes.

**Coverage risk: low.**
- The assertions are unchanged.
- The positive claims are decided by the first launch.
- Fewer respawn lines get checked by the `! grep` halves. The settle condition in 9 and 13 keeps a full cycle in view.

### C2. Tests 4 and 5 (expect no bridge): observe the dispatcher's decision instead of waiting out a window

**Change**

1. Send the dispatcher's stderr to `$TEST_SKILL_DIR/dispatcher.err`, with a long-lived parent.
2. Wait until "this seat has no unambiguous request pair; waiting without dispatch" (`:324`) has been printed K=4 times. With the 0.3/0.6/1.2 s backoff that is about 2.2 s of observation, and it covers both the fresh-resolve and the cached-identity paths (`:203-253`).
3. While the dispatcher is still alive, assert `count_child_launchers` = 0 and no `$CAPTURE`.
4. Stop the parent, `wait` for the dispatcher, and assert no `$CAPTURE` again.
5. Drop the 3 s post-wait. Only a child can launch a bridge, and none existed.

**Savings:** about 21 s macOS, 14 s ubuntu.

Basis: today 15.1 / 14.7 s macOS and 10.5 / 10.5 s ubuntu. The new cost is about 4.5 / 3.7 s: setup plus 2.2 s of decisions plus the stop. Local V4 with K=3 took 3.27 s; K=3 would save another ~1.2 s per test.

**test_only:** yes.

**Coverage risk: low.**
- The observation window shrinks from about 6 s to about 2.2 s.
- But the test now *proves* the dispatcher evaluated the state four times. Today a dispatcher that died at start-up would also pass.
- The decision depends only on state that does not change during the test (request file, record).

### C3. Tests 11 and 12: stop the 10 s parents after the singleton assertion

**Change**

- Replace the trailing `wait "$launcher_a"; …; wait "$parent_b"` (L336-339, L372-375) with `agmsg_stop_pid "$parent_a"; agmsg_stop_pid "$parent_b"`, then `wait` for the launchers. The lock holder exits within one poll step.
- Re-assert `wc -l < $CAPTURE` = 1 after both dispatchers are gone. Today the count is checked only at first sighting.

**Savings:** about 17 s macOS, 16 s ubuntu.

Basis: 13.3 / 14.2 s macOS and 11.85 / 12.0 s ubuntu today, against an estimated 5.0-5.5 / 3.5-4.0 s after. Local V11 took 4.04 s, about 2.7 s with prompt reaping.

**test_only:** yes.

**Coverage risk: none.** The test gets stronger: the singleton is re-checked after the contention window closes.

### C4. Test 14: wait for the `thread-after` launch, then stop the parent

**Change.** After `put_record … thread-after` (L400), poll `$CAPTURE` for `--pair team<TAB>alice --thread thread-after`, then stop the 6 s parent instead of `wait`ing it out (L401-402).

**Savings:** about 3.75 s macOS, 3.5 s ubuntu. Basis: 8.75 / 7.20 s today; the child relaunches within about 1-2 s of the record change.

**test_only:** yes. **Coverage risk: none**, with the same assertions.

### C5. Tests 27-32: replace the fixed `sleep 3` with proof that the reaper pass ran

**Change**

- Replace `sleep 3` with a bounded wait (about 10 s) for the launcher's *own* bridge, `grep -q -- '--thread thread-alice' "$CAPTURE"`, and fail if it never appears. Then `kill -0 "$victim"`.
- The child runs `_reap_orphan_bridges` immediately before every spawn (`:884-887`, `:914`), so its bridge existing proves the reap pass happened and did not block.
- The fake victims are spawned without `--thread` (`_spawn_fake`, L710-716), so the gate cannot be satisfied by the test's own fixture. That is the trap the #984 comments (L636-705) warn about, and why `_require_launcher_bridge` would be wrong here: the victim is already an exact `{alice}` bridge.

**Savings:** about 15.5 s macOS, 17.3 s ubuntu.

Basis: the new cost is taken from test 22 (3.88 / 2.67 s), which waits on the launcher's first bridge the same way. Locally V27 took 3.71 s against 6.57 s for the original.

| test | macOS saved (s) | ubuntu saved (s) |
|---|---:|---:|
| 27 | 3.1 | 2.9 |
| 28 | 3.0 | 2.9 |
| 29 | 2.45 | 2.9 |
| 30 | 2.7 | 2.9 |
| 31 | 2.95 | 2.85 |
| 32 | 1.3 | 2.85 |

**test_only:** yes.

**Coverage risk: none.** The test gets stronger, because today a launcher that had not reached its reaper within 3 s passes without testing anything.

### C6. Teardown: wake child launchers out of their `sleep` so their TERM trap runs now

**Change.** In `teardown` (L149-151), after `kill "$pid"`, add:

```
command -v pkill >/dev/null && pkill -TERM -P "$pid" -x sleep 2>/dev/null || true
```

The launcher's `trap 'exit 0' INT TERM` is deferred while its foreground `sleep` (0.3-2 s, or the post-spawn `sleep 1`) runs. Signalling that `sleep` makes it exit at once, through its normal EXIT trap. Nothing else changes: same snapshot, same `wait_for_pid_exit`.

**Tests affected:** about 27 tests leave a child launcher alive at teardown (1-3, 6-18, 22-32).

**Savings:** about 9.5 s macOS, 9.5 s ubuntu. Basis: local teardown under a prompt-reaping subreaper went from 0.54 s to 0.19 s for V1 and V27; 0.35 s × 27. The residual sleep is random, between 0 and 2 s, so CI could see more.

**test_only:** yes.

**Coverage risk: none.** It is cleanup only, and the graceful exit path is kept (unlike SIGKILL). On Git Bash `pkill` may be missing; the guard falls back to today's behaviour.

### C7. Optional: stop paying for `join.sh` in tests that never use the registration (33-39)

**Change.** Move the lease-schema and start-token units (tests 33-39, L941-1036) to their own file. Its `setup` only needs `setup_test_env`, `RUN_DIR` and `LAUNCHER`. Those tests deliberately stay on every leg (L951-952), so do not use the `windows-native` filter.

**Savings:** about 5 s macOS, 3 s ubuntu. Basis: 7 tests × `join.sh` (0.6 s locally, about 0.45 s on ubuntu CI and an assumed ~0.8 s on macOS), minus about 0.3 s of fixed overhead for a new file.

**test_only:** yes.

**Coverage risk: none.** It is low value; do it only if this file is being split anyway.

## Risks and notes

**Comments respected**

- The launcher's poll steps have no env override on purpose (`codex-bridge-launcher.sh:259-261`). No proposal needs one.
- Test 17's `sleep 3` has a stated reason: to exercise a cache hit being invalidated rather than a loop still resolving every tick (L574-577). It is left alone. At best about 1 s could be saved by shortening it to just past the 0.3+0.6+1.2 s backoff, which is not worth the risk.
- `run_launcher_until_capture`'s own comment supports C1: keep a long lifetime and stop early.

**Already event-driven.** Tests 15, 16, 18 and 20-26 are already event-driven. What remains in them is the product's own poll backoff and `ps`-based counting, which is cheap on ubuntu but slower on macOS (test 15 runs at a 1.89 ratio).

**Expected result.** The file should drop from about 258 to about 140 s macOS and from 201 to about 93 s ubuntu once C1-C6 are applied, on per-test sums. Refresh `bats-file-seconds.tsv` afterwards so the shard balancer sees it.

**Reproducing locally.** In a container whose PID 1 does not reap orphans promptly, every test that nohups a launcher child picks up about 1.8 s of `wait_for_pid_exit` in teardown. That is an environment artifact, not CI cost. Use `subreaper.py` to get CI-like numbers.

**Scripts used**

- `S/survey/deepdive/rsync-cbl-dsh/side.py`
- `S/survey/deepdive/rsync-cbl-dsh/bench_join.sh`
- `S/survey/deepdive/rsync-cbl-dsh/subreaper.py`
- `S/survey/deepdive/rsync-cbl-dsh/sb/tests/cbl.bats`
- `S/survey/deepdive/rsync-cbl-dsh/sb/tests/cbl_td*.bats`
- `S/survey/deepdive/rsync-cbl-dsh/teardown_ms.txt`
