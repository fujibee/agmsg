# test_watch.bats: where the CI time goes and how to cut it

Data: CI run 41607512279 (main @ 64723d6), per-test durations from
`per-test-41607512279.tsv` (a test's seconds include its own setup and teardown;
test 1 also absorbs setup_file). Code references are to main @ 551764e.
Local measurements were taken on a 4-core Linux box that was also running the
strace sweep, so absolute local numbers are used only as ratios.

## Summary

- 41 tests, **383.2 s macOS / 245.4 s ubuntu** per full run (mac/ubu 1.56).
- Before any test body runs, every test pays a fixed **2.83 s macOS / 1.56 s ubuntu**
  (test #16, whose body is a single `grep`): `setup_test_env` plus **two `join.sh`
  runs** in `setup()` (test_watch.bats:17-18) plus a `ps -eo` scan in teardown.
- `join.sh` runs 110 times per run (82 in setup, 28 in bodies, 12 of which are
  redundant re-joins of alice/bob that setup already joined). At ~1.17 s macOS /
  ~0.77 s ubuntu each that is **~129 s macOS / ~85 s ubuntu (34-35 % of the file)**.
- About 40 % of every `join.sh`, `watch.sh` start, `_iid` call and `session-start.sh`
  run is a **futile process-tree walk** (`agmsg_agent_pid`, resolve-project.sh:489)
  that climbs ~10 ancestors with three `ps` calls and ~7 other execs per hop looking
  for a `claude` binary that never exists on a CI runner. ~210 walks per run.
  test_delivery.bats already pins it off with `AGMSG_AGENT_PID=""`; this file does not.
- Fixed waits: test #1's `--max-seconds` caps (~39 s of its 51 s), the 7 s window in
  #29, three 2 s windows in #17, `sleep 3` in #20, `sleep 1/2` after barrier release
  in #36/#38/#39/#40: ~59 s nominal per OS.
- Data volume: #22 (100 x 2 KB arrange built with ~2000 forks) and #26 (14-26 x 90 KB
  `send.sh`) cost 37 s macOS / 25 s ubuntu together.
- Test-only proposals P1-P6 (+P8, P11, P12) cut roughly **210 s macOS / 135 s ubuntu**
  (to ~170 s / ~110 s; ubuntu +-15 %, see P2). P1+P2 were prototyped in a scratch copy: five representative
  tests went from 19.8 s to 4.4 s locally at a CI-like process depth, all passing.

## Where the time goes

Aggregate (per full run):

| bucket | macOS s | ubuntu s | basis |
|---|---:|---:|---|
| `join.sh` (110 runs: 82 setup + 28 body, 12 redundant) | ~129 | ~85 | J = 1.17 / 0.77 s per join (test_team #62 "join: accepts claude-code" 1.40/0.89 minus its no-op baseline #70 0.23/0.12) |
| ancestor walks outside join (100: watcher starts, `_iid`, session-start, reset) | ~45 | ~35 | W = 0.45 / 0.35 s per walk (see Risks and notes) |
| fixed waits that must elapse | ~65 | ~65 | 59 s of caps/sleeps/windows listed in the table + ~6 s of stuck-guard cycles in #27/#28, nominal |
| per-test base (setup_test_env, bats, teardown `ps -eo`) | ~12 | ~7 | 41 x the no-op baseline (test_team #70: 0.23/0.12 s) + the teardown `ps -eo` scan (~0.05 s) |
| rest (watcher startup work, sends, sqlite, arrange data, cursor polls) | ~132 | ~53 | remainder |

Per test, sorted by macOS seconds (all 41 tests; the first 19 rows are 70 % of the
macOS time). "joins" is setup+body; "walks (non-join)" counts `agmsg_agent_pid` walks
outside join.sh (a bare-session watcher start = 2: watch.sh:130 resolve + :140
normalize; a composite `<sid>.<pid>` start = 1; `_iid` = 1; session-start.sh ~3;
reset.sh 2). A mac/ubu ratio near 1 means waits; near 2 or above means spawn cost.

| # | title | macOS s | ubuntu s | mac/ubu | cum % mac | joins (setup+body) | walks (non-join) | fixed waits s | driver |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | watch: --max-seconds ends the run with a re-arm line after a delive... | 51.12 | 43.88 | 1.16 | 13.3 | 2+3 | 8 | 36 | --max-seconds caps that must elapse (8+2+2 s, 4 s no-flag window, 4x5 s erin runs; ~39 s with cycle alignment); 3 body joins; 8 watcher starts (4 bare-sid = 8 walks; erin runs pin AGMSG_AGENT_PID=$$); actas-claim; 5 sends |
| 22 | watch: a backlog large enough to exceed the OS argv ceiling still d... | 19.69 | 9.43 | 2.09 | 18.5 | 2+0 | 2 | 0 | bulk_send_direct 100x2000 arrange (~1500 subshell forks + ~500 execs: compat_uuid7/_sqlite_now/_sqlite_lit per message); watcher start (2 walks) delivering 100 rows; cursor poll |
| 29 | watch: an idle pair seeing only a cursor high-water is not treated ... | 18.43 | 9.88 | 1.86 | 23.3 | 2+1 | 2 | 7 | fixed 7 s observation window (70 x 0.1 s, asserting an absence over >STUCK_THRESHOLD cycles); sqlite3 stub on PATH (every sqlite3 call becomes bash+sqlite3); 1 body join (idle); send; watcher start (2 walks) |
| 26 | watch: a backlog past the argv ceiling still delivers (#1045/#777, ... | 17.09 | 16.04 | 1.07 | 27.7 | 2+0 | 2 | 0 | count x send.sh with a 90 KB body (count = ARG_MAX/90000+3: 26 on ubuntu, 14 on macOS, which is why ubuntu is nearly as slow); watcher (2 walks) delivering 1.3-2.3 MB; cursor poll |
| 27 | watch: a cursor stuck N cycles with pending rows reports on stdout ... | 12.75 | 5.54 | 2.30 | 31.1 | 2+0 | 2 | 3 | STUCK_THRESHOLD=3 poll cycles at the 1 s minimum interval + exit wait; sqlite3 stub on PATH; watcher start (2 walks); macOS 2.3x ubuntu = stubbed exec per sqlite call |
| 17 | watch: a second unfiltered watcher says it is sharing, and a lone o... | 12.70 | 9.77 | 1.30 | 34.4 | 2+1 | 5 | 6 | three fixed 2 s absence windows (solo, third, other-project); 5 composite-id watcher starts (5 walks); 1 body join (otherteam) |
| 28 | watch: the stuck guard fires for a pair whose agent name has a spac... | 12.59 | 6.93 | 1.82 | 37.7 | 2+2 | 2 | 3 | as #27 plus 2 body joins (spaced agent in a second project) |
| 3 | watch: a fresh session delivers existing unread; a later watcher do... | 12.33 | 5.50 | 2.24 | 40.9 | 2+0 | 4 | 0 | 2 run_watcher_until (startup + delivery + _read_cursor polling, each poll sources storage.sh in a subshell); 2 sends; 4 walks; macOS 2.2x ubuntu = spawn-heavy cursor polls |
| 37 | watch: a claim landing between consume and the fold is not obeyed (... | 11.69 | 6.29 | 1.86 | 43.9 | 2+2 (1 redundant) | 2 | 0 | redundant alice re-join + leader join; watcher start (2 walks); fold barrier (0.25 s test polling); exit wait; identities.sh |
| 33 | watch: with NO claim in the window a ctrl:despawn is still obeyed (... | 11.64 | 5.93 | 1.96 | 47.0 | 2+2 (1 redundant) | 4 | 0 | redundant alice re-join + leader join; watcher (2 walks); claim barrier; ctrl:despawn obeyed -> reset.sh (2 walks); exit wait; identities.sh |
| 4 | watch: exits when its session dies without consuming an undelivered... | 11.46 | 5.66 | 2.03 | 50.0 | 2+0 | 3 | 0 | stand-in session + watcher (1 walk, composite) killed by the liveness guard within one interval; redelivery run_watcher_until (2 walks); 2 sends |
| 34 | watch: a message for a role claimed inside the window is neither sh... | 11.29 | 6.28 | 1.80 | 52.9 | 2+2 (1 redundant) | 2 | 0 | redundant alice re-join + leader join; watcher (2 walks); claim barrier; next-turn wait (1 s cycle); inbox.sh |
| 32 | watch: a role claimed inside the window keeps its registration (#98... | 10.65 | 6.00 | 1.78 | 55.7 | 2+2 (1 redundant) | 2 | 0 | redundant alice re-join + leader join; watcher (2 walks); claim barrier; exit wait; identities.sh |
| 35 | watch: with NO claim in the window the message IS shown and consume... | 10.26 | 5.76 | 1.78 | 58.4 | 2+2 (1 redundant) | 2 | 0 | redundant alice re-join + leader join; watcher (2 walks); delivery wait + next-turn wait (1 s cycle); inbox.sh |
| 21 | watch: delivers a burst of 8 consecutive messages without loss (#245) | 10.17 | 4.93 | 2.06 | 61.0 | 2+0 | 3 | 0 | 8 x send.sh (~0.6 s macOS / ~0.2 s ubuntu each); watcher (2 walks) + _iid (1 walk); delivery wait |
| 36 | watch: a claim landing DURING delivery still leaves the batch unrea... | 10.13 | 6.10 | 1.66 | 63.7 | 2+2 (1 redundant) | 2 | 1 | redundant alice re-join + leader join; watcher (2 walks); consume barrier; fixed sleep 1 after release; inbox.sh |
| 38 | watch: a lock that cannot be READ stops the act, it does not read a... | 9.97 | 6.88 | 1.45 | 66.3 | 2+2 (1 redundant) | 2 | 2 | redundant alice re-join + leader join; watcher (2 walks); consume barrier; fixed sleep 2 after release (chmod 000 lock); inbox.sh |
| 40 | watch: a BROAD watcher refuses too when the lock stops being readab... | 9.90 | 6.89 | 1.44 | 68.9 | 2+2 (1 redundant) | 2 | 2 | redundant alice re-join + leader join; broad watcher (2 walks); consume barrier; fixed sleep 2 after release (chmod 000 run/); inbox.sh |
| 5 | watch: closed stdout exits without advancing the read cursor | 8.98 | 6.29 | 1.43 | 71.2 | 2+0 | 5 | 0 | _iid (1 walk) + watcher with closed stdout (2 walks) + redelivery run (2 walks); send; cursor reads |
| 39 | watch: an unreadable lock also stops the ctrl:despawn teardown (#983) | 7.71 | 6.87 | 1.12 | 73.2 | 2+2 (1 redundant) | 2 | 2 | redundant alice re-join + leader join; watcher (2 walks); fold barrier; fixed sleep 2 after release (chmod 000 lock); identities.sh |
| 2 | watch: restart delivers messages that arrived while the watcher was... | 7.28 | 4.98 | 1.46 | 75.1 | 2+0 | 4 | 0 | 2 watcher starts (4 walks); 2 sends; delivery waits (<=1 s poll); _read_cursor polling |
| 31 | watch: the watcher names this session's pane (#1044) | 7.04 | 3.88 | 1.81 | 76.9 | 2+0 | 3 | 0 | _iid (1 walk) + watcher (2 walks, bare on CI) with fake tmux; wait for the rename call |
| 11 | session-start: skips directive when watcher already alive (compact ... | 6.44 | 4.57 | 1.41 | 78.6 | 2+1 (1 redundant) | 6 | 0 | redundant alice re-join; watcher (2 walks) + _iid (1) + session-start.sh (~3 walks) |
| 20 | watch: surfaces an unopenable DB once instead of spinning silently ... | 6.41 | 4.78 | 1.34 | 80.3 | 2+0 | 2 | 3 | send; watcher (2 walks); fixed sleep 3 (startup + >1 poll, see #1023 comment) |
| 30 | watch: a failed pending-scan is surfaced and exits, not collapsed t... | 6.06 | 3.09 | 1.96 | 81.9 | 2+0 | 2 | 0 | sqlite3 stub; watcher (2 walks) exits on the first failed scan; exit wait |
| 15 | watch: the successor claims the pidfile before it signals, and keep... | 5.78 | 2.88 | 2.01 | 83.4 | 2+0 | 2 | 0 | 3 perl -pi instrumentations of watch.sh; 2 composite-id watchers (2 walks); predecessor exit wait |
| 9 | watch: ready sentinel records the owner session_id | 5.74 | 4.10 | 1.40 | 84.9 | 2+0 | 3 | 0 | watcher (2 walks) + _iid (1); ready-sentinel poll at 0.5 s granularity |
| 6 | session-end: leaves the store-owned read cursor intact | 5.67 | 3.02 | 1.88 | 86.4 | 2+0 | 1 | 0 | send + inbox.sh + session-end.sh (1 walk) + 2 _read_cursor subshells |
| 8 | watch: a broad (non-actas) watcher does not create a ready sentinel | 5.31 | 3.59 | 1.48 | 87.8 | 2+1 (1 redundant) | 2 | 0 | redundant bob re-join; broad watcher (2 walks); send; delivery wait |
| 12 | session-start: GCs a stale ready sentinel but keeps a live one | 4.78 | 3.40 | 1.40 | 89.0 | 2+1 (1 redundant) | 3 | 0 | redundant alice re-join; session-start.sh (~3 walks) |
| 7 | watch: actas-mode watcher creates a ready sentinel and removes it o... | 4.55 | 3.19 | 1.42 | 90.2 | 2+0 | 2 | 0 | watcher (2 walks); ready-sentinel poll at 0.5 s granularity |
| 10 | watch: cleanup leaves a sentinel that a successor session re-owned | 4.46 | 3.30 | 1.35 | 91.4 | 2+0 | 2 | 0 | watcher (2 walks); ready-sentinel poll at 0.5 s granularity |
| 14 | watch: relaunch with the SAME instance id replaces the previous wat... | 4.38 | 2.89 | 1.52 | 92.5 | 2+0 | 2 | 0 | 2 sequential composite-id watchers (2 walks); pidfile handover wait |
| 23 | watch: empty session_id gets a generated fallback instead of a Usag... | 4.11 | 2.67 | 1.54 | 93.6 | 2+0 | 2 | 0 | watcher with generated id (2 walks); pidfile poll every 0.2 s |
| 24 | watch: sentinel '-' session_id resolves like an empty one (#477) | 4.04 | 2.63 | 1.54 | 94.6 | 2+0 | 2 | 0 | as #23 with '-' session id |
| 13 | watch: two sessions sharing a session_id keep independent watchers ... | 3.98 | 2.38 | 1.67 | 95.7 | 2+0 | 2 | 0 | 2 concurrent composite-id watchers (2 walks) + 2 stand-in sleeps; pidfile waits |
| 19 | watch: a watcher does not delete filter metadata it did not write | 3.76 | 2.26 | 1.66 | 96.6 | 2+0 | 1 | 0 | 1 composite-id watcher (1 walk); filter-file checks |
| 25 | watch close_own_placement: a corrupt pane ref logs 'did not resolve... | 3.43 | 1.66 | 2.06 | 97.5 | 2+0 | 0 | 0 | awk extraction + one bash -c over sourced libs; no watcher (fixed cost dominates) |
| 41 | watch: the re-verify makes exactly ONE lock read, and derives nothi... | 3.38 | 1.54 | 2.19 | 98.4 | 2+0 | 0 | 0 | awk/grep over watch.sh and scripts/ (fixed cost only) |
| 18 | watch: a filtered watcher is never mistaken for unfiltered while st... | 3.24 | 2.13 | 1.52 | 99.3 | 2+0 | 1 | 0 | 1 composite-id watcher (1 walk); filter-file checks |
| 16 | watch: the slot is claimed before the previous holder is signalled ... | 2.83 | 1.56 | 1.82 | 100.0 | 2+0 | 0 | 0 | grep over watch.sh only: this IS the fixed per-test cost F (setup_test_env + 2 joins + teardown ps scan) |
| | **total** | **383.2** | **245.4** | 1.56 | | | | | |

How test #1 spends its 51 s: the watcher decides to stop at the top of the first poll
cycle where `SECONDS + AGMSG_WATCH_ELAPSED_BASE >= --max-seconds` (watch.sh:1311-1313,
`SECONDS` counts from the watcher's own start, startup included). With
`AGMSG_WATCH_INTERVAL=1` each run lasts cap + 0..1 s: s-ms1 at 8 s (line 371), s-ms2
and s-ms3 at 2 s (383, 392), the no-flag run s-ms4 is observed for 4 s (`_wait_exit
"$pid" 40`, line 403), and the four erin runs (443, 461, 483, 501) at 5 s each. That
is 36 s nominal, ~39 s with cycle alignment, and it costs the same on both OSes.

## Proposals

Estimates are per full CI run (each test once per OS). Proposals are listed in the
order they would be applied; where two overlap, the later one's number is incremental.

### P1. Pin `AGMSG_AGENT_PID=""` in `setup()` - test-only, low risk

- Change: test_watch.bats:9-19, add `export AGMSG_AGENT_PID=""` (today it is set only
  on MSYS, line 14). Same line test_delivery.bats:9 and test_reset_role_session.bats:14
  already carry.
- Why it costs: `agmsg_agent_pid` (resolve-project.sh:489) honours the override first
  (an empty value returns "no agent ancestor" immediately) and otherwise walks the
  ppid chain to pid 1 (max 20 hops). Each hop runs `compat_get_ppid` and
  `agmsg_pid_is_agent` (resolve-project.sh:439): `ps -o ppid=`, `ps -o comm=`,
  `ps -ww -o args=`, three `uname -s` (`_agmsg_detect_platform` caches into a variable
  inside `$(...)` subshells, compat.sh:13-20, so every subshell re-detects), `tr`, two
  `basename`, `awk`. Callers in this file: every `join.sh` (resolve at join.sh:93),
  every `watch.sh` start (watch.sh:130 and, for a bare session id, :140), every `_iid`
  (test_watch.bats:247), `session-start.sh` (:167, :251), `reset.sh` (:47, :58),
  `session-end.sh`. On a CI runner the chain is bats-exec-test, bats-exec-file,
  bats-exec-suite, bats, run-bats-timed.sh, the step shell, Runner.Worker,
  Runner.Listener, ..., pid 1: about 10 hops, and it never contains `claude`.
- Count: 210 walks per run (82 setup joins + 28 body joins + 100 in the table's
  "walks" column).
- Estimate: **~95 s macOS / ~70 s ubuntu** standalone (210 x W, W = 0.45 / 0.35 s).
  Basis for W: local emulation with 10 extra ancestors and no agent: `join.sh` 0.66 s
  walk vs 0.31 s pinned, `whoami.sh` 0.49 vs 0.20, `reset.sh` fast-fail 0.47 vs 0.10;
  bats single-test runs at the same depth: test_team #14/#31/#59/#62 saved 0.46-0.50 s
  per walk. CI: test_team #34 (reset.sh fast-fail = sourcing + one walk) costs only
  0.60 s macOS / 0.50 s ubuntu in total, and in test_delivery (pinned) a second codex
  join adds 0.52 / 0.33 s versus 1.17 / 0.77 s for an unpinned join.
- Coverage: none lost on CI. On a runner the walk always ends with "no agent", which
  is exactly what the pin returns, and `_iid` (the test-side derivation) and watch.sh
  stay in agreement because both read the same variable. The composite-id cases
  (#4, #13, #14, #15, #17, #18, #19) pass explicit `<sid>.<pid>` tokens, which
  `agmsg_normalize_instance_id` passes through without walking (instance-id.sh:385-391),
  and test #1's erin runs already pin `AGMSG_AGENT_PID=$$` per command. What changes:
  a developer who runs the file inside a real Claude Code session gets bare ids instead
  of composite ones (test_delivery.bats:7-9 calls this file the "composite path"; on CI
  that path is only ever reached through the explicit tokens above), and the walk's
  "nothing found" branch is no longer run incidentally here. The walk itself is unit
  tested in test_instance_id.bats:436-480 and test_resolve_project.bats.

### P2. Build the joined team once per file; drop the 12 redundant re-joins - test-only, low risk

- Change: replace the two joins in `setup()` (test_watch.bats:17-18) with a copy of a
  team directory produced once in `setup_file` by the real `join.sh` (alice, bob; plus
  a second snapshot after also joining leader). Remove the re-joins that repeat what
  setup already did: bob at :677 (#8), alice at :749 (#11), :784 (#12), and alice at
  :1659, :1694, :1728, :1764, :1803, :1843, :1883, :1917, :1956 (#32-#40). Replace the
  leader joins at the following lines (#32-#40) with the leader snapshot.
  A working version is in `survey/deepdive/work-wdt/prototype.diff` (about 25 lines:
  `setup_file`, `_use_team_fixture base|leader`, and the deletions).
- Why it is safe: after `setup_test_env` + the two joins, the only new files are
  `teams/team/config.json` and `teams/team/roster.jsonl`; `db/messages.db` is
  byte-identical (`.dump` compared before/after) and no file contains
  `$TEST_SKILL_DIR` or `$AGMSG_TEST_TMPDIR`, so a copy is the real join output.
  Member join time (`at`) is not used for delivery (only roster-journal.sh projects
  it). Each test still gets its own copy, so isolation is unchanged; join.sh keeps
  running in setup_file and in #1, #17, #28, #29, and is the subject of test_team.bats.
  A re-join of an already registered (agent, type, project) takes join.sh's
  "existing registration" branch and rewrites identical content (no roster event).
- Estimate: 100 joins avoided (82 setup + 12 redundant + 9 leader - 3 run once in
  setup_file). After P1: 100 x J0 = **~70 s macOS / ~40 s ubuntu** (J0 = join without
  the walk = J - W = 0.72 / 0.42 s). Standalone (without P1): 100 x J = ~117 s / ~77 s.
- Prototype (P1+P2, scratch copy, 5 extra ancestors so the walk depth matches CI):
  #8 4.11 -> 1.10 s, #11 4.79 -> 0.79 s, #16 1.69 -> 0.22 s, #18 2.60 -> 0.49 s,
  #33 6.61 -> 1.81 s; all pass. Local ubuntu-equivalent saving was 86 % of what the
  model above predicts for these five, so read the ubuntu numbers as +-15 %.

### P3. Test #1: run the four independent renewal cases concurrently - test-only, low risk

- Change: test_watch.bats:367-406. Cases s-ms1 (alice, 8 s cap), s-ms2 (carol, 2 s),
  s-ms3 (dave, 2 s, KEEP_ALIVE) and s-ms4 (bob, no flag) use different roles, session
  ids and could use different output files; nothing they read is written by the others
  (the only shared step, sending "renewal probe" bob->alice, happens before launch).
  Start all four, `_wait_exit` s-ms2/s-ms3/s-ms1, then check that s-ms4 is still
  running and has printed no `agmsg watch:` line.
- Estimate: sequential 8.5 + 2.5 + 2.5 + 4.1 s becomes ~8.6 s: **~9 s per OS**.
- Coverage: unchanged, and the no-flag assertion gets stronger (observed for ~8.5 s
  instead of 4 s). Four watcher startups now overlap on a 3-core macOS runner; that
  only affects s-ms1, which must deliver before its 8 s cap, and its cap is kept.
  Lowering s-ms1's cap to 5 s (the value the erin runs use, chosen in their comment for
  slow macOS startup) would save another ~3 s but stacks that startup risk with the
  concurrency, so it is not counted here.

### P4. Wait for the refusal line instead of `sleep 1`/`sleep 2` after barrier release - test-only, low risk

- Change: #36 `sleep 1` (:1820), #38 `sleep 2` (:1902), #39 `sleep 2` (:1935), #40
  `sleep 2` (:1981). After `: > "$cb.release"` the watcher re-verifies and calls
  `_report_pair_refusal` (watch.sh:381-386), which writes to stdout within
  ~0.05-0.2 s: "changed hands ... marking them read" (#36) or "could not verify who
  holds this role" (#38-#40). Replace each sleep with
  `wait_for_file_contains "$out" '<that text>'`, then restore the chmod and kill as now.
- Estimate: 0.8 + 3 x 1.8 s = **~6 s per OS**.
- Coverage: #36, #39 and #40 already assert that line after the sleep, so the wait
  waits for what they assert; #38 asserts only the unread row, and the wait adds the
  refusal line as positive evidence that the guard path ran (stronger). The bounded
  helper fails after 10 s if the line never comes.

### P5. Test #26: build the >ARG_MAX backlog with `bulk_send_direct` - test-only, low risk

- Change: test_watch.bats:1425-1427, replace the `count` x `send.sh` loop with
  `bulk_send_direct team bob alice "$count" "$body" WMSG` and adjust the two greps and
  the `run_watcher_until` needle to its `WMSG-<i>-` labels (first `WMSG-0-`, last
  `WMSG-$((count-1))-`).
- Why: each `send.sh` with a 90 KB argv costs ~0.25-0.3 s ubuntu / ~0.6 s macOS, and
  `count = ARG_MAX/90000 + 3` is 26 on ubuntu (ARG_MAX 2097152) but 14 on macOS
  (1048576), which is why this test is as slow on ubuntu as on macOS (ratio 1.07).
  #22 already uses `bulk_send_direct` for the same purpose; the helper feeds SQL on
  stdin, never through argv.
- Estimate: **~7.5 s macOS / ~6 s ubuntu** (14 x 0.6 and 26 x 0.25 s of sends replaced
  by one helper call of ~0.3-0.6 s). Making the helper itself fork-free (one `od` for
  all random bytes, one `date`, inline quoting instead of six `$(_sqlite_lit)` per row,
  test_helper.bash:769) would also speed up test_inbox.bats:530 and
  test_watch_once.bats:129, which build the same 100-row backlog.
- Coverage: the subject is the watcher draining a backlog bigger than ARG_MAX through
  stdin; how the rows were written is arrange. Still "many normal messages sized from
  the measured ARG_MAX", as the test's comment requires.

### P6. Test #22: skip it on macOS (or drop it) - test-only, low risk

- Change: test_watch.bats:1302-1332. The #777 regression embedded the whole page in
  one argv element. 100 x 2000 bytes (200 KB) exceeds Linux's per-argument limit
  (MAX_ARG_STRLEN, 131072) but not macOS's: macOS enforces only the total argv+env size
  (ARG_MAX 1048576) and has no per-argument limit, so a 200 KB single argument fits and
  on macOS this test cannot fail for the bug it pins (the comment at :1286-1300 calls
  the macOS ceiling "smaller still"; that is true of the total, not of one argument). #26 sizes its backlog from `getconf ARG_MAX` and discriminates on both
  OSes, and its `run_watcher_until` also requires the cursor to advance.
- Estimate: skip on Darwin: **~17 s macOS / 0 ubuntu** (19.7 s minus the residual
  per-test cost). Dropping it everywhere adds ~8 s ubuntu; its remaining distinct
  shape (100 rows in one page) exercises no separate code path (`storage_watch_after`
  has no LIMIT, sqlite.sh:529-552), so that is also defensible, but it is the larger
  change to argue.
- Coverage: none on macOS (the test cannot fail there for #777); low if dropped.

### P7. Test #1, erin runs: two concurrent batches instead of four sequential runs - test-only, medium risk

- Change: test_watch.bats:415-507. Case 6 (desired=off) needs the global intent off;
  cases 5, 7, 8 need it on. Give cases 7 and 8 their own roles (join + actas-claim
  each, then corrupt that role's own role-session record) and run 5, 7, 8 together,
  then 6 alone.
- Estimate: removes two 5.5 s runs, adds two joins and two actas-claims:
  **~8 s macOS / ~9 s ubuntu** (after P1).
- Risk: medium. Three watcher startups share a loaded macOS runner while each must
  deliver before a 5 s cap, which is exactly the failure the comment at :435-441
  records. Not needed if P9 lands.

### P8. Test #21: write the 8-message burst with one `bulk_send_direct` - test-only, medium risk

- Change: test_watch.bats:1274-1276. Estimate: 8 x `send.sh` (~0.6 s macOS / ~0.2 s
  ubuntu) becomes one helper call: **~4.5 s macOS / ~1.5 s ubuntu**.
- Risk: medium. The burst then lands in one transaction and is drained in one poll,
  whereas eight processes ~0.2-0.6 s apart may span polls. The #245 property (no line
  lost after the 5th) does not depend on polls, but the test would no longer be
  "consecutive sends while the watcher runs".

### P9. watch.sh: honour `--max-seconds` only after one completed poll - not test-only, low risk

- Change: watch.sh:1311-1313, return early from `_watch_renew_or_stop` until the loop
  has finished one cycle (a counter bumped after the sleep at :1839). Then test #1's
  delivering runs can use `--max-seconds=1` (s-ms1 and the four erin runs) and the
  startup-time headroom that forced 5 s and 8 s disappears.
- Estimate (after P3): erin runs 4 x (5.5 - 2.5) s + s-ms1 group 8.6 -> ~4.1 s:
  **~16 s per OS**.
- Risk: low. In production the cap is 1750 s (test_delivery #40 and #46 assert
  `--max-seconds=1750`), so one guaranteed poll before honouring it changes nothing a
  user can observe; it removes the startup race the test comment describes.

### P10. watch.sh: accept a fractional `AGMSG_WATCH_INTERVAL` - not test-only, low-medium risk

- Change: watch.sh:495 rejects anything but digits (`*[!0-9]*` -> 5), so tests cannot
  go below the 1 s interval. `INTERVAL` is used only in `sleep "$INTERVAL"` (:1839),
  and both GNU and BSD `sleep` take fractions. Accept `N.N` from the env var (the
  config key can stay integer), then use 0.2-0.5 s in this file.
- Estimate: **~15 s per OS**: #27/#28 reach STUCK_THRESHOLD=3 cycles ~2.4 s sooner
  each; #29 with P11 shrinks from ~7 s to ~1.5 s; cap overshoot in #1 drops ~0.4 s per
  run x 7; ~14 delivery waits in #2-#5, #8, #21, #34, #35 drop ~0.4 s each.
- Risk: faster polling multiplies the watcher's per-cycle spawns (several sqlite3
  calls per pair) on a 3-core macOS runner; 0.5 s is the safer value.

### P11. Test #29: bound the "not stuck" window by observed poll cycles - test-only, low risk

- Change: test_watch.bats:1536-1540. The test already installs a `sqlite3` stub; let it
  append a line per call whose SQL contains `message_sent` (the per-cycle pending
  scan), and end the window once STUCK_THRESHOLD+2 scans have been seen (bounded).
- Estimate: ~7 s window becomes startup + ~5 cycles: **~1.5 s per OS** (more with P10).
- Coverage: stronger. Today 70 x 0.1 s is a wall-clock claim; on a slow macOS
  startup it can cover as few as ~4 cycles, barely above the threshold.

### P12. Test #17: replace the 2 s absence windows with progress evidence - test-only, low risk

- Change: test_watch.bats:1104, :1133, :1147. The sharing check runs right after the
  pidfile write and before the main loop (watch.sh:594-633) and is skipped entirely for
  a named watcher. Wait for the third watcher's ready sentinel, and for a probe message
  sent before launch to be delivered by the solo and other-project watchers, then
  assert the log has no warning (the pattern #8 already uses, "streamed delivery is the
  evidence", :677-697).
- Estimate: **~2 s per OS** (three 2 s windows minus startup and two extra sends).
- Note: the test's own comment prefers seconds ("waiting longer only makes the negative
  stronger"); the estimate is lowered accordingly and this is the lowest priority here.

Not proposed: #20's `sleep 3` (the comment documents that 2 s lost the race after
#1023; an event-plus-interval wait would cost about the same), the unconditional
`ps -eo` reap in teardown (test_watch.bats:125-161, deliberately redundant per its
comment; ~0.05 s per test), and splitting the file (384 s is about a third of one
6-shard slot; the long pole is #1 at 51 s, which P3/P9 address).

## Risks and notes

- W (cost of one walk) is the least certain constant. The sum P1+P2 is fairly robust
  (it is the full cost of the avoided joins plus the remaining walks: ~150-190 s macOS)
  but its split between P1 and P2 moves with W: W = 0.3 s gives ~63 + ~87 s macOS,
  W = 0.65 s gives ~136 + ~52 s. A single CI run with P1 alone would settle it.
- The setup_file template is a new pattern for this suite (no file uses `setup_file`
  today). It relies on `BATS_FILE_TMPDIR` (bats >= 1.4; CI uses 1.13.0, files run one
  at a time via run-bats-timed.sh, so setup_file runs once per file). The template must
  be built inside a subshell so `setup_test_env`'s exports (HOME, TMPDIR, SCRIPTS) do
  not leak into tests; the prototype does that.
- The pin is the change most likely to draw a reviewer question, because
  test_delivery.bats:7-9 names this file as the composite-path one. The answer is that
  on CI the composite path is only reached through explicit `<sid>.<pid>` tokens, which
  the pin does not affect; if that local coverage matters, keep one test that unsets
  `AGMSG_AGENT_PID` and runs a watcher with a fake agent ancestor.
- Production follow-up that helps every suite and every user (not counted above):
  call `_agmsg_detect_platform` once at compat.sh source time so `$(compat_get_*)`
  subshells inherit the value; that removes ~21 `uname -s` per `join.sh` and 3 per walk
  hop.
- After landing any of this, refresh `.github/scripts/bats-file-seconds.tsv`:
  shard-tests.sh weights files by measured macOS seconds, and a file that drops from
  384 s to ~170 s would otherwise unbalance its shard (tests/test_ci_sharding.bats
  checks the balance ratio).
- Local measurements were taken while the strace sweep was running (load 1.7-6); only
  ratios and the before/after pairs above were used.
