# Test strategy survey: where agmsg CI time goes

Scratch survey, not documentation. Branch `test-strategy-survey`, not for merge.
Status: in progress. Sections 2-5 are filled in as the measurements finish.

Data sources (all reproducible with the scripts in `tools/`):

- CI run [41607512279](https://github.com/fujibee/agmsg/actions/runs/41607512279)
  (push to main at 64723d6, the first run with 6 shards, green). Its
  `bats-timings-*` artifacts (12, all shards of both OSes) give per-file
  seconds; its job logs give per-test seconds (each log line carries a
  timestamp, so a test's duration is the gap since the previous TAP line).
- `.github/scripts/bats-file-seconds.tsv`: the max-of-two-runs macOS table
  from #1884, used as a second observation.
- Local measurements on a Linux container (4 cores, bash 5.2, bats 1.13.0).

## 0. What one CI run costs

`tests.yml` runs the whole bats suite on every PR push and again on every
push to main (and integration branches), on ubuntu-latest and macos-latest,
6 shards each. Docs-only PRs skip it.

| | macOS | ubuntu |
|---|---:|---:|
| bats time per full run (sum over shards) | 7195 s | 4069 s |
| slowest shard (bats only) | 1382 s | 774 s |
| `bash` on PATH | 3.2.57 (`/bin/bash`, arm64) | 5.3.9 |
| test cases run / skipped | 3049 / 90 | 3039 / 100 |

Both OS legs run the same 155 files and 3140 cases. macOS is 1.77x slower
in total, and it is the only place bash 3.2 runs: the macOS leg tests BSD
userland and bash 3.2 at the same time (this matters for item 5).

## 1. Per-file seconds

Full table: `data/per-file-seconds.tsv` (macOS from run 41607512279, macOS
from the #1884 table, ubuntu, ratio, test and skip counts). Per-test table:
`data/per-test-seconds-run41607512279.tsv`.

The 15 slowest files are 62.6 % of macOS time:

| file | macOS s | ubuntu s | mac/ubuntu | cum. % of macOS |
|---|---:|---:|---:|---:|
| test_install.bats | 764 | 238 | 3.2 | 10.6 |
| test_spawn.bats | 653 | 270 | 2.4 | 19.7 |
| test_remote.bats | 557 | 255 | 2.2 | 27.4 |
| test_watch.bats | 384 | 245 | 1.6 | 32.8 |
| test_delivery.bats | 306 | 151 | 2.0 | 37.0 |
| test_remote_sync.bats | 273 | 138 | 2.0 | 40.8 |
| test_codex_bridge_launcher.bats | 268 | 202 | 1.3 | 44.5 |
| test_agmsgd_daemon_sh.bats | 220 | 92 | 2.4 | 47.6 |
| test_team.bats | 212 | 134 | 1.6 | 50.5 |
| test_terminal_registry.bats | 206 | 110 | 1.9 | 53.4 |
| test_self_name.bats | 193 | 71 | 2.7 | 56.1 |
| test_migrate_team_store.bats | 167 | 95 | 1.8 | 58.4 |
| test_ci_sharding.bats | 153 | 112 | 1.4 | 60.5 |
| test_codex_bridge.bats | 145 | 144 | 1.0 | 62.6 |
| test_roster_journal.bats | 109 | 84 | 1.3 | 64.1 |

test_install.bats was 491-550 s in the #1884 measurement and 764 s here:
single runs vary a lot on macOS, so estimates below quote ranges.

### Per-test distribution

| | macOS | ubuntu |
|---|---:|---:|
| median test | 1.00 s | 0.58 s |
| 10th percentile | 0.24 s | 0.13 s |
| 90th percentile | 5.75 s | 2.88 s |
| tests under 1 s (count / total s) | 1522 / 655 s | 1864 / 616 s |
| tests 2-10 s | 964 / 4173 s | 512 / 1901 s |
| tests 10 s and over | 79 / 1394 s | 28 / 496 s |

The time is not in a few pathological tests: the bulk is in ~1000 tests of
2-10 s each, which means per-test fixed cost (fixture setup, script
start-up, sqlite3 spawns) and repeated arrange steps matter as much as the
outliers.

Slowest single tests on macOS:

| macOS s | ubuntu s | file | # | test |
|---:|---:|---|---:|---|
| 84.1 | 44.3 | test_remote_sync.bats | 53 | read-state: the roster list bound is swept on both sides -- 10,000 ... |
| 69.5 | 19.3 | test_install.bats | 97 | bare --update preserves every renderable type's SKILL.md flavor |
| 51.1 | 43.9 | test_watch.bats | 1 | --max-seconds ends the run with a re-arm line after a delivery |
| 49.7 | 36.8 | test_ci_sharding.bats | 9 | the shards cover every test file exactly once |
| 42.3 | 0.1 | test_agmsgd_daemon_sh.bats | 13 | enable/disable registers a resident unit (fake launchctl) |
| 42.1 | 31.5 | test_ci_sharding.bats | 14 | pinned-apart heavy files never share a shard, at any shard total |
| 40.1 | 21.0 | test_wait_helpers.bats | 7 | wait_for_file / wait_for_missing / wait_for_file_is agree |
| 40.0 | 16.1 | test_install.bats | 94 | --update moves removed/overwritten scripts/ files to .trash/ |
| 24.3 | 16.9 | test_self_proof.bats | 39 | the whole suite passes under each caller shell state |
| 23.8 | 10.2 | test_self_name.bats | 6 | another seat in the same pane does NOT take it ... |

### Fixed per-test cost

`setup_test_env` (107 of 155 files) copies all of `scripts/` (257 files,
4 MB) into a temp dir and runs `scripts/internal/init-db.sh` for every
test. Locally on Linux one setup+teardown costs ~68 ms: cp -R 18 ms,
chmod 3 ms, init-db.sh 36 ms, teardown the rest. The macOS 10th-percentile
test (0.24 s vs 0.13 s on ubuntu) suggests the floor is roughly twice as
high there. See section 4.

## 2. Duplicate executions since v1.7.0

In progress (needs the run inventory and the dependency graph).

## 3. Dependency graph

In progress. Method: every test file is run under
`strace -f -e trace=execve,openat` (`tools/strace_sweep.sh`) and the files
it actually executed or read are mapped back to repo paths
(`tools/extract_reads.py`; reads by cp/find/ls etc. are ignored so the
`cp -R scripts/` in the fixture does not count as reading every script).
That is compared with a static source/exec analysis to find where each
approach misses.

## 4. Shortening candidates (15 slowest files)

In progress.

## 5. Which files need macOS

In progress. Key fact already measured: macOS runners execute the suite
with bash 3.2.57, ubuntu with bash 5.3. "OS-dependent" therefore has two
axes: Darwin/BSD userland, and bash 3.2 semantics. The second could be
covered on a Linux runner with a bash 3.2 build, which would leave macOS
only the first.

## What could not be obtained

- Runner queue wait per job (job-level listings are large through the
  GitHub MCP; collected only where needed).
- The exact merge-ref commit a pull_request run tested (runs report the PR
  head SHA; the merge with the base at that moment is approximated by the
  head).
