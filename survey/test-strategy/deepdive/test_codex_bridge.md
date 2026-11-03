# test_codex_bridge.bats: where the CI time goes

Data: CI run 41607512279 (main @ 64723d6), `per-test-41607512279.tsv`, macOS shard 2 and ubuntu shard 2. Code read at main @ 551764e. Local checks (Linux, loaded box): a file-tree diff of what the setup writes, and 7 single tests run from a scratch copy of the file with the proposed setup and with the original. Paths are repo-relative; `Lnnn` means `tests/test_codex_bridge.bats:nnn`.

## Summary

- **145 s macOS / 144 s ubuntu** for 51 tests. The macOS/ubuntu ratio is ~1.0 throughout (0.8-1.3 per test), so time goes to two things that cost the same on both OSes:
  - **a fixed per-test setup cost**;
  - **timed waits inside the bridge runs**: windows, request timeouts, and the bridge's 1 s re-arm floor.

  This run's macOS shard-2 runner was fast: shard-2 files ran at 1.0-1.2x against 2-3x elsewhere, on the same image macos-26-arm64. `.github/scripts/bats-file-seconds.tsv` records 206 s macOS for this file, so on a slower runner the setup share grows on macOS.
- **Setup (L5-11) = `setup_test_env` + two `join.sh` calls (team alice / team bob, type codex).** Tests that use none of that pay it anyway. #1-#10 are pure node or grep checks and take 1.39-1.60 s macOS / 1.67-1.94 s ubuntu (#4, #6-#10: 1.39-1.46 s / 1.67-1.73 s). That is **≈ 1.35 s macOS / 1.6 s ubuntu per test, ≈ 69 s / 83 s per file (48% / 57%)**. The two joins alone are ≈ 1.0 s / 1.45 s per test. The joins write only `teams/team/{config.json,roster.jsonl}`, but their project path is `$TEST_SKILL_DIR/proj`, which differs per test.
- **Timed waits:**
  - #44: three 2 s windows, run one after another.
  - #45: one 6 s window.
  - #43: ~7 re-arms, each paced by the hard-coded 1 s `MIN_ARM_INTERVAL_MS`.
  - #33: a 3 s request timeout.
  - #27: a 2 s loaded-thread poll.
  - About ten tests each pay the 1 s re-arm floor once.
  - #49's 2 s and #36/#37's scripted timelines are justified in comments.
- **Test-only proposals C1-C5 and C7 save ≈ 63 s macOS / ≈ 85 s ubuntu (43% / 59%).** C1 alone is ≈ 50 s / 72 s. It was verified locally on 7 tests: 1.8-3.9 s each down to 0.27-1.9 s, all green. A product change, C6, a strictly validated test override for the 1 s re-arm floor, would save ≈ 10 s per OS more.

## Where the time goes

Driver legend:

- **F2**: the per-test setup.
  - `setup_test_env` (test_helper.bash:42-116).
  - Two `join.sh` calls (L9-10). Each one walks the CI process tree to pid 1 through `agmsg_agent_pid` (scripts/lib/resolve-project.sh:526), 3 `ps` per hop.
  - Teardown: `rm -rf "$PROJ"` plus `teardown_test_env`.
  - Cost ≈ 1.35 s macOS / 1.6 s ubuntu. Basis: #4 (grep only, 1.39 s / 1.67 s), #9 and #10 (toPosixPath, 1.39 s / 1.70 s and 1.44 s / 1.73 s).
- **floor**: the bridge waits until 1000 ms have passed since its previous watch-once arm before arming again (`MIN_ARM_INTERVAL_MS`, scripts/drivers/types/codex/codex-bridge.js:30, applied at :1373). There is no override.
- **inline-inbox bash**: with `--inline-inbox`, the bridge spawns `eligible-pairs.sh` and `inbox.sh`; the fakes also call `send.sh`. These are real bash + sqlite runs.
- **probe**: a node capability probe at the top of the test, `run node -e '…spawnSync("/bin/sh")…'`, plus net/crypto and unix-socket probes in #43-46.

The table covers the tests that make up the first 70% of the file's macOS time. Every test over 5 s falls inside that set.

| # | title | macOS s | ubuntu s | mac/ubu | cum. macOS % | driver |
|---:|---|---:|---:|---:|---:|---|
| 44 | codex-bridge: an invalid watch-rearm override falls back to the production delay, not an imm... | 8.59 | 8.42 | 1.02 | 6.0 | F2 + 3 cases run **sequentially**, each: fake WS server + bridge start, poll for 1st arm, fixed `sleep 2` window (L1899-1920) |
| 45 | codex-bridge: a flood of distinct wakes is rate-limited, not a re-arm storm (#936) | 8.08 | 7.87 | 1.03 | 11.6 | F2 + fixed `sleep 6` flood window (L1947), ceiling `arms <= 20` |
| 43 | codex-bridge: the failure cap reaches even when wakes interleave (#936) | 7.92 | 7.97 | 0.99 | 17.1 | F2 + ~7 watch-once arms, each paced by the 1 s `MIN_ARM_INTERVAL_MS` floor (codex-bridge.js:30, no override) to climb to the decayed failure cap of 3 |
| 33 | codex-bridge: delayed re-arm after sub-limit watch failure times out fatally | 6.12 | 5.96 | 1.03 | 21.4 | F2 + `--request-timeout-ms 3000` must elapse on the never-answered 2nd process/spawn (L1329) + 1 s arm floor |
| 49 | codex-bridge: a stale idle landing after the new turn was seen starting does not end the run... | 6.08 | 5.29 | 1.15 | 25.6 | F2 + fake's deliberate 2000 ms late completion (comment: must exceed subprocess latency) + floor + inline-inbox bash (send.sh, inbox.sh) |
| 36 | codex-bridge: an actively-streaming turn is not cut off by the idle watchdog past turn-timeout | 5.28 | 5.14 | 1.03 | 29.3 | F2 + scripted streaming timeline (deltas past `--turn-timeout 1`) + floor, 2 wakes |
| 37 | codex-bridge: non-message turn activity (reasoning/tool-call progress) also re-arms the idle... | 5.13 | 5.14 | 1.00 | 32.8 | F2 + scripted timeline 300/900/1600 ms vs `--turn-timeout 1` + floor, 2 wakes |
| 47 | codex-bridge: one wake starts one turn even when the previous turn's tail lands mid turn/sta... | 4.69 | 3.78 | 1.24 | 36.1 | F2 + inline-inbox bash (eligible-pairs.sh, inbox.sh, send.sh) + floor, 2 wakes |
| 34 | codex-bridge: re-arms after a turn via the watchdog when no turn/completed arrives | 4.49 | 3.94 | 1.14 | 39.2 | F2 + `--turn-timeout 1` watchdog + floor, 2 wakes |
| 27 | codex-bridge: --thread loaded errors when no thread is loaded in time | 3.83 | 3.94 | 0.97 | 41.9 | F2 + `--loaded-timeout 1500` with a fixed 1000 ms poll (codex-bridge.js:1293) = 2 s |
| 48 | codex-bridge: a turn fully notified before its turn/start ACK still ends promptly (deferred ... | 3.57 | 2.74 | 1.30 | 44.4 | F2 + inline-inbox bash, 1 wake |
| 32 | codex-bridge: re-arm spawn request timeout exits without a phantom watch | 3.51 | 3.39 | 1.04 | 46.8 | F2 + `--request-timeout-ms 500` + 1 s arm floor |
| 29 | codex-bridge: stops instead of looping on the same unread max_id | 2.92 | 2.88 | 1.02 | 48.8 | F2 + one 1 s arm floor (2nd arm sees the same max_id) |
| 31 | codex-bridge: watch-once timeout exit does not count toward failure limit | 2.91 | 2.88 | 1.01 | 50.9 | F2 + one 1 s arm floor |
| 35 | codex-bridge: re-arms after a turn when the app-server reports idle (not turn/completed) | 2.83 | 2.87 | 0.99 | 52.8 | F2 + one 1 s arm floor |
| 38 | codex-bridge: delivers a wake observed while the resumed thread was still active (no stale-s... | 2.81 | 2.88 | 0.98 | 54.8 | F2 + floor + 2 wakes |
| 51 | codex-bridge: stale unknown team is skipped silently without dropping healthy inboxes (#1714) | 2.73 | 2.25 | 1.21 | 56.7 | F2 + send.sh + readInboxForPrompt (eligible-pairs/inbox.sh) |
| 42 | codex-bridge: the turn watchdog rescues a resumed thread already active with no bridge-owned... | 2.70 | 2.90 | 0.93 | 58.6 | F2 + `--turn-timeout 1` watchdog, 2 wakes |
| 19 | codex-bridge: times out when a stdio app-server request never responds | 2.49 | 2.41 | 1.03 | 60.3 | F2 + stdio request timeout (500 ms) under a 3 s runner |
| 18 | codex-bridge: times out when an app-server request never responds | 2.39 | 2.12 | 1.12 | 61.9 | F2 + WS request timeout (100 ms) + runner |
| 28 | codex-bridge: inline-inbox includes unread message text in turn input | 2.37 | 2.69 | 0.88 | 63.6 | F2 + send.sh + inline-inbox turn |
| 46 | codex-bridge: a thread owned by another writer is fatal, not proceed-without-resume (#906) | 2.30 | 2.09 | 1.10 | 65.2 | F2 + WS fake (owned thread) + 2 node probes |
| 15 | codex-bridge: connects to unix app-server sockets over websocket | 2.21 | 2.18 | 1.01 | 66.7 | F2 + unix-socket WS fake server start + 1 wake |
| 17 | codex-bridge: times out when a websocket upgrade never completes | 2.12 | 2.13 | 0.99 | 68.2 | F2 + connect timeout (100 ms) + runner |
| 23 | codex-bridge: resumes an existing thread before arming | 2.08 | 2.01 | 1.04 | 69.6 | F2 + thread/resume + codex-record-session.sh |
| 22 | codex-bridge: starts a turn when app-server reports watch-once pending | 2.08 | 1.99 | 1.04 | 71.1 | F2 + 1 wake, 1 turn |

Observations:
- Every row includes F2, which is ~1.35 s macOS / ~1.6 s ubuntu. The 2.0-2.5 s tests (#15-#23) are F2 plus ~0.7 s of real bridge work: node start-up, the fake app-server, `identities.sh`, and `codex-record-session.sh` on resume.
- The waits are wall-clock, so they cost the same on both OSes.

## Proposals

### C1. Run the two setup joins once per file (fixed per-file project path plus a teardown-safe template)

- **Change (L5-11).** Pin `PROJ` to one path per file so the registrations are byte-identical in every test. Produce them with join.sh once and copy them per test:

  ```bash
  setup() {
    setup_test_env
    # A fixed per-file project path keeps the two registrations byte-identical
    # in every test, so join.sh runs once per file and each test gets a copy.
    export PROJ="$BATS_FILE_TMPDIR/proj"
    rm -rf "$PROJ"; mkdir -p "$PROJ"
    local tpl="$BATS_FILE_TMPDIR/teams-template"
    if [ ! -d "$tpl" ]; then
      bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
      bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
      mkdir -p "$tpl" && cp -R "$TEST_SKILL_DIR/teams/." "$tpl/"
    else
      cp -R "$tpl/." "$TEST_SKILL_DIR/teams/"
    fi
  }
  ```

  The existing teardown (`rm -rf "$PROJ"`) stays, and setup re-creates the directory, so each test still starts from an empty project dir.
- **Tests:** all 51. The first test builds the template.
- **Savings:** 50 × ≈ 1.0 s macOS / 1.45 s ubuntu ≈ **50 s macOS, ≈ 72 s ubuntu**. On a macOS runner as slow as shards 3/4 of this run, the macOS figure would be 2-3x larger.
  - Basis: F2 from #4/#9/#10 (1.39-1.44 s / 1.67-1.73 s), minus the bare fixture (≈ 0.3 s / 0.15 s) and the node or grep act.
  - Local check (original → C1): #11 2.52 → 2.05 s (this test built the template), #12 2.47 → 0.27 s, #13 1.89 → 0.27 s, #20 1.76 → 0.35 s, #22 2.55 → 0.69 s, #28 3.92 → 1.91 s, #51 2.86 → 1.34 s. All passed, including #28, which compares `runtimeWorkspaceRoots` against `process.env.PROJ`.
- **test_only:** yes. **Coverage risk: low.**
  - `PROJ` is used only as a `--project`/`--workspace-root` value and through `process.env.PROJ` (L139, L1005, L1033, L2402). Nothing compares it with `$TEST_SKILL_DIR`.
  - The teardown reaper keys on `$TEST_SKILL_DIR` in argv. Bridges and fakes still carry it, through `$TYPES/codex/codex-bridge.js` and the fake scripts' paths.
  - Each test still gets its own `teams/` copy, so a test that edits the roster cannot leak.
  - CI runs files serially without `--jobs`. If `--jobs` were enabled, use `setup_file`.

### C1-lite (alternative to C1, not additive). `export AGMSG_AGENT_PID=""` in setup

- **Change.** Add the line 14 other files already carry, for example test_delivery.bats:10 ("deterministic in CI and when the suite runs under an agent process"). It removes the 10-11-hop process-tree walk from both joins. In CI that walk ends empty, so the result is identical.
- **Savings:** 51 × 2 × ≈ 0.21 s macOS / 0.31 s ubuntu ≈ **21 s / 32 s**. Basis: ~42% of a CI join, from the local fork/exec counts (codex join: 362 → 240 forks, 180 → 127 execs, 21 → 0 `ps`) scaled to the CI tree depth seen in the sampler's ps listings.
- **test_only:** yes. **Coverage risk: low.** The bridge's own helpers would also see the empty pin. They run under node, with no codex ancestor, so CI behaviour does not change.

### C2. #44: run the three override cases concurrently (L1899-1925)

- **Change.** Each case already has its own fake server socket and log (`rearm3-$i.sock` / `.log`). Start all three servers and bridges, poll each log for its first arm, run one `sleep 2`, then kill all three and count arms per case.
- **Savings:** ≈ **4.8 s macOS / 4.5 s ubuntu**. Basis: (8.59 − 1.35) / 3 ≈ 2.4 s per case on macOS and (8.42 − 1.6) / 3 ≈ 2.3 s on ubuntu, and two of the three windows go away.
- **test_only:** yes. **Coverage risk: low.**
  - The rationale for the 2 s window (L1908-1912) is kept: past the 1 s floor and short of the 5 s production delay.
  - The only weakening is under heavy load. Six node processes start at once, and if a broken immediate re-arm were then pushed past 2 s for *all three* cases, the regression would slip through.

### C3. #45: shorten the flood window from 6 s to 3 s (L1947, L1957)

- **Change.** `sleep 6` → `sleep 3`, and the ceiling `[ "$arms" -le 20 ]` → `-le 10`.
  - With the 1 s floor the bridge arms about once per second, ≈ 3 arms in the window.
  - Without the floor the comment reports "hundreds" in 6 s (L1951-1953), and codex-bridge.js:27 measured 2094 arms in 56 s, ≈ 37/s, or ~110 in 3 s.
  - The margin stays ≥ 3x on both sides.
- **Savings:** **3 s per OS.**
- **test_only:** yes. **Coverage risk: low.**
- A sharper alternative, not the default: wait until the fake has logged 3 arms, then assert from the `Date.now()` stamps it already writes that consecutive arms are ≥ ~0.8 s apart. This takes ~2 s and asserts the floor directly, but changes the assertion.

### C4. #33: `--request-timeout-ms 3000` → `1000` (L1329)

- **Change.** The timeout under test belongs to the second `process/spawn`, which the bridge sends ~1 s after start (1 s floor plus the 50 ms override at L1326).
  - #32 already uses 500 ms for the same failure shape (L1265).
  - If `initialize` ever took longer than the timeout, the test would fail with a different message (`'initialize' timed out`). It would not pass vacuously.
- **Savings:** **≈ 2 s per OS.**
- **test_only:** yes. **Coverage risk: low.**

### C5. #27: `--loaded-timeout 1500` → `500` (L952)

- **Change.** `resolveLoadedThread` polls every 1000 ms and dies at the first empty poll past the deadline (codex-bridge.js:1278-1293).
  - 1500 ms costs two 1 s sleeps. 500 ms costs one and still exercises one retry.
  - Do not use 0: `this.opts.loadedTimeout || 30000` turns it into 30 s.
- **Savings:** **≈ 1 s per OS.**
- **test_only:** yes. **Coverage risk: none.**

### C6. (Product) A strictly validated test override for the 1 s re-arm floor

- **Change.** In codex-bridge.js, read e.g. `AGMSG_TEST_CODEX_BRIDGE_MIN_ARM_MS` with the same `_isPlainDigitString` + range checks as `AGMSG_TEST_CODEX_BRIDGE_WATCH_REARM_MS` (codex-bridge.js:31-72). Anything malformed falls back to 1000.
  - **Use it** only in tests that assert counts or ordering rather than the floor: #43, #29, #31, #34, #35, #38, #42.
  - **Never use it** in #44/#45, which exist to prove the floor.
- **Savings:** ≈ **10 s per OS.** #43 pays ~6 floors (≈ 5.4 s); six tests pay one floor each (≈ 0.9 s each). #43's N cannot shrink instead: with the default failure limit of 3, the fail/wake/fail pattern reaches the cap under the new decay but never under the old reset-to-0 rule. With a limit of 2, both rules stop, and the test would no longer tell them apart.
- **test_only:** no. **Coverage risk: low-medium.** It is a new test-only knob in product code. The precedent and its validation pattern already exist next to it.

### C7. Probe node capabilities once per file instead of once per test

- **Change.** 25 tests start with `run node -e 'const r = require("child_process").spawnSync("/bin/sh", …)'`. #43-46 add 8 net/crypto probes and ~4 unix-socket `listen` probes. Each probe is a node start-up, ~0.05 s. Run each probe once, for example in a helper that caches its verdict under `$BATS_FILE_TMPDIR`, and keep the per-test `skip` lines unchanged.
- **Savings:** ≈ 35 node start-ups ≈ **2 s per OS.**
- **test_only:** yes. **Coverage risk: none.** The environment cannot change within one file run.

## Risks and notes

- **Not proposed: #49's 2000 ms delayed completion.** The comment at L2305-2309 says it must stay "deliberately far above the bridge's subprocess latency … so the ordering assertion below cannot be saved by a slow machine".
- **Not proposed: #36/#37's timelines.** Deltas at 300/900 ms and completion at 1600 ms against `--turn-timeout 1` encode the behaviour under test. Scaling them down would shrink the 300-700 ms scheduling margins on loaded runners, which invites flakes.
- **Not proposed: #34/#42's `--turn-timeout 1`.** `turnTimeout` accepts fractions (codex-bridge.js:287, :1637), but the next arm waits for the 1 s floor anyway, so a shorter watchdog saves nothing without C6.
- **Order of value.** C1 is ~80% of the test-only saving. If a reviewer prefers not to move `PROJ`, C1-lite gets about 40% of C1 with a one-line change.
- **What remains after C1-C5 and C7** (≈ 82 s macOS / 60 s ubuntu): the fixture, node start-ups, and the deliberate waits in #36, #37, #43, #44 (one 2 s window), #45 (3 s) and #49.
