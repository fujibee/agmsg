# Suite-wide fixed per-test cost: `setup_test_env` / `teardown_test_env`

Repo: fujibee/agmsg main @ 551764e (read-only). CI data: run 41607512279 (main @ 64723d6), `per-test-41607512279.tsv`.
Work files: `survey/deepdive/fixture-overhead/` (scripts, raw outputs, the patched helper, the diff).

## Summary

- **The fixed cost every `setup_test_env` test pays** (bats + `setup_test_env` + `teardown_test_env`, measured on tests that do no work after setup) is **~0.225 s on macOS and ~0.113 s on ubuntu**. bats itself is ~0.028 / ~0.025 s of that, so `setup_test_env` + `teardown_test_env` is **~0.20 s macOS / ~0.088 s ubuntu**.
- It runs **2765 times per full run on each OS**: 2763 tests in 107 files call it from a per-test `setup()`, and 2 tests call it a second time in their body. No file uses `setup_file`. That is **~550-610 s of macOS bats time (7.7-8.5 % of 7195 s)** and **~235-250 s of ubuntu (~6 % of 4069 s)**. bats's own per-test cost adds ~88 / ~79 s across all 3140 tests.
- **Local Linux:** one setup + teardown takes 72 ms on a quiet machine: 23 execs and 33 forks. `init-db.sh` accounts for 41 ms of it (57 %), with 13 execs and 22 forks, to produce a 20 KB `messages.db` that is byte-for-byte the same every time.
- **Recommendation (test-only, `tests/test_helper.bash`):** build the skill-dir skeleton once per bats file in `$BATS_FILE_TMPDIR` (the `scripts/` copy with its exec bits, the initialised db, and empty `teams/` and `home/`). Each test then gets its own copy with a single `cp -R`.
  - Per test, this takes execs from 23 to 5 and forks from 33 to 5. Locally it takes 72-79 ms down to ~30 ms.
  - The tree it produces is identical to today's in all 298 entries (path, type, mode, size, content hash).
  - Estimated saving per full run: **~300 s macOS (range 240-390) and ~125 s ubuntu (range 95-160)**, about 4 % and 3 %.
- **(c) is already done:** the `ps` reap scan runs only when the plain `rm` fails (test_helper.bash:246-257). **(b) hard links are unsafe:** about 20 files edit their copied scripts in place. An APFS clone (`cp -c`) is safe, but its saving has to be measured on a Mac first.

## 1. What the helper does, and what each part costs locally

`setup_test_env` is test_helper.bash:42-116 and `teardown_test_env` is :238-258. Measurements are on this Linux box (bash 5.2.21, sqlite3 3.45.1) with 20 iterations per component, taken while the box was quiet (load 0.7). The later runs were contended by other jobs and read 2-3x slower in absolute terms, though the ratios held. Scripts are `fixture-overhead/bench.sh` and `initdb_parts.sh`; output is in `bench-run1.txt`.

| step | test_helper.bash | ms | execs / forks |
|---|---|---|---|
| `mktemp -d` for TEST_SKILL_DIR | :65 | 1.9 | 1 / 1 |
| `mkdir -p {scripts,db,teams}` | :66 | 2.0 | 1 / 1 |
| `cp -R scripts/.` (257 files, 36 dirs, 3.4 MB) | :70 | 12.8 | 1 / 1 |
| 3x `chmod +x` (`*.js` matches nothing and fails quietly) | :71, :72, :78 | 5.6 | 3 / 3 |
| `bash init-db.sh` | :81 | **41.4** | **13 / 22** |
| `mkdir -p "$HOME"` | :94 | ~2 | 1 / 1 |
| `mktemp -d` for AGMSG_TEST_TMPDIR | :114 | 1.9 | 1 / 1 |
| teardown: `rm -rf` TMPDIR, then `rm -rf` TEST_SKILL_DIR | :245, :253 | 13.4 (2.2 + 9.8) | 2 / 2 |
| **whole setup + teardown** | | **72.2** | **23 / 33** (strace, `exec-counts.txt`) |
| reap scan, *only if the rm fails*: `$(uname -s)` + `ps -eo pid=,args= \| awk` | :143, :159-160 | 1.8 + 7.0 | 3 / 3+ |

How `init-db.sh` breaks down. It is scripts/internal/init-db.sh, 41 lines; the execs are 6 `dirname`, 3 `sqlite3`, 2 `sed`, 1 `mkdir` and 1 `bash`:

- **bash startup plus sourcing** `lib/storage.sh` and the `validate.sh` and `compat.sh` it pulls in: 12.0 ms.
- **Resolving the db path:** `$(cd "$(dirname ...)" && pwd)` twice, then `dirname` and `mkdir -p`. This brings the total to 20.1 ms.
- **The escape probe:** `sqlite3 -escape off :memory:` at storage.sh:328, ~2.5 ms.
- **The WAL pragma:** init-db.sh:23, ~5 ms.
- **Three autocommit DDL statements:** :28-41, ~7 ms.
- **The `agmsg_sqlite` wrapper:** it adds a command-substitution subshell and a `| sed` to each call (storage.sh:388+).
- **Totals:** a fresh run takes 41.7 ms. A re-run on an existing db still takes 34.7 ms, because almost all of it is process work, not I/O.

Alternatives, measured the same way:

| alternative | ms |
|---|---|
| `cp` of a ready-made `messages.db` | 2.0 |
| `cp -R` from an already-chmod'ed template | same as from the repo (27.7 vs 25.2 ms in an interleaved run under load, `bench_cp.sh`) |
| whole skeleton copy (scripts + db + teams + home) | 28.1 ms in that same run |
| `cp -al` hard-link tree | 6.8 (unsafe; see (b)) |

## 2. Who calls it

Census by `fixture-overhead/usage.py`, which parses column-0 functions and `@test` blocks, skips heredocs, and resolves file-local helpers transitively. Output is `usage-files.tsv` and `usage-tests.tsv`.

- **Coverage:** 107 of 155 files call `setup_test_env` from `setup()`, which covers **2763 of 3140 `@test` cases**. None calls it through a wrapper, and no file uses `setup_file` (0 files). The other 48 files (377 tests) build their own fixture or none at all.
- **Called twice per test:** only two tests do this. `test_api.bats:42-44` runs `teardown_test_env; setup_test_env` to start over with no teams. `test_self_name.bats:556-571` runs it a second time inside `run bash -c` as a regression guard. That makes **2765 setups per full run per OS**.
- **Skipped tests pay it anyway:** `skip` runs only after `setup_test_env` has finished. Usually it sits in the test body; in test_compat.bats it comes later in `setup()` itself (`skip_unless_msys`, :16-18). That file's 8 tests therefore all skip right after the fixture on macOS/ubuntu, which makes them pure-fixture probes (§3).
- **`load` inside `setup()`:** five files (test_self_identity, test_self_name, test_self_proof, test_self_rename, test_sweep_enumeration) run `load 'test_helper'` inside `setup()` before calling `setup_test_env`. That changes nothing init-db depends on.
- **Nothing changes init-db's inputs first:** no file sets `AGMSG_STORAGE_PATH` or a fake `sqlite3` on PATH before `setup_test_env`.

## 3. The per-test overhead from CI

Script: `fixture-overhead/ci_overhead.py`; per-file output in `ci-files.tsv`. Test 1 of each file is excluded because it also carries the file's own startup. Each figure below is a single CI run.

**Reference tests, where the duration is all fixture:**

| what | macOS s | ubuntu s | basis |
|---|---|---|---|
| bats alone (setup-less files, trivial bodies) | 0.028 | 0.025 | p10 of test_refute (0.028/0.024), test_team_guidance_usage (0.029/0.026), test_ci_workflow (0.030/0.026), test_apply_fail_stderr (0.027/0.024), test_close_fds (0.028/0.025) |
| bats + `setup_test_env` + teardown + skip | 0.224-0.250 | 0.110-0.115 | test_compat.bats tests 2-8, all skipped right after setup: min 0.224 / 0.110, median 0.250 / 0.115 |
| the same, plus one `config.sh get` | 0.223-0.227 | 0.116-0.118 | test_config.bats #2 and #6 (`setup()` is only `setup_test_env`, :5-7) |
| other skip-in-body tests | 0.279-0.30 | 0.109-0.111 | test_sync_cipher (4 skips), test_perf_harness (1 skip) |

**Fixed per-test floor: ~0.225 s macOS, ~0.113 s ubuntu.** Taking bats out leaves **`setup_test_env` + `teardown_test_env` at ~0.20 s macOS (0.197-0.222) and ~0.088 s ubuntu (0.085-0.090)**. That is a ratio of 2.3, against 1.1 for bats alone. The macOS penalty sits in the fixture's process and file work, not in bats.

**Per full run:**
- macOS: 2765 × 0.197-0.222 = **545-614 s**. Add 3140 × 0.028 = 88 s for bats.
- ubuntu: 2765 × 0.085-0.090 = **235-249 s**. Add 79 s for bats.

**Per-file floor, the task's p10 view.** Summing p10 × number of tests over the 107 files gives **2607 s macOS (36 % of the suite) and 1513 s ubuntu (37 %)**. Generic fixture plus bats is only ~630 / ~310 s of that ((0.20 + 0.028) × 2762 and (0.088 + 0.025) × 2762). The rest is file-specific `setup()` work, mostly `join.sh`; see D3 in §4.

Top 20 files by macOS p10 × n:

| file | tests | macOS p10 s | ubuntu p10 s | mac/ubu | `join.sh` in `setup()` | p10 × n macOS s | p10 × n ubuntu s |
|---|---|---|---|---|---|---|---|
| test_spawn.bats | 122 | 2.781 | 1.141 | 2.4 | 0 | 339 | 139 |
| test_remote.bats | 152 | 1.911 | 0.972 | 2.0 | 1 | 290 | 148 |
| test_watch.bats | 41 | 3.724 | 2.251 | 1.7 | 2 (pinned) | 153 | 92 |
| test_migrate_team_store.bats | 26 | 4.992 | 3.086 | 1.6 | 4 | 130 | 80 |
| test_remote_sync.bats | 55 | 1.831 | 0.703 | 2.6 | 0 | 101 | 39 |
| test_terminal_registry.bats | 211 | 0.466 | 0.216 | 2.2 | 0 | 98 | 46 |
| test_key.bats | 38 | 2.304 | 1.523 | 1.5 | 2 | 88 | 58 |
| test_delivery.bats | 227 | 0.383 | 0.200 | 1.9 | 0 (pinned) | 87 | 45 |
| test_codex_bridge.bats | 51 | 1.444 | 1.712 | 0.8 | 2 | 74 | 87 |
| test_codex_bridge_launcher.bats | 39 | 1.559 | 1.054 | 1.5 | 1 | 61 | 41 |
| test_messaging.bats | 33 | 1.801 | 1.584 | 1.1 | 2 | 59 | 52 |
| test_watch_once.bats | 13 | 3.903 | 3.065 | 1.3 | 2 | 51 | 40 |
| test_inbox.bats | 21 | 2.393 | 1.557 | 1.5 | 2 | 50 | 33 |
| test_dispatch.bats | 15 | 3.224 | 1.997 | 1.6 | 2 | 48 | 30 |
| test_remote_status_liveness.bats | 44 | 0.951 | 0.907 | 1.0 | 1 | 42 | 40 |
| test_api.bats | 18 | 2.106 | 1.622 | 1.3 | 2 | 38 | 29 |
| test_doctor.bats | 41 | 0.911 | 0.374 | 2.4 | 1 (pinned) | 37 | 15 |
| test_jsonl_remote_sync.bats | 25 | 1.370 | 0.645 | 2.1 | 0 | 34 | 16 |
| test_team.bats | 87 | 0.393 | 0.195 | 2.0 | 0 | 34 | 17 |
| test_session_start_claude_code_native_channel.bats | 29 | 1.171 | 1.190 | 1.0 | 1 | 34 | 35 |
| **all 107 files** | 2762 | | | | | **2607** | **1513** |

### How much of the macOS 0.20 s is init-db, and how much is the copy

Two files that are not part of the 107 build their fixture without init-db: test_delivery_cli.bats (:11-21 plus a teardown `rm -rf` at :34) and test_daemon_offer.bats (:6-15, :28). Their fixture is `mktemp`, a `cd/pwd` subshell, a `cp -R` of the same 257-file `scripts/` tree, `mkdir`, one `sqlite3` schema load, and `rm -rf`.

- **The copy and delete are cheap even on macOS.** Their cheapest tests take **0.133 s macOS and 0.072 s ubuntu**: test_delivery_cli #17, whose body is 7 `grep` execs, and test_daemon_offer #8, one `daemon.sh offer`. Taking out bats and the body leaves ~0.07 s macOS (~0.035 s ubuntu) for copying and deleting the tree plus a few execs.
- **So the parts the recommendation removes are most of the cost.** The `setup_test_env` fixture costs 0.20-0.22 s. The chmods, init-db and mkdirs therefore account for **~0.13-0.15 s macOS and ~0.053 s ubuntu**.
- **An exec-count check agrees.** The recommendation removes 18 execs, 9 more forks and 3 small sqlite writes. At the 4.5-6 ms (macOS) and 1.7-2.2 ms (ubuntu) per exec estimated in `test_remote.md`, that comes to ~0.09-0.13 s and ~0.036-0.045 s. Scaling the local saving by the CI/local ratio gives ~0.047-0.06 s on ubuntu.

The estimates below use **0.115 s per test on macOS (range 0.09-0.15) and 0.047 s on ubuntu (0.036-0.06)** for the full template.

## 4. Options

Savings are per full run per OS. They count 2765 setups minus the first test of each of the 107 files, which builds the cache and pays one extra `cp -R`: about 107 × 0.03 s macOS and 107 × 0.013 s ubuntu.

| option | macOS s | ubuntu s | isolation risk | notes |
|---|---|---|---|---|
| **A+. Per-file skill-dir template** (scripts, chmod, initialised db, teams/, home/), one `cp -R` per test | **~300** (240-390) | **~125** (95-160) | low | Recommended. 23 → 5 execs per test, 33 → 5 forks. Tree identical to today's. |
| A. Database-only template: init-db once per file, `cp messages.db` per test | ~235 (180-275) | ~100 (80-115) | low | 23 → 11 execs. Smallest diff. Matches the per-file reports' D1/T4 prototype (`work-wdt/prototype.diff`). |
| B1. Per-file chmod'ed scripts template, re-copied per test (no db) | ~40 | ~16 | low | Saves only the 3 chmods. The copy itself costs the same from a template as from the repo. |
| B2. Hard-linked scripts tree (`cp -al`, `pax -rwl`) | ~50-100 (unmeasured) | ~18 | **high: reject** | Appends, truncating rewrites, `cp` over a file, `chmod` and `touch` all change the shared inode. That changes the template and every later test in the file. |
| B3. APFS clone (`cp -c -R`) for the per-test copy on macOS | 0-50 (unmeasured) | 0 (ext4 has no reflink) | low | Each clone is an independent file (copy-on-write), so it is semantically safe. Needs a Mac measurement and a Darwin-only guard. Possible follow-up to A+. |
| C. Skip the helper's reap scan when the test started nothing | **0** | **0** | n/a | Already done: the scan runs only when the plain `rm` fails (test_helper.bash:246-257, since #1123). |
| C'. Gate the unconditional per-file teardown scans behind a launch flag | ~5-7 | ~2 | medium | test_spawn.bats:47 and test_watch.bats:158 (`_reap_test_skill_dir_procs`), test_roster_journal.bats:27 (`pgrep -f`), test_sync_autostart.bats:53 (`pkill -f`). 207 tests in all. |
| D1. `$OSTYPE` in place of `$(uname -s)` in the helpers | ~3-5 | ~1-2 | low | 157 call sites of `skip_on_windows`, `skip_unless_*` and `file_mode`, plus 36 inline. |
| D2. Product change: cache the sqlite3 `-escape` probe across processes | ~25-90 (rough) | ~10-33 (rough) | low-medium | Not test-only. One extra `sqlite3` per DB-touching bash process (storage.sh:323-331). At least 4341 script invocations appear statically per run. |
| D3. Per file: pin `AGMSG_AGENT_PID=""`, or build `join.sh` output once in `setup_file` | up to ~600 (walk only) | up to ~450 | medium | Not suite-wide. 29 files run `join.sh` in `setup()`: 1038 calls per run, 865 of them unpinned. Files that test the ancestor walk must keep it. |
| D4. One `mktemp` parent holding both TEST_SKILL_DIR and TMPDIR, one `rm` | ~28 | ~11 | low-medium | Saves 2 execs per test, but changes the path shape. Not worth bundling. |

### (a) Template db: what init-db.sh writes

- **The output is a single file, `db/messages.db` (20480 bytes).** Nothing else is written: no `config.yaml`, no `run/`, and no `-wal`/`-shm` files after exit, because sqlite checkpoints and removes them on close.
- **It is identical on every run.** Two runs 1.1 s apart produced byte-identical files (`cmp`). `strings` shows only the schema SQL. No path or timestamp is embedded.
- **Header and schema:** bytes 18-19 are `2 2` (persistent WAL). `PRAGMA journal_mode` is `wal`, `user_version` is 0, and the schema is `messages`, `sqlite_sequence`, `idx_unread` and `idx_history`.
- **Inputs:** the db location comes from `_agmsg_runtime_db_path` → `agmsg_storage_dir` (storage.sh:256, :268-275, :91-117). That is `AGMSG_STORAGE_PATH` if set, otherwise `<script dir>/../../db`. Running from a copied tree therefore lands in the copy's own `db/`. init-db.sh runs before HOME is sandboxed (test_helper.bash:81 vs :93) and does not touch HOME. In production, `send.sh:90` re-runs init-db only when the file is missing, so a ready-made file changes nothing there.
- **Tests that change the schema or the journal mode act on their own per-test db.** Examples: test_storage.bats:401 and :442 (`DROP INDEX events_id; PRAGMA user_version=0`), :520 (`journal_mode=DELETE`, which uses `$BATS_TEST_TMPDIR`), test_storage_contract.bats:127 (`user_version=0`) and :226 (`rm -f db/messages.db*`), and test_remote_sync.bats:761. With a per-test copy they cannot reach the template or each other.
- **Tests that exercise init itself use their own paths**, which the template does not touch: test_storage.bats #6 (override path), #13 and #15 (fresh override stores).
- **No test checks `messages.db` mtime, inode or checksum** (grep for stat, `-nt`, cksum and touch on `db/messages.db`). Plain `cp` gives a fresh mtime anyway, as init-db would. `cp -p` would carry the first test's mtime, so the prototype's `cp -p` should become plain `cp`.

### (b) The scripts copy

- **Copying from a template costs the same as copying from the repo:** ~12.8 ms per 257 files locally. So a per-file scripts cache only saves the chmods (B1).
- **Tests edit their copied `scripts/` in place.** Examples:
  - **Append:** test_agmsgd_entrypoint.bats:156, :214, :249; test_placement_collisions.bats:192; test_reset_role_session.bats:90; test_terminal_registry.bats:4724; test_type_registry.bats:178.
  - **Truncate and rewrite:** test_inbox.bats:49-52, :80 (`lib/storage.sh` becomes `exit 99`); test_key.bats:51, :70; test_spawn.bats:328, :1881; test_self_fix.bats:473-848 (12 sites); test_session_start_claude_code_native_channel.bats:436, :459, :497; test_codex_bridge.bats:2400; test_codex_bridge_launcher.bats:61; test_agmsgd_launch.bats:129; test_delivery.bats:838; test_type_registry.bats:168, :179, :187.
  - **`cp` over an existing file:** test_sync_autostart.bats:306-486 (6 sites); test_delivery.bats:865.
  - **chmod:** test_watch_agmsgd_note.bats:57, :61; test_watch_install_changed.bats:174, :181; test_spawn.bats:1723, :1730; test_type_registry.bats:160 (`chmod 000`); test_agmsgd_daemon_sh.bats:10.
  - **touch:** test_watch_install_changed.bats:134, :239.
  - **mv/rm, which only touch directory entries:** test_codex_monitor.bats:144; test_team.bats:447, :449; test_watch_install_changed.bats:94, :149; test_agmsgd_entrypoint.bats:224, :273, :315; test_type_registry.bats:152.

  That is 20 of the 107 `setup_test_env` files. The full list is in `writes-cmds.txt` and `writes-redirect.txt` (149 grep hits, including reads and three files with their own fixture, e.g. test_agmsgd_switch.bats:136-191).
- **What this rules out:** with hard links or a symlinked tree, every in-place modification above would leak into the template and into the later tests of the same file. Only real copies or clones are safe.
- **Nothing writes into the repo's own `scripts/`** (grep for writes to `$BATS_TEST_DIRNAME/../scripts`). The template therefore always matches the repo for the life of a file's run.

### (c) The process-reap scan

- **The helper's teardown already avoids the scan.** It tries `rm -rf` first and scans with `ps` only if that fails. The failure is the very symptom the reap exists for: a detached holder writing into `run/`.
- **The helper has no safer signal to skip on:**
  - `jobs -p` cannot see detached grandchildren: codex-monitor.sh starts the launcher with `… &` and it outlives the script.
  - The launcher writes no pidfile.
  - A `run/*.pid` check would miss argv-only holders.
- **Four files scan unconditionally anyway:** test_spawn.bats:47, test_watch.bats:158, test_roster_journal.bats:27 and test_sync_autostart.bats:53, 207 tests together.
  - They scan to kill leaked processes that do not make `rm` fail (for example a `sleep 600` whose argv names the dir) but would hold bats's output pipe. So gating them on `rm` failure would be unsafe.
  - The safe pattern is test_despawn.bats:32-34: scan only if a test set `_WATCHER_LAUNCHED`.
  - The saving is small: a scan costs ~9 ms locally, an estimated ~25-35 ms on macOS, which is 3 execs.

### (d) Other findings

- **D3 is the largest remaining per-test lever, but it is not suite-wide.**
  - 29 of the 107 files run `join.sh` in `setup()`: 688 tests and 1038 `join.sh` runs per full run per OS. Only 6 files (107 tests) pin `AGMSG_AGENT_PID=""`, which skips the ancestor walk.
  - Per `test_remote.md`'s fixture table, the walk costs ~0.65-0.75 s macOS and ~0.5-0.55 s ubuntu per call. The rest of a `join.sh` costs ~0.4-0.5 / 0.12-0.17 s.
  - That is how the per-file floor reaches 2607 / 1513 s. It belongs in the per-file reports (for example `setup_file` templates of join output, as in `work-wdt/prototype.diff` for test_watch), not in `setup_test_env`, because some files test the walk itself.
- **D2: repeated sqlite3 spawns come from product code, not the fixture.** `agmsg_sqlite` memoises the escape probe only per shell (storage.sh:323-331, reset at source time). Every script invocation that touches the db therefore pays one extra `sqlite3` (~2.5 ms locally). A test-only change cannot pre-seed it.
- **Per-test `load test_helper`** sources 800 lines in every test process (bats-exec-test is exec'd per test). This is already included in the ~0.028 s bats figure, so it is not worth chasing.

## 5. Recommended change (test-only PR) and diff

What it does: in `tests/test_helper.bash`, build the skeleton once per file into `$BATS_FILE_TMPDIR/agmsg-skill-template` from the first test's `setup_test_env`, then `cp -R` it into each test's own `TEST_SKILL_DIR`. If anything is unusual, it falls back to today's code path unchanged:
- no `BATS_FILE_TMPDIR` (the helper is sourced outside bats);
- `AGMSG_STORAGE_PATH` is set;
- another test of the same file is building the template right now (`bats --jobs`); `mkdir` serves as the lock, and the loser does not wait;
- the template build failed.

Full patch: `fixture-overhead/proposed-template.diff` (92 lines including comments; helper: `test_helper.new.bash`). The core:

```diff
+_agmsg_populate_skill_dir() {   # <dir>  -- today's steps, chained so a failure is the status
+  mkdir -p "$1"/{scripts,db,teams,home} &&
+  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$1/scripts/" &&
+  chmod +x "$1/scripts/"*.sh &&
+  { chmod +x "$1/scripts/"*.js 2>/dev/null || true; } &&
+  { chmod +x "$1/scripts/drivers/types/codex/"*.sh 2>/dev/null || true; } &&
+  bash "$1/scripts/internal/init-db.sh"
+}
+
+_agmsg_copy_skill_template() {   # <dir>
+  local tpl="${BATS_FILE_TMPDIR:-}"
+  [ -n "$tpl" ] && [ -z "${AGMSG_STORAGE_PATH:-}" ] || return 1
+  tpl="$tpl/agmsg-skill-template"
+  if [ ! -f "$tpl.ready" ]; then
+    mkdir "$tpl" 2>/dev/null || return 1            # lock; a parallel loser takes the old path
+    _agmsg_populate_skill_dir "$tpl" || { rm -rf "$tpl"; return 1; }
+    : > "$tpl.ready"
+  fi
+  cp -R "$tpl/." "$1/"                              # plain cp: fresh inodes and mtimes
+}
@@ setup_test_env
   export TEST_SKILL_DIR="$(TMPDIR="$AGMSG_TEST_REAL_TMPDIR" mktemp -d)"
-  mkdir -p "$TEST_SKILL_DIR"/{scripts,db,teams}
-  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$TEST_SKILL_DIR/scripts/"
-  chmod +x "$TEST_SKILL_DIR/scripts/"*.sh
-  chmod +x "$TEST_SKILL_DIR/scripts/"*.js 2>/dev/null || true
-  chmod +x "$TEST_SKILL_DIR/scripts/drivers/types/codex/"*.sh 2>/dev/null || true
-  bash "$TEST_SKILL_DIR/scripts/internal/init-db.sh"
+  _agmsg_copy_skill_template "$TEST_SKILL_DIR" ||
+    _agmsg_populate_skill_dir "$TEST_SKILL_DIR"
@@
   export HOME="$TEST_SKILL_DIR/home"
-  mkdir -p "$HOME"
+  [ -d "$HOME" ] || mkdir -p "$HOME"
```

How this differs from the per-file D1/T4 prototype:
- it also folds in the 3 chmods and 2 mkdirs (+65 s macOS / +25 s ubuntu);
- it publishes the template atomically, so `bats --jobs` cannot copy a half-written file;
- plain `cp`, not `cp -p`;
- an `AGMSG_STORAGE_PATH` guard;
- a verified identical tree.

### Verification done locally

Everything ran in a copy of the repo under `fixture-overhead/sandbox`; the repo itself was not touched.

- **Same tree (`compare_trees.sh`):** today's helper, the first test (template build), a later test (template copy), and the no-bats fallback all produce the same 298 entries (path, type, mode, size, sha1). The root stays at mode 700, HOME exists, and nothing is left in TMPDIR.
- **Exec census (`count_execs.sh`):**
  - today's helper: 23 execs / 33 forks per test;
  - database-only: 11 / 11;
  - template: **5 / 5** (`cp` 1, `mktemp` 2, `rm` 2);
  - the first test of a file under the template: 24 / 34.
- **Local timing:** the box was contended by other jobs, so only interleaved rounds compare fairly (`bench_variants.sh`, `bench-variants2.txt`). In the quiet rounds today's helper took 79-91 ms, database-only 42-43 ms and the template 30-36 ms. The template came out fastest in every round.
- **28 single tests via `bats -f` (`validate.sh`), chosen to exercise isolation:**
  - test_inbox #1-#4: #1 rewrites `lib/storage.sh` to `exit 99`, and later tests must not see it;
  - test_type_registry's overlay tests (`rm` / `chmod 000` / truncate `template.md`);
  - test_api #2 (re-setup in the body);
  - test_self_name #18 (`setup_test_env` inside `run bash -c`);
  - test_storage's init and schema tests;
  - the test_teardown_reap reaper tests;
  - test_agmsgd_entrypoint #5 followed by #10.

  Results are identical with the original and the patched helper: 26 ok and the same 2 failures, which come from this environment (outputs identical apart from pids):
  - test_teardown_reap #2: the container's PID 1 leaves the orphan as a zombie, so `kill -0` succeeds;
  - test_agmsgd_entrypoint #10: node 22.23's `ExperimentalWarning:` matches the test's `Warning:` grep.

### Checks for the PR's own CI run

1. Full suite green on ubuntu and macOS, plus the Windows legs that use `setup_test_env` (test_codex_monitor.bats, test_codex_bridge_launcher.bats run on Git Bash).
2. Compare pure-fixture tests before and after.
   - test_compat.bats tests 2-8: macOS 0.224-0.250 → expect ~0.11-0.14; ubuntu 0.110-0.115 → expect ~0.06-0.07.
   - test_config.bats #2 and #6 should move the same way.
3. Total bats seconds per OS should drop by ~300 / ~125 s; shard totals vary run to run, so compare more than one run.
4. The saving is uniform per test, so per-file weights shift in proportion to test counts. Re-measure `.github/scripts/bats-file-seconds.tsv` only if test_ci_sharding.bats's balance check goes red.

Optional follow-ups, not in this PR:
- B3: `cp -c` on Darwin, measured on a macOS runner first;
- C': a launch flag in the 4 always-scanning teardowns;
- D1: `$OSTYPE` in the helpers;
- D2: a product PR to share the escape probe across processes;
- D3: per-file setup work (`AGMSG_AGENT_PID` pinning, join templates).
