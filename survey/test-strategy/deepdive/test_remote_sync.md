# tests/test_remote_sync.bats — where the CI time goes

Data: CI run 41607512279 (main @ 64723d6; no change to this file, `scripts/drivers/storage/sqlite-sync.sh`, `scripts/internal/storage-sync-driver.sh` or `tests/test_helper.bash` between 64723d6 and 551764e). File time 273 s macOS / 138 s ubuntu (per-test sum 271.5 / 138.2 s, 55 tests, all `ok`). Per-test numbers from `per-test-41607512279.tsv` (a test's seconds include its own setup/teardown).

## Summary

- **One test is 31% of the macOS time.** Test 53 (the 10,000-entry roster-list bound) costs 84.1 s macOS / 44.3 s ubuntu. The product code is not slow: run outside bats, the same 10,000-entry `storage_sync_prepare_read_state` call takes 0.9 s. Inside bats it costs about 31 s locally, because of **bats' DEBUG trap**:
  - `bats-exec-test` runs under `set -eET` (`libexec/bats-core/bats-exec-test:2`, so functrace is on) and installs `trap 'bats_debug_trap "$BASH_SOURCE"' DEBUG` (`lib/bats-core/tracing.bash:385`).
  - With functrace on, the handler (`tracing.bash:274-299`: path normalisation, an exclude-path loop, two array copies, a stack capture and a trace emit) runs before **every simple command**. That includes every command inside functions the test *sources*.
  - This file sources the sqlite driver into the bats shell (`setup`, L5-17). `storage_sync_prepare_read_state` validates `roster_seqs` with a pure-bash loop: `sqlite-sync.sh:1670-1679` → `_sqlite_sync_sequence` (`:138`) → `_sqlite_sync_decimal_le` (`:115-136`). That is about 15 simple commands per entry, so 10,000 entries means about 150k trap calls.
- **The same tax applies to the rest of the file.** Every test drives the driver in-process. When the per-test `scripts/` copy was excluded from the trap, tests 6, 9, 44 and 49 got 30-39% faster locally.
- **Smaller fixed costs:**
  - Test 45 holds the write lock with a fixed `sleep 3` and waits a fixed `sleep 0.5` first. It has the lowest macOS/ubuntu ratio in the file (1.50), which is what a fixed wait looks like.
  - Test 44 forks jq 125 times to build its pages.
- **Setup floor** is about 0.69 s macOS / 0.34 s ubuntu per test (tests 47 and 48 do almost nothing else), so about 38 / 19 s across 55 tests.
- **macOS/ubuntu ratio** is about 2 across the file, and 2.4-4.1 on fork-heavy tests (jq/sqlite3 per call). Process spawning on macOS is part of the story, but the biggest single item (test 53) is bash-level CPU inflated by the trap.

## Where the time goes

These tests make up 70.3% of the macOS time, and include every test over 5 s. "in-proc" means a `storage_*` driver call made inside the bats shell, so it pays the DEBUG-trap tax.

| # | title (abridged) | macOS s | ubuntu s | driver |
|---|---|---:|---:|---|
| 53 | read-state: roster list bound swept, 10,000 pass / 10,001 refused (#968) | 84.12 | 44.27 | 10,000-entry pure-bash validation loop run in-proc → ~150k DEBUG-trap calls (`sqlite-sync.sh:1670-1679`). The 10,001 case is refused by jq before the loop (cheap). Plus apply 4 msgs + mark read |
| 44 | applying a pull page does not grow the command line (#882) | 11.87 | 6.55 | `_sync_page_of 5` + `_sync_page_of 120` = 125 jq forks (L1375-1393). Two in-proc applies, each with a per-record bash loop (`sqlite-sync.sh:1267ff`). Every sqlite3 call goes through a bash recorder wrapper (one extra exec per call) |
| 49 | frontier advances across roster sequences (#968) | 7.01 | 3.49 | `_968_apply_messages` (one jq per msg, apply, then `storage_watch_tip` + `storage_read_cursor_consume` per msg) + 2 in-proc prepares |
| 51 | roster row in quarantine exempt only when listed (#968) | 6.34 | 3.29 | roster apply + apply 2 msgs + 2 prepares + 2 sqlite reads |
| 45 | store held by another writer is busy (11), not 13 | 6.33 | 4.23 | **fixed waits**: holder `sleep 3` (L1458) and `sleep 0.5` (L1460). Three adapter processes |
| 9 | pull reconciles echoes, imports wire IDs once | 5.95 | 3.12 | prepare + reconcile + 2 applies + 5 history/unread reads + ~8 jq forks |
| 50 | lost MESSAGE still pins the frontier (#968) | 5.90 | 3.17 | apply 3 msgs + 2 prepares |
| 54 | roster seq validated against the sequence DOMAIN (#968) | 5.74 | 2.38 | apply 2 msgs + 3 prepares |
| 15 | reprocess scope=malformed … one definition (#1284) | 5.68 | 3.12 | 2 applies, 3 reprocess calls, 3 `bash -c 'source remote.sh'`, `cp -R` of scripts/ (257 files), `join.sh`, `remote.sh sync start` with fake node/ps (readiness ceiling already cut to 400 by `AGMSG_TEST_SYNC_START_READY_CEILING`), `grep -rn` |
| 6 | reconcile advances only the contiguous prefix | 5.55 | 1.96 | 3 sends + prepare + 2 reconciles + 3 jq (ratio 2.83: fork-heavy) |
| 33 | ack position stays a whitelist | 5.01 | 2.09 | `_seed_legacy_history` + prepare + 11 refused in-proc reconciles (L943-966) |
| 55 | roster entry with trailing newline refused (#968) | 4.81 | 2.55 | apply 2 msgs + 4 prepares + 3 sqlite reads |
| 8 | reconcile stops at the FIRST gap (#912) | 4.66 | 2.15 | 5 sends + prepare + 2 reconciles + 2 jq |
| 4 | prepare is re-entrant and byte-stable | 4.29 | 1.74 | send + 2 prepares + 2 jq |
| 21 | Stage-2 exports exact reads across holes | 4.17 | 2.32 | apply 2 + read consume + prepare + apply_read_state + unread |
| 32 | ack wire id stays a whitelist | 4.02 | 1.73 | seed + prepare + 7 refused reconciles |
| 24 | Stage-2 exact limit block persists | 3.99 | 2.51 | send + 3 prepares + block + unblock |
| 11 | pull conflicts with an acked mapping | 3.88 | 2.11 | send + prepare + reconcile + apply + 3 sqlite reads |
| 7 | message at the maximum seq advances the cursor | 3.85 | 1.59 | 2 sends + UPDATE + prepare + reconcile |
| 46 | conflict guard lookup is a search (#910) | 3.82 | 1.56 | 2 prepares + EXPLAIN + DROP INDEX |
| 17 | retention resync records one immutable gap | 3.82 | 2.00 | prepare + 2 resync_status + 2 resync + 4 sqlite reads |
| 47/48 | #462 scan / mutation control | 0.69/0.87 | 0.34/0.35 | setup floor only (the repo tree scan is cheap) |

Local evidence (4-core container, under the parallel strace load, bash 5.2.21, bats 1.13.0). Scratch files are in `S/survey/deepdive/rsync-cbl-dsh/sb/tests/`.

- `rs53.bats`:
  - in-proc prepare at N=2,000: 8.76 s
  - apply-4 baseline alone: 2.50 s
  - N=10,000 + N=10,001 through `storage-sync-driver.sh read-prepare`, with the same assertions: 3.57 s
- `rs53b.bats`, same N=2,000 test:
  - with `scripts/` excluded from the trap: 3.48 s
  - apply-4 baseline with exclusion: 1.71 s; with `trap - DEBUG`: 1.36 s
  - empty test (setup floor): 0.37 s
- `rs_orig.bats` against `rs_excl.bats` (one added setup line):

  | test | original | exclusion |
  |---|---:|---:|
  | 6 | 2.31 s | 1.59 s |
  | 9 | 3.45 s | 2.38 s |
  | 44 | 6.07 s | 4.28 s |
  | 49 | 3.97 s | 2.44 s |

- Outside bats (`bench_968.sh`): the N=10,000 prepare costs 0.90 s and the N=10,001 refusal 0.16 s.

## Proposals

### P1. Run the #968 read-prepare through the real driver process (fixes test 53)

**Change.** Make `_968_prepare` (L1602-1610) pipe its context into the adapter instead of the sourced function:

```
bash "$SCRIPTS/internal/storage-sync-driver.sh" read-prepare demo "$SERVER_ID" "$TEAM_ID" 1
```

The adapter dispatches `read-prepare` at `storage-sync-driver.sh:58-59`. This is the path `remote-sync.mjs` uses in production. A fresh bash process does not inherit bats' DEBUG trap. You can apply this to test 53 only, or to the helper, which also covers tests 49-55.

**Saves** about 77 s macOS and 41 s ubuntu. Basis:
- Test 53 today: 84.1 / 44.3 s.
- After the change it should cost about the same as test 49, which has the same arrange plus two small prepares: 7.0 / 3.5 s.
- Local: both big prepares together cost 1.07 s over the apply baseline through the adapter, against about 31 s in-proc (6.3 s per 2,000 entries).

**test_only:** yes.

**Coverage risk: none.**
- It is the same function with the same assertions.
- The adapter passes exit 13 through unchanged. It only rewrites a *busy* failure to 11 (`:72-77`), then `exit "$rc"` (`:92`).
- The refusal text goes to stderr, which `run` merges, so `grep -Fq "roster_seqs is not a list of at most 10000"` still matches.
- It adds fidelity: the engine's real entry path is exercised.

### P2. Exclude the per-test scripts copy from bats' DEBUG trap (whole file)

**Change.** In `setup()`, right after `setup_test_env` (L6), add:

```
command -v bats_add_debug_exclude_path >/dev/null && bats_add_debug_exclude_path "$TEST_SKILL_DIR/"
```

`bats_debug_trap` then returns early for commands whose source file is under the copied `scripts/`. Test-body lines are still traced, because the preprocessed test file lives under `$BATS_RUN_TMPDIR`, not under `$TEST_SKILL_DIR`. Applies to all 55 tests.

**Saves** about 41 s macOS and 28 s ubuntu, not counting test 53 (already in P1). Basis:
- Measured locally: -30%, -31%, -30%, -39% on tests 6, 9, 44 and 49.
- Applied as 30% of the ubuntu non-53 time (93.9 s → 28 s).
- Applied as 22% of the macOS non-53 time (187.4 s → 41 s). macOS gets a lower share because forks, which the trap does not touch, weigh more there (the fork-heavy tests here show ratios of 2.4-2.8).

**test_only:** yes.

**Coverage risk: none.** The same code runs.
- Diagnostics: failure lines in the test body are unchanged. Frames *inside* driver code are no longer recorded in the bats stack trace.
- Dependency: `bats_add_debug_exclude_path` is a bats-internal function (`lib/bats-core/tracing.bash:323`, present in the pinned 1.13.0). The `command -v` guard makes a future bats without it only slower, never red.
- Cross-cutting note: the same line in `tests/test_helper.bash` `setup_test_env` would reach all 107 files that use it. That is unmeasured here, but worth measuring on files that source `scripts/lib` or driver code in-process.

### P3. Test 44: build each page with one jq instead of one jq per message

**Change.** In `_sync_page_of` (L1375-1393), emit `seq<TAB>id` lines with the `printf` builtin (no fork) and turn them into records with a single `jq -R` program. Emit the cursor line from the same call, or keep its one extra jq. The records stay byte-identical (same ids, same `m<seq>` bodies). Applies to test 44.

**Saves** about 1.3 s macOS and 0.4 s ubuntu. Basis: 123 fewer forks; 120 jq forks cost 0.41 s locally outside bats (3.4 ms each); macOS fork+exec assumed about 3x.

**test_only:** yes. **Coverage risk: none.**

**Not proposed: shrinking N=120.** The comment at L1441-1443 sets the `+200` slack against N=120. With 115 extra messages, any per-message growth of 2 or more characters is caught; at N=20 only growth of 14 or more would be. Shrinking N would weaken the guard.

### P4. Test 45: replace the fixed 3 s lock holder and 0.5 s sleep with an event-driven holder

**Change.** At L1458-1460:
1. The holder sends `BEGIN IMMEDIATE` and then blocks reading a FIFO under `$BATS_TEST_TMPDIR` before `COMMIT`.
2. The test waits until the lock is actually held. Either have the holder `.print LOCKED`, the idiom `daemon.sh` `_with_op_lock` uses (`daemon.sh:161`), or poll `sqlite3 -cmd 'PRAGMA busy_timeout=0;' "$db" 'BEGIN IMMEDIATE; ROLLBACK;'` until it fails, as `agmsgd-launch.sh` `_agmsgd_launch_lock_held` does.
3. Run the busy adapter call, write to the FIFO, then `wait "$holder"`.

**Saves** about 2.7 s macOS and 2.5 s ubuntu. Basis: test 45 is 6.33 / 4.23 s. The holder window is a fixed 3.0 s, and the busy call needs about 0.3-0.5 s (`AGMSG_BUSY_TIMEOUT=200` plus process start).

**test_only:** yes.

**Coverage risk: low, and the test gets stronger.** Today a runner slow enough to start the adapter after 3 s would see no lock and fail. With the readiness event and explicit release, the lock always covers the busy call.

### P5. Not proposed / low value

- **Sharing state across the #968 tests (49-55) through `setup_file`.** Each test applies a different sequence set, and `prepare` rewrites `sync_read_prepared`/`sync_read_members`. Sharing is unsafe, and merging would only save the ~0.7 s macOS setup per test.
- **Moving tests 47/48 (#462 tree scans) to a setup-free file.** They do not use the store. It would save about 1 s macOS.
- **A `setup_file`-level `scripts/` copy.** The `cp -R` is about 18 ms per test on Linux, so it is negligible here.

## Risks and notes

- **Why this file in particular.** It is the heaviest file that runs driver code *inside* the bats shell. Files that execute scripts as child processes do not inherit the trap, because a new bash does not inherit traps or functrace. If P2 is applied suite-wide, the gain will concentrate on files that `source` product code.
- **Do P1 regardless of P2.** P2 alone would cut test 53 to about 9 s locally (3.48 s per 2,000 entries). P1 cuts it to about 1 s, and needs no bats internals.
- **Expected file time after P1-P4:** about 150 s macOS / 66 s ubuntu, down from 273 / 138. Refresh `.github/scripts/bats-file-seconds.tsv` after landing, or `shard-tests.sh` will keep over-weighting this file.
- **Local numbers** come from a loaded 4-core container on bash 5.2.21. CI ubuntu runs bash 5.3.9 and macOS runs `/bin/bash` 3.2.57. The macOS shares are inferred from the CI per-test ratios, not measured.
- **Scripts used:**
  - `S/survey/deepdive/rsync-cbl-dsh/side.py` (per-test table)
  - `S/survey/deepdive/rsync-cbl-dsh/bench_968.sh` (phases outside bats)
  - the scratch bats variants above
