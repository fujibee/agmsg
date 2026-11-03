# tests/test_ci_sharding.bats — where the CI time goes

Data: CI run 41607512279 (main @ 64723d6), `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/per-test-41607512279.tsv`. Code read at main @ 551764e (no change to this file or `.github/scripts/` since 64723d6). Local measurements: Linux, 4 cores, load ~5 (a background strace sweep was running), bash 5.2.

## Summary

- 20 tests, **151.9 s macOS / 112.2 s ubuntu** per full run. Nine tests carry 99% of it, and all nine spend their time the same way: they call `.github/scripts/shard-tests.sh`, **74 times in total**.
- One call costs about **1.9 s on macOS and 1.4 s on ubuntu** (fitted from tests 14 and 19, see below). Locally it takes 1.51 s. strace counts **507 execs and 822 forks per call**: 348 `basename`, 154 `awk`, plus 2 `sort`, `find`, `dirname` and `bash`. The script looks up each file's weight with its own `$(basename)` and `$(awk ... table)`, called inside a `$(file_seconds ...)` subshell (shard-tests.sh:133-144, called at :191). The pinned-seed loop adds another `$(basename "$f")` for every file it scans (:163-182).
- The macOS/ubuntu ratio is 1.28-1.44 for every heavy test. That points to process spawning that is the same on both OSes. There are no sleeps, waits or timeouts in this file.
- **Best fix (not test-only):** do the weighting in one `awk` pass. I wrote a prototype that gives a byte-identical partition and runs in **0.032 s instead of 1.51 s** per call. It would cut the file to about 12 s on macOS and 8 s on ubuntu, **saving about 140 s macOS and 104 s ubuntu per full run**. The test-only fallback saves about 76 s macOS and 57 s ubuntu: compute each shard once in `setup_file`.

## Where the time goes

Tests sorted by macOS seconds. The first 9 rows are 99.0% of the file's macOS time.

| # | title | macOS s | ubuntu s | ratio | shard-tests.sh calls | driver |
|---|---|---|---|---|---|---|
| 9 | the shards cover every test file exactly once | 49.7 | 36.8 | 1.35 | 23 (totals 1,2,3,4,5,8 via `union_of_shards`, L62-67) | 23 script runs. Also `all_test_files()` (L58-60) is re-evaluated once per total at L196, and each call is `find -exec basename {} \;` = 155 execs, so 930 execs in total |
| 14 | the pinned-apart heavy files never share a shard, at any shard total >= 2 (#847, #848) | 42.1 | 31.5 | 1.34 | 22 (totals 2,3,4,5,8, L270-279) | 22 script runs + 44 `grep -qF <<<` forks |
| 19 | shard totals stay balanced by real measured seconds, not count (#1243) | 11.4 | 8.1 | 1.40 | 5 (L373-377) | 5 script runs. The test's own `shard_seconds()` (L21-32) also runs `$(basename)` + `$(awk)` for every file it lists (~310 execs) |
| 20 | a file missing from the seconds table is estimated at the average, not dropped (#1243) | 11.3 | 8.7 | 1.30 | 6 (L401-409) | 6 script runs on a copied tree (`cp` of 155 files, L397) |
| 12 | no shard is empty at the shard count CI uses | 8.3 | 5.9 | 1.41 | 4 (L221-224) | script runs only |
| 15 | adding tests to an unrelated file does not reunite the pinned-apart files (#847 positive control) | 8.2 | 5.7 | 1.44 | 4 (L301-305) | script runs + `cp` of 155 files + 8 greps |
| 13 | the heaviest file does not share a shard with the second heaviest | 7.9 | 5.8 | 1.37 | 4 (L248-253) | script runs + 2 table sorts |
| 10 | this test file is itself assigned to a shard | 7.6 | 5.9 | 1.28 | 4 (L207) | script runs only |
| 11 | the split is deterministic across repeated runs | 4.0 | 3.0 | 1.31 | 2 (L214-215) | script runs only |
| others (11 tests) | timed-runner fakes, usage and argument checks, workflow greps | 1.5 | 0.9 | ~1.7 | 0 (except error paths that exit early) | negligible |

How the per-call cost was derived. Test 14 is 22 calls plus 44 small `grep` forks, and test 19 is 5 calls plus about 315 `$(basename)`/`$(awk)` forks. Solving both gives about **1.90 s per call and 5.9 ms per `$(external)`** on macOS, and **1.42 s and 3.1 ms** on ubuntu. The fit also reproduces test 9: 23 × 1.90 + 930 × 5.9 ms ≈ 49 s, against 49.7 s measured.

## Proposals

### 1. Weight every file in one awk pass inside shard-tests.sh (not test-only)

- **What to change:** `.github/scripts/shard-tests.sh`:
  - Replace `avg_seconds` and `file_seconds()` (:116-144) and the weighting loop (:184-195) with a single `awk`. It reads the table with `getline` in `BEGIN` and prints `<weight>\t<path>` for the `find | sort` list. It keeps the same rules: the first row per basename wins, and the average comes only from non-comment two-column rows.
  - In the pinned loop (:163-182), take basenames as `${f##*/}` instead of `$(basename "$f")`.
  - The LPT loop, the pins, the tie-break sort and the exit-status handling stay exactly as they are.
- **Prototype:** `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/survey/deepdive/proto/shard-tests.fast.sh`. It is bash 3.2-safe: indexed arrays, `${f##*/}`, here-docs, and BSD-awk `getline`/`split`.
- **Verification (local):**
  - The full partition (every shard) is identical to the current script for totals 1, 2, 3, 4, 5, 6 and 8 on the real tree. It is also identical for the test-20 shape (an extra unmeasured file, total 5) and with `SHARD_TESTS_SECONDS_TABLE=/nonexistent` (total 4).
  - The exit codes are the same for `0 4`, `5 4`, `abc 4`, `1 0` (all 2) and for a missing dir (1).
  - The first draft used the `FNR == NR` idiom and swallowed the file list when the table was empty. The no-table check caught it, and the prototype now reads the table with `getline`.
  - Cost: 1.51 s → 0.032 s per call (average of 10 runs).
- **Sandbox run:** I copied `tests/` and `.github/` and put the prototype in place of shard-tests.sh. Tests 9-15, 19 and 20 all pass and take **7.2 s in total** locally: test 9 2.9 s, test 14 1.3 s, test 19 1.6 s, the rest ≤ 0.4 s. On CI ubuntu the same tests take about 111 s today.
- **Tests:** 9, 10, 11, 12, 13, 14, 15, 19, 20.
- **Estimate:** macOS 151.9 → ~12 s, **saving ~140 s**. ubuntu 112.2 → ~8 s, **saving ~104 s**.
  - Basis: 74 calls go from 1.90 s to ~0.06 s each on macOS, and from 1.42 s to ~0.03 s on ubuntu. On top of that, the ~4.8 s of non-script work left in the sandbox, ×1.7 for macOS.
  - CI also saves ~2 s per macOS shard job and ~1.5 s per ubuntu shard job, because each of the 12 jobs calls the script once. That is runner time, not bats time.
- **test_only:** no. **Coverage risk:** low. The tests still run the real script against the real tree. The algorithm and its output are unchanged and were checked against the current script. The only new exposure is BSD awk on macOS, which the first macOS CI run confirms.

### 2. Test-only alternative: compute each shard once per file in `setup_file`

- **What to change:**
  - Add `setup_file` to test_ci_sharding.bats. It runs `bash "$SHARD" i total` once for every pair the file uses (totals 1,2,3,4,5,8 = 23 calls) and writes each result to `$BATS_FILE_TMPDIR/shard.<total>.<i>`.
  - `union_of_shards` (L62-67) and tests 10, 12, 13, 14 and 19 then read those files.
  - Test 11 compares one fresh call against the cached output. Today it makes two fresh calls, so determinism is still checked.
  - Tests 15 and 20 build their own trees and stay as they are (4 + 6 calls).
- **Tests:** 9, 10, 11, 12, 13, 14, 19.
- **Estimate:** 74 → 34 calls (23 cached + 1 in test 11 + 4 in test 15 + 6 in test 20). That **saves ~76 s macOS and ~57 s ubuntu** (40 × 1.90 s and 40 × 1.42 s).
  - Not additive with proposal 1: after 1 it would save about 2 s more.
- **test_only:** yes. **Coverage risk:** low. Every assertion still reads real script output; the output is just produced once per file instead of once per test.
- Note: no file in `tests/` uses `setup_file` or `BATS_FILE_TMPDIR` today, so this introduces a new pattern. bats 1.13.0, which CI uses, supports both.

### 3. Remove the test file's own per-file forks (test-only, additive to 1 or 2)

- **`all_test_files()` (L58-60):** replace `find ... -exec basename {} \;` (155 execs per call) with `find "$REPO_ROOT/tests" -maxdepth 1 -name '*.bats' | sed 's|.*/||' | LC_ALL=C sort`. In test 9, compute it once before the `for total` loop instead of inside the comparison at L196.
- **`shard_seconds()` (L21-32):** replace the per-file `$(basename)` + `$(awk)` with one `awk` that joins the shard's file list against `$SECONDS_TABLE`. It must use the same "first match, else table average" rule; the comment at L34-36 asks that the two never drift apart. Keep `table_avg_seconds()` as the single source of the average.
- **Tests 13, 14, 15:** use `case "$shard_files" in *"$pin1"*)` instead of `grep -qF ... <<<`.
- **Tests:** 9, 13, 14, 15, 19.
- **Estimate: saves ~5 s macOS and ~3 s ubuntu.**
  - Basis: about 930 + 310 + 60 fewer `$(external)` calls at the fitted 5.9 ms (macOS) and 3.1 ms (ubuntu) each.
  - Sandbox check: with proposal 1 in place, test 9 still takes 2.9 s locally, and about 2.1 s of that is the six `all_test_files` calls.
- **test_only:** yes. **Coverage risk:** none. Same values, fewer processes.

### 4. Shrinking the totals: dropped

- Test 9's comment (L190-191) says an off-by-one in the greedy loop "can easily be invisible at one shard count and drop a file at another".
- Test 14 checks 2..8 on purpose (L263-266).
- Shrinking N would trade away exactly that coverage. After proposal 1 the calls cost milliseconds, so it isn't worth it.

### 5. Shard-balance follow-up

- After proposal 1 lands, refresh this file's row in `.github/scripts/bats-file-seconds.tsv` (153 s macOS today) at the next re-measure (#1884's process). Otherwise LPT keeps reserving ~140 s of a shard for a file that no longer needs it.
- Getting this wrong only hurts balance, never coverage: shard-tests.sh:34-36.

## Risks and notes

- Proposal 1 changes a CI script that protects coverage. The safety argument rests on two things: the partition is identical (checked), and this file keeps testing the real script.
- Before merging, run the prototype under macOS `/bin/bash` 3.2 and BSD awk. The constructs are basic, but I only ran it on Linux.
- The weighting rule has to stay "first row whose first field is the basename". Comment rows can't collide with `*.bats` names, so `w[$1]` keyed by basename gives the same answer as the per-file `awk '$1 == b { print $2; exit }'`.
- These estimates come from one CI run (macos_n = ubuntu_n = 1). The per-call cost is consistent across tests 9-14, which share no other cost, so the fit is stable.
- If neither 1 nor 2 lands, proposal 3 alone is the cheapest change, but it only saves ~5 s.
