# test_team.bats: where the CI time goes and how to cut it

Data: CI run 41607512279 (main @ 64723d6), per-test durations from
`per-test-41607512279.tsv` (a test's seconds include its own setup and teardown).
Code references are to main @ 551764e. Local numbers come from a loaded 4-core Linux
box and are used only as before/after ratios.

## Summary

- 87 tests, **211.9 s macOS / 133.5 s ubuntu** per full run (mac/ubu 1.59). No fixed
  sleeps anywhere in the file; only one test (#5) is above 7 s.
- The per-test fixture is cheap (setup_test_env only, test_team.bats:5-11): the no-op
  tests (#70, #71, #83) cost 0.23-0.26 s macOS / 0.12-0.13 s ubuntu.
- **`join.sh` is the file's cost**: ~112 runs per full run (it is both the subject of
  the `join:` tests and the arrange step of almost every other test). At ~1.17 s
  macOS / ~0.77 s ubuntu each that is **~131 s macOS / ~86 s ubuntu (62 % / 64 %)**.
- Of each `join.sh`, ~0.45 s macOS / ~0.35 s ubuntu is the agent-ancestor walk
  (`agmsg_resolve_project` -> `agmsg_agent_pid`, resolve-project.sh:489/710), which on
  a CI runner climbs ~10 ancestors with 3 `ps` + ~7 other execs per hop and finds
  nothing. `whoami.sh` and `reset.sh` walk too (19 more walks). test_delivery.bats pins
  the walk off with `AGMSG_AGENT_PID=""`; this file does not.
- Proposals: T1 (pin, one line) **~55 s macOS / ~45 s ubuntu**; T2 (smaller fan-out in
  #5, medium risk) ~7 / ~3; T4 (per-file init-db cache) ~4 / ~2; T3 (fewer forks inside
  join.sh, production) ~25 / ~15. T1 was checked on five tests at a CI-like process
  depth: 20.0 s -> 12.3 s locally, all passing.

## Where the time goes

Aggregate (per full run):

| bucket | macOS s | ubuntu s | basis |
|---|---:|---:|---|
| `join.sh` runs (112 that reach the walk; 13 of them in #5) | ~131 | ~86 | J = 1.17 / 0.77 s (test #62 "join: accepts claude-code" 1.40/0.89 minus the no-op baseline #70 0.23/0.12); the 8 single-join tests #62-#66, #76-#78 span 0.80-1.17 s macOS / 0.75-0.86 s ubuntu |
| ...of which the ancestor walk | ~50 | ~39 | W = 0.45 / 0.35 s per walk (see test_watch.md P1 for the measurement) |
| walks in whoami.sh (15) and reset.sh (4) | ~9 | ~7 | 19 x W |
| per-test base (setup_test_env, bats, teardown) | ~21 | ~11 | 87 x 0.24 / 0.13 s |
| team.sh / leave / rename / send / inbox / JSONL driver work, #5's lock contention | ~51 | ~30 | remainder |

Per test, sorted by macOS seconds (the first 44 rows are 70 % of the macOS time; the
table runs to 81.8 %). "joins" counts `join.sh` runs that reach the walk (rejections
before `agmsg_resolve_project` and the ext-tool join, which skips it, are excluded;
rejections after it, as in #54-#57, are included). "walks (non-join)" counts
`whoami.sh`/`reset.sh` walks (mocked-ps tests #26/#28/#30 and #29 do not walk).

| # | title | macOS s | ubuntu s | mac/ubu | cum % mac | joins | walks (non-join) | fixed waits s | driver |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| 5 | join: concurrent joins to the same team do not lose registrations (... | 17.81 | 9.13 | 1.95 | 8.4 | 13 | 0 | 0 | 13 joins (1 seed + 12 concurrent) serialized on the team registry lock; 11 waiters spin (sleep 0.01 + date + holder checks per try) -> CPU contention, macOS 1.95x ubuntu |
| 48 | rename: JSONL keeps exact reads and cursor with the new agent name | 6.56 | 4.20 | 1.56 | 11.5 | 1 | 0 | 0 | 1 join + JSONL driver ops in-process (send/tip/consume/history/list_unread: jq/lock heavy) + rename |
| 86 | team: --purge-messages removes only that team's message rows, leave... | 6.41 | 4.21 | 1.52 | 14.5 | 4 | 0 | 0 | 4 joins + 2 sends + team.sh --purge-messages + checks |
| 40 | rename-team: JSONL keeps the cursor with the renamed event stream | 5.94 | 3.51 | 1.69 | 17.3 | 1 | 0 | 0 | 1 join + JSONL driver ops in-process (storage_send/tip/consume/history: jq/lock heavy) + rename-team |
| 59 | rename-team: escapes quoted team names and migrates only the matchi... | 5.89 | 4.28 | 1.38 | 20.1 | 4 | 0 | 0 | 4 joins + 2 sends + rename-team + 2 inbox |
| 31 | reset: removes only current project registration | 5.64 | 3.52 | 1.60 | 22.8 | 2 | 3 | 0 | 2 joins + reset (1 walk) + 2 whoami (2 walks) |
| 85 | team: --delete removes an empty team's folder and run/ records, lea... | 5.33 | 3.66 | 1.45 | 25.3 | 4 | 0 | 0 | 4 joins + 2 leaves + 2 team.sh --delete |
| 11 | team: shows team members with types | 4.60 | 2.46 | 1.87 | 27.5 | 2 | 0 | 0 | 2 joins + ext-tool setup + ext-tool join (no walk) + team.sh |
| 3 | join: adds multiple agents to same team | 4.54 | 2.10 | 2.16 | 29.6 | 2 | 0 | 0 | 2 joins + 1 team.sh |
| 13 | team --json emits one full object per registration | 4.33 | 2.20 | 1.97 | 31.6 | 2 | 0 | 0 | 2 joins + team.sh --json + 4 sqlite_mem probes |
| 37 | rename-team: preserves agents in the team | 4.16 | 2.29 | 1.82 | 33.6 | 2 | 0 | 0 | 2 joins + 2 team.sh |
| 38 | rename-team: migrates messages to the new team name | 4.07 | 2.39 | 1.70 | 35.5 | 2 | 0 | 0 | 2 joins + 1 team.sh + 1 send + 1 inbox |
| 27 | whoami: explicit type overrides auto-detection | 3.95 | 2.65 | 1.49 | 37.4 | 2 | 1 | 0 | 2 joins + clear_autodetect_env + whoami (walk) |
| 87 | team: --delete refuses when members remain or the team is actively ... | 3.83 | 2.83 | 1.35 | 39.2 | 3 | 0 | 0 | 3 joins + team.sh --delete refusals |
| 4 | join: re-join shows one row per registration without duplicating th... | 3.70 | 1.93 | 1.92 | 40.9 | 2 | 0 | 0 | 2 joins + 1 team.sh |
| 46 | rename: migrates messages to the new agent name | 3.66 | 2.47 | 1.48 | 42.7 | 2 | 0 | 0 | 2 joins + 1 send + 1 inbox |
| 39 | rename-team: atomically migrates cursor and sync sidecars | 3.60 | 1.84 | 1.95 | 44.4 | 1 | 0 | 0 | 1 join + sourced storage/sync schema setup + rename-team + 2 sqlite + jq |
| 7 | leave: removes agent from team | 3.49 | 1.98 | 1.76 | 46.0 | 2 | 0 | 0 | 2 joins + 1 team.sh |
| 19 | whoami: returns multiple when multiple identities | 3.42 | 2.21 | 1.55 | 47.6 | 2 | 1 | 0 | 2 joins + 1 whoami |
| 9 | leave: an agent name containing a single quote doesn't break the un... | 3.34 | 2.02 | 1.65 | 49.2 | 2 | 0 | 0 | 2 joins + 1 team.sh |
| 21 | whoami: finds re-joined agent in another project registration | 3.28 | 2.20 | 1.49 | 50.8 | 2 | 1 | 0 | 2 joins + 1 whoami |
| 23 | whoami: auto-detects claude-code from CLAUDE_CODE_SESSION_ID env | 3.26 | 1.96 | 1.66 | 52.3 | 1 | 1 | 0 | 1 join + clear_autodetect_env (type-registry loop) + whoami (walk) |
| 22 | whoami: suggests same-type agents registered elsewhere when no exac... | 2.98 | 1.54 | 1.94 | 53.7 | 1 | 1 | 0 | 1 join + 1 whoami |
| 56 | join: a rejected forced reassignment leaves the rename tombstone in... | 2.91 | 2.36 | 1.23 | 55.1 | 3 | 0 | 0 | 1 join + rename + 2 joins rejected after the walk (tombstone/--force checks) |
| 32 | reset: retires the member when its last registration is cleared | 2.91 | 1.58 | 1.84 | 56.4 | 1 | 1 | 0 | 1 join + 1 reset |
| 24 | whoami: auto-detects codex from CODEX_SANDBOX env | 2.88 | 2.15 | 1.34 | 57.8 | 1 | 1 | 0 | 1 join + clear_autodetect_env + whoami (walk) |
| 47 | rename: atomically migrates cursor and remote member association | 2.74 | 1.87 | 1.46 | 59.1 | 1 | 0 | 0 | 1 join + sourced storage/sync schema setup + rename + 3 sqlite |
| 30 | whoami: no type argument still answers when the fallback name is no... | 2.73 | 1.61 | 1.69 | 60.4 | 1 | 0 | 0 | 1 join + clear_autodetect_env + mocked ps + whoami |
| 25 | whoami: auto-detects codex from CODEX_THREAD_ID env | 2.67 | 2.18 | 1.23 | 61.6 | 1 | 1 | 0 | 1 join + clear_autodetect_env + whoami (walk) |
| 28 | whoami: rejects an explicit unknown type instead of answering not_j... | 2.61 | 1.34 | 1.94 | 62.9 | 1 | 0 | 0 | 1 join + clear_autodetect_env + mocked ps + whoami (exits at the type check) |
| 57 | join: joining the new name after a rename succeeds normally | 2.56 | 1.81 | 1.41 | 64.1 | 2 | 0 | 0 | 2 joins + rename |
| 20 | whoami: lists available teams when not joined | 2.48 | 1.52 | 1.63 | 65.3 | 1 | 1 | 0 | 1 join + 1 whoami |
| 42 | rename-team: fails when new team already exists | 2.45 | 1.65 | 1.48 | 66.4 | 2 | 0 | 0 | 2 joins + rename-team refusal |
| 33 | reset: an explicit agent_id containing a single quote doesn't break... | 2.41 | 1.57 | 1.54 | 67.5 | 1 | 1 | 0 | 1 join + 1 reset |
| 54 | join: refuses to silently revive a name that was just renamed away | 2.35 | 1.91 | 1.23 | 68.7 | 2 | 0 | 0 | 1 join + rename + 1 join rejected after the walk + team.sh |
| 16 | whoami: resolves team and agent names containing single quotes | 2.28 | 1.49 | 1.53 | 69.7 | 1 | 1 | 0 | 1 join + 1 whoami |
| 26 | whoami: defaults to claude-code when no env vars set | 2.25 | 1.65 | 1.36 | 70.8 | 1 | 0 | 0 | 1 join + clear_autodetect_env + mocked ps + whoami (walk ends at mocked ppid 1) |
| 15 | whoami: resolves project paths containing single quotes | 2.23 | 1.52 | 1.46 | 71.9 | 1 | 1 | 0 | 1 join + 1 whoami |
| 35 | rename-team: renames the team dir and updates config.json name | 2.23 | 1.08 | 2.06 | 72.9 | 1 | 0 | 0 | 1 join + rename-team |
| 60 | rename: escapes the agent name in the messages UPDATE without widen... | 2.19 | 1.38 | 1.60 | 73.9 | 1 | 0 | 0 | 1 join + rename + sqlite probes |
| 50 | rename: fails when new agent already exists | 2.16 | 1.72 | 1.26 | 75.0 | 2 | 0 | 0 | 2 joins + rename refusal |
| 45 | rename: renames an agent, preserving its registration | 2.14 | 1.41 | 1.52 | 76.0 | 1 | 0 | 0 | 1 join + rename + team.sh |
| 1 | join: creates team and adds agent | 2.11 | 1.13 | 1.87 | 77.0 | 1 | 0 | 0 | 1 join (also absorbs the file's first-test overhead) |
| 55 | join: --force cannot reassign a renamed-away identity name | 2.11 | 1.72 | 1.22 | 78.0 | 2 | 0 | 0 | 1 join + rename + 1 join rejected after the walk |
| 8 | leave: retains an id-bearing team when its last member leaves | 2.06 | 1.11 | 1.86 | 78.9 | 1 | 0 | 0 | 1 join + leave |
| 36 | rename-team: a new team name containing a single quote doesn't brea... | 2.04 | 1.07 | 1.92 | 79.9 | 1 | 0 | 0 | 1 join + rename-team |
| 14 | whoami: returns agent identity | 2.01 | 1.51 | 1.34 | 80.8 | 1 | 1 | 0 | 1 join + 1 whoami |
| 43 | rename-team: an inert empty target dir does not block the rename | 1.99 | 1.28 | 1.55 | 81.8 | 1 | 0 | 0 | 1 join + rename-team + team.sh |
| | **total (87 tests)** | **211.9** | **133.5** | 1.59 | | 112 | 19 | 0 | |

Remaining 39 tests (macOS/ubuntu s): #81 1.90/1.30; #12 1.85/1.08; #2 1.84/0.86;
#53 1.70/1.12; #6 1.64/0.84; #51 1.63/1.16; #62 1.40/0.89; #82 1.37/1.04; #10
1.37/0.89; #78 1.37/0.98; #63 1.34/0.97; #44 1.28/0.92; #52 1.28/0.91; #64 1.26/0.96;
#84 1.25/1.01; #49 1.24/0.98; #77 1.21/0.98; #66 1.21/0.97; #65 1.18/0.98; #74
1.08/0.86; #17 1.03/0.72; #76 1.03/0.87; #29 1.01/0.64; #58 0.88/0.70; #18 0.87/0.69;
#34 0.83/0.62; #80 0.66/0.28; #79 0.56/0.32; #61 0.42/0.21; #41 0.41/0.16; #68
0.38/0.23; #67 0.32/0.18; #69 0.31/0.17; #75 0.27/0.15; #73 0.26/0.15; #72 0.26/0.14;
#83 0.26/0.13; #71 0.24/0.13; #70 0.23/0.12. Almost all are one `join.sh` plus one
cheap command (the "join: accepts <type>" set #62-#66, #77, #78 is exactly one join
each, which is how J was derived); #67-#75 and #83 are validation failures that never
reach the walk and show the bare per-test cost.

Two calibration points worth keeping in mind: #34 (`reset.sh` that fails validation
right after `agmsg_resolve_project`, reset.sh:47-70) costs 0.60 s macOS / 0.50 s
ubuntu over the no-op baseline, i.e. sourcing plus one walk; #18 (`whoami.sh` on an
unknown project, one walk) costs 0.64 / 0.57 s.

## Proposals

Estimates are per full CI run. Listed in application order; later numbers are
incremental where they overlap.

### T1. Pin `AGMSG_AGENT_PID=""` in `setup()` - test-only, low risk

- Change: test_team.bats:5-7, add `export AGMSG_AGENT_PID=""` after `setup_test_env`,
  as test_delivery.bats:9 and test_reset_role_session.bats:14 do.
- Why: `join.sh` (join.sh:93), `whoami.sh` (whoami.sh:58) and `reset.sh`
  (reset.sh:47) all call `agmsg_resolve_project`, whose first step is
  `agmsg_agent_pid` (resolve-project.sh:489-538). With the variable set but empty it
  returns immediately; unset, it walks the ppid chain to pid 1. Each hop forks
  `ps -o ppid=`, `ps -o comm=`, `ps -ww -o args=`, three `uname -s`, `tr`, two
  `basename`, `awk` (strace of one join: 19 `ps`, 21 `uname`). A CI runner never has a
  `claude` ancestor, so every walk runs to the top (~10 hops) and returns nothing.
- Count: 112 joins that reach the walk + 15 `whoami` + 4 `reset` = 131 walks; 12 of the
  joins run concurrently in #5, so their walks overlap in wall time.
- Estimate: 118 sequential walks x W (0.45 / 0.35 s) + ~3 / ~2 s for #5 =
  **~55 s macOS / ~45 s ubuntu**.
- Measured (scratch run of the unmodified file with `AGMSG_AGENT_PID=` in the
  environment, 5 extra ancestors so the walk depth matches CI): #14 1.59 -> 0.67 s,
  #31 3.67 -> 1.37 s, #59 5.07 -> 3.10 s, #62 1.02 -> 0.52 s (0.46-0.50 s per walk),
  #5 8.69 -> 6.62 s; all pass. For comparison the same tests on CI ubuntu took 1.51,
  3.52, 4.28, 0.89 and 9.13 s, i.e. about 0.9x the local unpinned times.
- Coverage: no test here is about the ancestor walk. On CI the walk always ends with
  "no agent ancestor", which is what the pin returns, so every resolution in this file
  takes the same branch (ancestor registration / git common dir / raw path). The
  auto-detection tests (#23-#30) exercise `agmsg_detect_cli_type`'s own process lookup
  through `mock_no_agent_ps` (test_team.bats:52-77), which the pin does not touch. The
  walk itself stays covered by test_instance_id.bats and test_resolve_project.bats.

### T2. Test #5: 6 concurrent joins instead of 12 - test-only, medium risk

- Change: test_team.bats:150 `local n=12` -> `local n=6`.
- Why: the 12 joins serialize on the team registry lock (`agmsg_lock_acquire`,
  registry-lock.sh:281-416); each of the 11 waiters spins on `mkdir` with `sleep 0.01`,
  a `date` fork and holder checks per attempt, so the test is nearly linear in N and
  CPU-bound on a 3-core macOS runner (1.95x ubuntu).
- Estimate (after T1): half of the serialized part: (14.8 - 0.25 - 0.72) / 2 s macOS,
  (7.1 - 0.13 - 0.42) / 2 s ubuntu = **~7 s macOS / ~3 s ubuntu**.
- Risk: medium. Six joins started together still reach their read-modify-write at
  about the same moment (their pre-lock phases are identical), so a missing lock would
  still lose registrations, but with fewer chances; and the #994 leak the comment at :117-139
  describes (rmdir-then-remove racing a new acquirer under load) is reproduced through
  the number of hand-offs, which halves. The comment records three rounds of tuning on
  this test; treat this as a trade to propose, not a free cut.

### T3. Fewer forks inside `join.sh`'s own path - not test-only, low-medium risk

- Change (production): in a pinned codex join, 108 execs remain; ~40 of them are
  replaceable by builtins: 13 `basename` (type-registry enumeration), 14 `sed
  "s/'/''/g"` quote escapes (join.sh:128-233 and the libraries it sources; watch.sh already documents a bash-3.2-safe
  parameter-expansion form), 13 `tr -d '\r'` on sqlite output, plus the per-subshell
  `uname -s` that `_agmsg_detect_platform` repeats because its cache is set inside
  `$(...)` (compat.sh:13-20; calling it once when compat.sh is sourced fixes that for
  every caller). The `mv`/`mkdir`/`rmdir` of the atomic-write and lock protocol and the
  10 `sqlite3` calls stay.
- Estimate: J0 (join without the walk) 0.72 s macOS / 0.42 s ubuntu, mostly exec cost;
  removing ~37 % of its execs saves ~0.27 / ~0.15 s per join x 112 =
  **~25 s macOS / ~15 s ubuntu** here, and the same per join everywhere else
  (test_watch.bats runs 110 joins).
- Risk: touches hot shared code with bash 3.2 quoting quirks; behaviour-preserving
  refactor, covered by this very file.

### T4. Cache `init-db.sh`'s output per bats file in `setup_test_env` - test-only, low risk

- Change: tests/test_helper.bash:81. Run `init-db.sh` once per file and copy
  `db/messages.db` from `$BATS_FILE_TMPDIR` afterwards (13 execs incl. 3 `sqlite3`
  replaced by one `cp`). A working version is in
  `survey/deepdive/work-wdt/prototype.diff`.
- Estimate: locally 19 ms per test (14 fast tests 3739 -> 3475 ms); macOS assumed
  ~2.5x for an exec-bound step: 87 x 0.05 / 0.02 s = **~4 s macOS / ~2 s ubuntu**.
  Shared helper: the same change saves ~10 / ~4.5 s in test_delivery.bats and applies
  to every file that calls `setup_test_env`.
- Coverage: each test still gets its own database file; init-db.sh itself still runs
  once per file and in its own tests.

### T5. Optional: share the most common arrange (`join myteam alice claude-code /tmp/proj`) - test-only, low-medium risk

- Change: build that team once in `setup_file` (same pattern as test_watch.md P2) and
  copy it in the ~10 tests whose arrange is exactly that line and whose subject is not
  join itself (#8, #10, #14, #19, #23, #26, #27, #28, #30, #49).
- Estimate (after T1): 10 x J0 = **~7 s macOS / ~4 s ubuntu**.
- Lowest priority: this file is where join.sh is the subject, and replacing the real
  call with a copy in ten more places adds indirection for a modest gain.

Not proposed: merging the seven "join: accepts <type>" tests into one loop (saves only
the per-test base, ~1.5 s macOS / ~0.8 s ubuntu, and loses per-type failure reports);
the JSONL tests #40/#48 (~4.5 s macOS each beyond their join) spend their time inside
the JSONL storage driver, which is production code; splitting the file (212 s is a
sixth of one shard slot).

## Risks and notes

- W (one walk) is calibrated, not measured on CI: local runs at a CI-like depth give
  0.46-0.50 s per walk, CI ubuntu runs these tests at ~0.9x local, and macOS is assumed
  at 0.45 s (the CI single-script comparisons put it between 0.45 and 0.7 s). A single
  CI run with T1 would replace the estimate with a measurement.
- T1 changes nothing on CI except skipping work whose result is known; locally, under a
  real Claude Code session, resolution would have found the developer's own agent and
  consulted its SessionStart project marker. None of these tests write such a marker,
  so the outcome is the same there too.
- After landing, refresh `.github/scripts/bats-file-seconds.tsv` so shard-tests.sh
  rebalances (tests/test_ci_sharding.bats asserts the balance ratio).
- The same pin applies to any other file that runs `join.sh`/`whoami.sh`/`watch.sh`
  without needing a real agent ancestor; it is the cheapest cross-suite lever found here.
