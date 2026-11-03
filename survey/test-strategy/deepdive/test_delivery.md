# test_delivery.bats: where the CI time goes and how to cut it

Data: CI run 41607512279 (main @ 64723d6), per-test durations from
`per-test-41607512279.tsv` (a test's seconds include its own setup and teardown;
test 1 also absorbs the file's start-up). Code references are to main @ 551764e.
Local numbers come from a loaded 4-core Linux box and are used only as before/after
ratios; every local before/after quoted here ran the unmodified test and a patched
scratch copy back to back.

## Summary

- 227 tests, **303.9 s macOS / 149.6 s ubuntu** per full run (mac/ubu 2.03, the
  highest of the three files). The distribution is flat: 70 % of the macOS time is
  spread over 110 tests, only #44 and #107 exceed 5 s, and the median test costs
  0.92 s macOS / 0.44 s ubuntu.
- The file already does what the other two do not: `setup()` pins
  `AGMSG_AGENT_PID=""` (test_delivery.bats:9) and most session-start joins pass
  `AGMSG_RESOLVE_PROJECT=0`, so the ancestor-walk cost that dominates test_watch and
  test_team is absent here.
- The fixed per-test cost (bats + `setup_test_env` + `mktemp -d` + teardown) is
  ~0.30 s macOS / ~0.19 s ubuntu (the fast-fail validation tests #28, #31, #34, #35),
  i.e. **~68 s macOS / ~43 s ubuntu (22 % / 29 %)** for 227 tests.
- `delivery.sh set/status` on the hooks-JSON types (groups G1 + G2, 92 tests) is
  **147 s macOS (48 %) / 62 s ubuntu** with a 2.2-2.7 macOS/ubuntu ratio; one call
  costs ~0.5-1.1 s on macOS against ~0.2-0.3 s on ubuntu (single-call tests #12, #14,
  #40-#42, #48, #69, #78, #167). The cause is inside delivery.sh on macOS, not in the
  tests.
- Fixed waits are few and mostly removable: #44 waits out a 5 s autostart budget,
  #103/#107 hold flat 3-4 s absence windows, #183 sleeps 1 s for distinct mtimes, #102
  waits a 1 s stdin timeout, #205 waits a 1.5 s probe timeout.
- Test-only proposals D1-D5 save **~18 s macOS / ~12 s ubuntu**; three of them were
  prototyped and pass (#44 6.52 -> 2.50 s, #102 1.98 -> 1.21 s, #183 1.97 -> 1.09 s
  locally). The larger lever (D7, ~25-30 s macOS) is a macOS profile of delivery.sh.

## Where the time goes

All 227 tests by group (every test is in exactly one group):

| group | tests | n | macOS s | ubuntu s | mac/ubu | median macOS s/test | % of file macOS |
|---|---|---:|---:|---:|---:|---:|---:|
| G1 codex delivery with a join (join codex + delivery.sh set monitor/turn codex + status/off) | 113, 169-181, 185, 204-207 | 19 | 61.4 | 22.5 | 2.73 | 3.44 | 20.2 |
| G2 delivery.sh set/status on hooks-JSON types (claude-code, codex) without a join | 1-23, 25, 39-42, 48-56, 69-73, 78-79, 108-112, 114-134, 167-168, 184 | 73 | 85.8 | 39.8 | 2.15 | 1.06 | 28.2 |
| G3 session-start/session-end (claude-code): join (AGMSG_RESOLVE_PROJECT=0) + session-start.sh, watcher sweeps | 43, 45-47, 58-68, 74-77, 80-86, 105-106 | 28 | 35.6 | 18.9 | 1.88 | 1.41 | 11.7 |
| G4 session-start.sh for codex (join codex + seat/rollout fixtures + session-start) | 87, 159-166, 182-183 | 11 | 21.0 | 10.8 | 1.94 | 1.92 | 6.9 |
| G5 check-inbox (joins + config + send + check-inbox runs) | 100-102, 216-222 | 10 | 29.5 | 15.6 | 1.89 | 2.84 | 9.7 |
| G6 watch.sh in this file (watcher starts, flat absence windows, log-cap waits) | 57, 103-104, 107, 208-215 | 12 | 26.4 | 16.2 | 1.63 | 1.63 | 8.7 |
| G7 rule-file / manual types (gemini, copilot, opencode, cursor, antigravity, grok-build, hermes, devin) | 88-99, 135-158, 186-203, 223-227 | 59 | 31.3 | 16.5 | 1.89 | 0.47 | 10.3 |
| G8 delivery set project_path validation (fast-fail) | 26-38 | 13 | 5.1 | 3.1 | 1.67 | 0.36 | 1.7 |
| G9 #44 sync autostart (waits the 5 s autostart budget) and #24 daemon boot id | 24, 44 | 2 | 7.8 | 6.1 | 1.27 | 7.46 | 2.6 |
| **total** | | 227 | **303.9** | **149.6** | 2.03 | | 100 |

Per test: every test above 2.0 s macOS (all tests above 5 s included), sorted by
macOS seconds, then the rest of the 70 % set by number and group.

| # | title | macOS s | ubuntu s | mac/ubu | cum % mac | fixed waits s | driver |
|---|---|---:|---:|---:|---:|---:|---|
| 44 | session-start: a connected team with no engine is started, and said... | 7.46 | 5.81 | 1.28 | 2.5 | 5 | G9: 3 session-start runs; the third (spaced install, real remote.sh) waits out the 5 s AGMSG_SYNC_AUTOSTART_TIMEOUT_S budget with a start still in flight (measured locally: 8.13 s default vs 3.99 s with the budget at 1 s); then sync start via fake node; the in-flight child keeps spinning up to 16 s after the test |
| 107 | watch.sh subscription is static — newly joined identities don't app... | 5.61 | 4.75 | 1.18 | 4.3 | 4 | G6: flat sleep 1 (subscription snapshot) + flat sleep 3 (absence window); join + 2 sends; watcher start |
| 205 | delivery status (codex): a port that accepts but never answers does... | 4.72 | 2.98 | 1.58 | 5.9 | 1.5 | G1: 2 joins + set monitor codex + node listener + status probe that waits AGMSG_CODEX_STATUS_PROBE_TIMEOUT_MS (1500 ms default) against a silent port |
| 103 | watch.sh restricts subscription to active_name when 4th arg is given | 4.69 | 3.81 | 1.23 | 7.4 | 3 | G6: flat sleep 3 absence window; 2 sends; watcher start (ready-sentinel wait) |
| 219 | check-inbox: a message whose payload could not be written stays unr... | 4.61 | 1.98 | 2.33 | 8.9 | 0 | G5: 2 codex joins + config + send + 2 check-inbox runs (barrier) + inbox |
| 176 | delivery status (codex): notes when the installed shim loses to a d... | 4.24 | 1.00 | 4.24 | 10.3 | 0 | G1: join codex + set monitor codex + shim fixture + status codex (PATH-mismatch probe) |
| 170 | delivery status (codex): stale bridge pidfile is reported as stale | 4.23 | 1.07 | 3.95 | 11.7 | 0 | G1: join codex + set monitor codex + stale pidfile fixture + status codex |
| 180 | delivery status (codex): multiple identities are enumerated indepen... | 4.10 | 1.33 | 3.09 | 13.0 | 0 | G1: same arrange as #175 with 2 codex joins + status enumerating both identities |
| 179 | delivery status (codex): no PATH-mismatch note when a bridge is ali... | 3.92 | 1.00 | 3.91 | 14.3 | 0 | G1: same arrange as #175 + live stand-in bridge (sleep 60) + shim fixture |
| 178 | delivery status (codex): no PATH-mismatch note when no PATH-based s... | 3.66 | 0.98 | 3.71 | 15.5 | 0 | G1: same arrange as #175 (no PATH shim installed) |
| 175 | delivery status (codex): identity with no bridge and no seat says s... | 3.58 | 1.00 | 3.58 | 16.7 | 0 | G1: join codex + set monitor codex + status codex reporting no bridge and no seat (one sha1 + node lookup) |
| 222 | check-inbox: no session id names nothing; the same call with one do... | 3.57 | 1.89 | 1.90 | 17.9 | 0 | G5: fake herdr + join + config + 2 check-inbox runs |
| 177 | delivery status (codex): no PATH-mismatch note when the shim correc... | 3.50 | 1.00 | 3.50 | 19.0 | 0 | G1: same arrange as #175 + shim fixture wins PATH |
| 206 | delivery status (codex): the loaded-thread probe runs once, not onc... | 3.47 | 1.64 | 2.12 | 20.2 | 0 | G1: 3 codex joins + set monitor codex + seat records + status (probe once) |
| 207 | delivery status (codex): a thread already seated elsewhere is not c... | 3.44 | 1.51 | 2.28 | 21.3 | 0 | G1: 2 codex joins + seat records + status |
| 183 | session-start.sh for codex resolves the rollout by real mtime, not ... | 3.39 | 1.88 | 1.80 | 22.4 | 1 | G4: join codex + rollout fixtures + flat sleep 1 for distinct mtimes + session-start codex + 0.1 s log poll |
| 13 | delivery set: does not strip a project's OWN hook merely because it... | 3.36 | 1.15 | 2.93 | 23.5 | 0 | G2: 4 delivery.sh set runs on hand-written settings + 6 sqlite_mem probes |
| 172 | delivery status (codex): metadata project spelling variant is not a... | 3.36 | 0.98 | 3.42 | 24.6 | 0 | G1: same arrange as #175 (metadata spelling variant) |
| 185 | delivery set off (codex): stops the bridge, cleans run files, notes... | 3.34 | 1.73 | 1.93 | 25.7 | 0 | G1: 2 codex joins + stand-in bridge + 2 set off codex + set monitor codex + sha1 |
| 218 | check-inbox: a message whose payload was written is consumed (#677) | 3.18 | 1.67 | 1.91 | 26.8 | 0 | G5: 2 codex joins + config + send + check-inbox + inbox |
| 220 | check-inbox (PostToolUse): shows a message without consuming it (#1... | 3.16 | 1.63 | 1.94 | 27.8 | 0 | G5: 2 codex joins + config + send + check-inbox (PostToolUse) + inbox |
| 113 | codex Windows hook: what the login profile prints does not reach th... | 3.06 | 1.49 | 2.05 | 28.8 | 0 | G1: join codex + send + set turn codex + bash -lc login-shell run of the commandWindows payload |
| 174 | delivery status (codex): missing bridge metadata is reported as stale | 3.05 | 0.95 | 3.21 | 29.8 | 0 | G1: same arrange as #175 (missing metadata) |
| 216 | check-inbox: a live watcher no longer stops the turn side (#694) | 2.84 | 1.48 | 1.91 | 30.8 | 0 | G5: 2 joins + stand-in watcher + config + send + check-inbox + inbox |
| 101 | check-inbox (copilot): emits decision=block JSON when new messages ... | 2.72 | 1.45 | 1.87 | 31.7 | 0 | G5: join + set turn copilot + send + check-inbox (copilot) |
| 169 | delivery status (codex): live bridge reports alive and suppresses w... | 2.71 | 0.98 | 2.76 | 32.6 | 0 | G1: same arrange as #175 + live stand-in bridge |
| 217 | check-inbox: what the watcher already took is not offered twice (#694) | 2.68 | 1.53 | 1.75 | 33.4 | 0 | G5: 2 joins + config + send + check-inbox runs + inbox |
| 212 | watch: an unmeasurable record rotates rather than guessing (#691) | 2.64 | 1.19 | 2.22 | 34.3 | 0 | G6: join (UTF-8 team) + 2 watcher runs polled until a log line appears (0.1 s) + wc shim |
| 23 | delivery status: a Codex project with no hooks file reads as agmsgd... | 2.62 | 1.91 | 1.37 | 35.2 | 0 | G2: codex project without hooks + install.db/agmsgd state fixture + status |
| 211 | watch: the cap is bytes, not characters (#691) | 2.61 | 1.19 | 2.20 | 36.0 | 0 | G6: join (UTF-8 team) + 2 watcher runs polled until a log line appears |
| 102 | check-inbox: does not hang when stdin is a non-TTY pipe that never ... | 2.60 | 1.80 | 1.44 | 36.9 | 1 | G5: join + check-inbox with AGMSG_HOOK_STDIN_TIMEOUT=1 (the 1 s stdin timeout must elapse) via a bash timeout shim |
| 14 | delivery set monitor: round-trips multibyte (UTF-8) settings withou... | 2.57 | 0.47 | 5.43 | 37.7 | 0 | G2: one delivery.sh set monitor on a UTF-8 settings file (macOS 5.4x ubuntu; unexplained) |
| 204 | delivery status (codex): a recorded seat makes "not running" mean t... | 2.52 | 1.09 | 2.32 | 38.6 | 0 | G1: same arrange as #175 + seat record |
| 171 | delivery status (codex): bridge metadata mismatch is reported as stale | 2.42 | 1.00 | 2.41 | 39.4 | 0 | G1: same arrange as #175 (metadata mismatch) |
| 6 | delivery set monitor: idempotent | 2.36 | 0.99 | 2.38 | 40.1 | 0 | G2: 3 x delivery.sh set monitor + sqlite probe |
| 221 | check-inbox: names this pane on the way through (#1044) | 2.32 | 1.19 | 1.96 | 40.9 | 0 | G5: fake tmux + join + config + check-inbox |
| 165 | session-start.sh for codex never picks a seat by the pane its envir... | 2.28 | 1.27 | 1.80 | 41.7 | 0 | G4: 2 codex joins + seat fixtures + session-start codex |
| 163 | session-start.sh for codex does not choose a /clear seat by process... | 2.15 | 1.14 | 1.89 | 42.4 | 0 | G4: 2 codex joins + seat fixtures + session-start codex |
| 8 | delivery set monitor (codex): a hand-formatted, key-reordered hooks... | 2.11 | 1.05 | 2.01 | 43.1 | 0 | G2: delivery.sh set monitor codex on a hand-formatted hooks file + probes |
| 68 | session-start: snake_case session_id still wins over camelCase (cla... | 2.07 | 1.06 | 1.95 | 43.7 | 0 | G3: join + set monitor + session-start |

Remaining tests inside the first 70% of macOS time (number, group, macOS/ubuntu s): #166 G4 2.01/1.02; #134 G2 2.00/1.03; #66 G3 1.95/1.09; #182 G4 1.95/0.88; #73 G2 1.94/0.99; #159 G4 1.92/0.86; #67 G3 1.91/1.15; #210 G6 1.86/0.76; #15 G2 1.85/0.59; #100 G5 1.83/0.98; #65 G3 1.81/0.99; #132 G2 1.81/0.89; #87 G4 1.79/0.89; #133 G2 1.76/0.88; #1 G2 1.75/0.92; #160 G4 1.75/0.76; #17 G2 1.72/0.57; #47 G3 1.70/0.93; #105 G3 1.65/0.81; #10 G2 1.65/0.66; #83 G3 1.65/0.72; #214 G6 1.63/0.75; #208 G6 1.62/0.73; #46 G3 1.57/0.86; #181 G1 1.56/0.58; #106 G3 1.56/0.76; #81 G3 1.56/0.73; #7 G2 1.53/0.77; #209 G6 1.52/0.73; #64 G3 1.52/0.79; #19 G2 1.50/0.62; #60 G3 1.49/0.74; #213 G6 1.48/0.74; #164 G4 1.48/0.77; #4 G2 1.44/0.68; #61 G3 1.43/0.87; #9 G2 1.42/0.66; #12 G2 1.41/0.46; #45 G3 1.41/0.90; #62 G3 1.39/0.84; #11 G2 1.38/0.66; #72 G2 1.38/0.67; #118 G2 1.38/0.67; #109 G2 1.37/0.69; #167 G2 1.36/0.40; #161 G4 1.32/0.71; #114 G2 1.32/0.41; #215 G6 1.32/0.72; #80 G3 1.31/0.74; #18 G2 1.31/0.58; #84 G3 1.30/0.41

Reading the groups:

- **G1 (19 tests, 61 s macOS, ratio 2.7)**: `join.sh <team> alice codex` +
  `delivery.sh set monitor codex` + `delivery.sh status codex` per test, with bridge,
  seat or shim fixtures in between. On ubuntu the whole test is ~1.0 s; on macOS
  3.4-4.2 s. `set monitor codex` alone is 1.06 s macOS / 0.21 s ubuntu over the base
  (#167). A local exec trace of the arrange+act shows modest counts (join 108 execs,
  `set monitor` 76, `status` 56; mostly `sed`, `dirname`, `tr`, `sqlite3`, `mv`,
  `mktemp`), so the 4-6x macOS factor of `status codex` is not explained by Linux-side
  data.
- **G2 (73 tests, 86 s macOS, ratio 2.2)**: one to four `delivery.sh set/status`
  calls on claude-code/codex hook files plus sqlite probes.
- **G3/G4/G5 (49 tests, 86 s macOS, ratio ~1.9)**: a join plus `session-start.sh` or
  `check-inbox.sh` runs; process-spawn bound, no waits except #102 and #183.
- **G6 (12 tests, 26 s macOS, ratio 1.6)**: watcher starts; #103/#107 hold flat
  windows, #208-#215 poll the watcher log at 0.1 s until a line appears.
- **G7/G8 (72 tests, 36 s macOS)**: rule-file types and validation failures, ~0.3-0.9 s
  each, i.e. mostly the fixed per-test cost.
- **G9**: #44 (below) and #24 (skipped on macOS).

## Proposals

Estimates are per full CI run.

### D1. Cache `init-db.sh`'s output per bats file in `setup_test_env` - test-only, low risk

- Change: tests/test_helper.bash:81 runs `init-db.sh` (13 execs: 6 `dirname`, 3
  `sqlite3`, ...) in every test. Its only output is `db/messages.db` (WAL mode set in
  the header, no path inside), so run it once per file and `cp -p` the result from
  `$BATS_FILE_TMPDIR` afterwards (prototype in
  `survey/deepdive/work-wdt/prototype.diff`, 10 lines).
- Estimate: locally the 14 fast validation tests went 3739 -> 3475 ms (19 ms per
  test); macOS assumed ~2.5x for an exec-bound step: 227 x 0.045 / 0.019 s =
  **~10 s macOS / ~4.5 s ubuntu**. Shared helper: test_team.bats (~4 / ~2 s),
  test_watch.bats (~2 / ~1 s) and every other file that calls `setup_test_env` gain the
  same per test.
- Coverage: each test still gets its own database file. init-db.sh still runs once
  per file (and in its own tests). If a file ever changes `_agmsg_runtime_db_path`'s
  inputs before `setup_test_env`, the cache must be skipped; the prototype only caches
  `$TEST_SKILL_DIR/db/messages.db`.

### D2. #44: give only the third session-start a 1 s autostart budget - test-only, low risk

- Change: test_delivery.bats:883, add `AGMSG_SYNC_AUTOSTART_TIMEOUT_S=1` to that
  `run env ...` line (read at sync-autostart.sh:73, default 5).
- Why: the third run uses the real `remote.sh` against a connected team with no
  server; its `sync start` never sees the engine's capabilities event, so the autostart
  waits its whole 5 s budget and reports the start as still in flight
  (sync-autostart.sh:177-196, :241-252). The test's assertions (a runnable `bash ...`
  line that survives a spaced install path, then a successful run of it with a fake
  node) do not depend on which branch printed the line.
- Measured: 6.52 -> 2.50 s locally with the change on that line only; passes. With
  the budget at 1 s for the whole test it also passes (8.13 -> 3.99 s), but that would
  also shorten the budget of the second run, which must reach the "failed" branch
  before the budget ends; keep it on line 883 only.
- Estimate: **~4 s per OS** (a fixed wait, same on both).
- Notes: the comment above the test says "The budget is raised as well" but no
  override exists in the file; the second run is the one that would benefit from a
  raised budget (robustness on a slow runner, not speed). Separately, the in-flight
  child keeps polling for up to `AGMSG_TEST_SYNC_START_READY_SECONDS` (16 s,
  remote.sh:3230) after the test ends, with `sleep 0.01` and four spawns per turn
  (remote.sh:3317-3334), competing with the next tests for CPU. Shortening that budget
  in the same line is tempting but makes the child reap the engine and delete the
  pidfile the test reads afterwards, so it needs its own change (for example stopping
  the child explicitly at the end of the test).

### D3. #183: set the mtimes explicitly instead of `sleep 1` - test-only, no risk

- Change: test_delivery.bats:3506-3507. Replace `sleep 1; touch <stale-by-name>` with
  `touch -t 202001010000 <newer-by-name>` followed by the existing touch: the
  newer-by-name file becomes older on disk without waiting for the clock. `touch -t`
  is POSIX (GNU and BSD). The resolver sorts the newest N rollout files by mtime and has
  no age window (drivers/types/codex/_session-start.sh:17-60).
- Measured: 1.97 -> 1.09 s locally; passes. Estimate: **~0.9 s per OS**.
- Coverage: same ordering, and it no longer depends on 1-second mtime granularity.

### D4. #103 and #107: end the absence window one poll after the allowed message - test-only, low risk

- Change: #103 `sleep 3` (:1821), #107 `sleep 3` (:1941). Wait for the allowed line
  ("new-for-bob" / "for-alice-static") with `wait_for_file_contains`, then sleep one
  poll interval plus margin (`sleep 1.5` at `AGMSG_WATCH_INTERVAL=1`), then stop the
  watcher and assert the forbidden line is absent.
- Why it respects the comments (:1815-1820, :1935-1940): they reject polling for the
  allowed message because a buggy watcher could be killed between writing the allowed
  line and the forbidden one. A watcher prints a poll's rows in one pass, so a
  forbidden row already in the store appears within milliseconds of the allowed one. In
  #103 the forbidden message is sent first, so it is in the store before the allowed
  one; in #107 it is sent second and could land one poll later, which the extra full
  interval covers.
- Estimate: arrival (~0.5 s average) + 1.5 s instead of 3 s: **~1 s per test, ~2 s per
  OS**.
- Related, robustness rather than speed: #107's `sleep 1` (:1925) assumes the watcher
  has resolved its subscription within 1 s of launch; on a slow macOS runner startup can
  exceed that, and then `join.sh bob` lands inside the snapshot and the refute fails.
  Sending a probe to alice before launch and waiting for it to be delivered is a real
  "subscription resolved" event.

### D5. #102: shorten the stdin timeout to 0.3 s - test-only, low risk

- Change: test_delivery.bats:1770, `AGMSG_HOOK_STDIN_TIMEOUT=1` -> `0.3`. The value
  goes to `timeout` (check-inbox.sh:95); the test's own shim and GNU `timeout` both
  accept fractions.
- Measured: 1.98 -> 1.21 s locally; passes. Estimate: **~0.7 s per OS**.
- Coverage: the property is "returns instead of hanging"; the timeout length is not
  asserted.

### D6. Optional: #205 with a shorter probe timeout - test-only, medium risk

- Change: test_delivery.bats:3851, run status with
  `AGMSG_CODEX_STATUS_PROBE_TIMEOUT_MS=300` (read at
  drivers/types/codex/_delivery.sh:131-132, default 1500).
- Estimate: **~1.2 s per OS**.
- Risk: medium. Today the test proves the default bound is short (`elapsed < 8`); with
  an override it only proves the override is honoured. Worth it only if the default is
  asserted somewhere else.

### D7. Profile `delivery.sh` on macOS - not test-only, no coverage risk

- Observation: G1 + G2 are 147 s macOS against 62 s ubuntu. Session-start and
  check-inbox tests, which spawn similar tools, run at ~1.9x; `delivery.sh` runs at
  2.2-2.7x overall and up to 4-6x on `set monitor codex` / `status codex` (#167, #175)
  and on a UTF-8 settings file (#14: 2.57 s vs 0.47 s for one call).
- Proposal: a one-off macOS run with timestamps per sourced library and per spawned
  command (Homebrew bash 5 for `EPOCHREALTIME`, or `dtruss -f`) to find what is
  macOS-specific (candidates: bash 3.2 parse time of the ~7100 lines delivery.sh
  sources, per-exec cost of `sqlite3`/`mktemp`/`sed` from a large bash 3.2 process,
  the codex status path's `shasum` (a Perl script) and node lookup).
- Estimate (ceiling): bringing G1 + G2 to the file's ~1.9x level would save
  **~25-30 s macOS**, ubuntu unchanged. Not counted in the summary total.

Not proposed: merging the 13 validation tests (G8) or the rule-file tests (G7) into
fewer tests (saves only the ~0.3 s per-test base, about 3 s macOS for G8, and loses
per-case failure reports); `AGMSG_RESOLVE_PROJECT=0` on the remaining arrange joins
(~40 ms per join locally on top of the pin); replacing `delivery.sh set monitor codex`
in the G1 arrange with a prebuilt hooks file (the hooks embed the per-test skill path,
so a template would need path rewriting); splitting the file (304 s is a quarter of a
6-shard slot and has no long pole).

## Risks and notes

- The fixed per-test cost (~22 % macOS / 29 % ubuntu) is mostly bats itself plus
  `setup_test_env`'s copy of the 257-file `scripts/` tree; D1 removes only the init-db
  part. Making the copy cheaper (hard links, shared trees) is unsafe because several
  tests rewrite scripts in place (for example #44 replaces `$SCRIPTS/remote.sh`).
- Two comments in this file are out of date and worth fixing with D2/D4: #44's "The
  budget is raised as well" (nothing raises it), and the latent `sleep 1` race in #107
  described under D4.
- After landing, refresh `.github/scripts/bats-file-seconds.tsv` so shard-tests.sh
  keeps the shards balanced (tests/test_ci_sharding.bats asserts the ratio).
