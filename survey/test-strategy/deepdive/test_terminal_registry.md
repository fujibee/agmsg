# tests/test_terminal_registry.bats — where the CI time goes

Data: CI run 41607512279 (main @ 64723d6, shard 5 on both OSes), `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/per-test-41607512279.tsv`. Code read at main @ 551764e; the file, `tests/test_helper.bash` and the terminal drivers/registries are unchanged since 64723d6.

Local measurements were taken on Linux, 4 cores, under a background strace sweep (load 3-7), bats 1.13.0 and bash 5.2.21. A/B runs were made on copies of this file in `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/survey/deepdive/rst/fakerepo/tests/`; the repo was not modified. The strace sweep was stopped before it reached this file, so there are no per-test exec counts; drivers come from reading the tests and from the A/B runs.

## Summary

- **Size:** 211 tests, **203.6 s macOS / 108.2 s ubuntu**.
- **The time is flat.** The top 25 tests are only 40% of the macOS time; the other 186 average 0.66 s macOS / 0.32 s ubuntu.
- **The fixture is about 36% of the file.** Every test pays `setup_test_env` + sourcing `terminal-registry.sh` (L15-38) + `teardown_test_env`: the 10 fastest tests average **0.37 s macOS / 0.22 s ubuntu**. Across 211 tests that is ~74 s macOS / ~42 s ubuntu (36% / 39%).
- **Fixed waits: 10.7 s per OS, all in two tests.**
  - Test 142's last block (L2981) and test 148's never-recovers case (L3181) run herdr's whole `agent_not_found` retry budget: 50 × `sleep 0.1` (`scripts/drivers/terminals/herdr/ops.sh:1392-1407`, `:1468-1477`).
  - Test 148's three recovering cases add 7 more pauses.
- **bats' DEBUG trap inflates the in-process code.**
  - Most tests call registry and driver functions in the bats test shell. There, bats runs `trap 'bats_debug_trap "$BASH_SOURCE"' DEBUG` under `set -eET` (bats-core `tracing.bash:385`), before every simple command, including inside library functions and `$(...)`.
  - Locally, test 174 drops from 3.4 s to 1.2 s (−65%) when the trap skips the sandbox's library frames. A group of 9 placement-guard tests drops 20%, a group of 9 typical orca tests 10%. Every test still passes.
- **Process-tree walk:** the join/actas tests (135-138) pay the ~10-hop `ps` walk in `join.sh`/`actas-claim.sh` described in `test_remote.md`. Their macOS/ubuntu ratio is low (1.38-1.70), which is the walk's signature.
- **Proposals, all test-only:**
  1. A counting `sleep` stub in tests 142 and 148: **~11.5 s macOS / ~10.9 s ubuntu**, and it adds an assertion that nothing pins today.
  2. Keep the bats DEBUG trap out of the sandbox's library frames: **~18 / ~14**.
  3. Copy an initialised fixture instead of re-running `init-db.sh` + chmod per test: **~17 / ~8** (a test_helper change, shared with other files).
  4. Pin `AGMSG_AGENT_PID=""`: **~4 / ~3**.

## Where the time goes

The top 25 tests by macOS time are listed one by one; together they are 39.6% of the file's macOS time and include every test over 5 s. The remaining 186 tests are grouped below, so the two tables together cover 100%.

| # | title | macOS s | ubuntu s | ratio | driver |
|---|---|---|---|---|---|
| 142 | naming ON by default (herdr): keeps existing names and records placement (#1631) | 15.7 | 9.9 | 1.59 | 9 in-process `agmsg_terminal_name_self ... record` calls through the fake herdr (3, then 5 malformed replies at L2969-2979, then 1 more). The last, `HERDR_AGENT_GET_FAIL=1` (L2981), retries `agent get` to the bound: **50 × `sleep 0.1` = 5.0 s fixed** plus 51 fake-herdr execs |
| 148 | terminal_name retries an 'agent_not_found' rename and succeeds once herdr catches up (#1631) | 13.0 | 7.5 | 1.74 | 5 in-process `terminal_name` calls. Retry pauses 3 + 3 + 1, then the never-recovers case (L3181-3185): **57 × `sleep 0.1` = 5.7 s fixed**, and 62 fake-herdr execs, each forking `cat` for its counter |
| 174 | placement guard: the pane splitter agrees with the registry's own ref parsers on every accepted form (#1114 follow-up) | 5.7 | 3.5 | 1.61 | CPU-bound in-process parsing: 9 refs × 3 readers + 6 refusals (L3770-3796). Locally 65% of its run time is the bats DEBUG trap |
| 137 | join: proxy registration leaves the caller untouched and actas records the member pane | 3.9 | 2.8 | 1.38 | `join.sh` + `actas-claim.sh` subprocesses (L2847, L2852), each doing the ~10-hop `ps` walk on CI |
| 6 | resolve: a trusted external manifest participates in every chooser (#1133) | 3.6 | 1.7 | 2.10 | `agmsg_terminal_candidates` + 3 resolvers over all 7 drivers incl. a trusted external one. Each resolver re-reads every manifest through subshells |
| 135 | actas-claim: names the pane when the sid arrives COMPOSITE and herdr knows the bare one | 3.3 | 2.4 | 1.38 | `join.sh` + `actas-claim.sh` (L2764-2766): two walks, plus a naming in the subprocess |
| 120 | herdr naming: the bare-pane arm is POSITIVE by STRUCTURE — an unresolvable entry is did-not-answer | 3.1 | 1.7 | 1.85 | loop over 7 raw agent entries → `run agmsg_terminal_resolve_name` each (fake `herdr agent list` + sqlite JSON parsing) |
| 179 | placement guard: a claimant whose session is confirmed gone lets a live seat take the pane; a claimant still there still refuses (#1485) | 2.8 | 2.2 | 1.27 | 3+ in-process namings with `record` + placement-guard reads. The low ratio means interpreter work (trap), not forks |
| 178 | placement guard: a record under a VANISHED team is dropped and the seat acting now is recorded, without a warning | 2.8 | 2.4 | 1.16 | same shape as 179 |
| 44 | herdr: the pane-id grammar shell authority agrees with the resolver on boundary values | 2.4 | 1.2 | 1.96 | boundary-value loop: `run agmsg_terminal_resolve_name` per value through the fake herdr |
| 5 | self env asks registered drivers in nesting order and keeps unknown distinct from n/a | 2.2 | 1.2 | 1.86 | ~9 `agmsg_terminal_self_env` calls, each asking every driver |
| 63 | orca: bare refs and local locators split to the same handle and CLI target | 1.8 | 1.0 | 1.80 | ~12 in-process split/qualify/claim calls + fake orca |
| 171 | terminal_name_self record: the same SEAT under another TEAM is not a rival claim (#1114) | 1.6 | 1.1 | 1.52 | in-process namings with `record` + guard reads |
| 136 | join: tmux registration neither names the caller nor takes placement | 1.6 | 1.0 | 1.70 | one `join.sh` subprocess (walk) |
| 59 | herdr naming: the internal key avoids the known fold/join collisions ('-' and ':') | 1.6 | 0.9 | 1.86 | key-derivation loop (sha256 helper per name) |
| 138 | join: a dedicated session_env does not authorize pane naming | 1.6 | 1.1 | 1.48 | one `join.sh` subprocess (walk) |
| 175 | placement guard: a peer whose name ENDS in this seat's name is another seat (#1114 review) | 1.6 | 1.0 | 1.52 | in-process namings + guard reads |
| 121 | herdr naming: a STRUCTURE-complete bare pane reaches not-among in every agent_status... | 1.6 | 0.8 | 1.99 | loop over agent statuses → resolve per status |
| 10 | record: an unknown or CORRUPT ref FAILS CLOSED — validates the ID, not just the scheme | 1.6 | 0.6 | 2.40 | ref-validation loop (driver load per scheme) |
| 176 | placement guard: a peer record whose ref cannot be read as a pane is a CLAIM, not a pass (#1114 review) | 1.5 | 1.1 | 1.42 | in-process namings + guard reads |
| 195 | seam: a seat that fell through to its ENVIRONMENT is refused when a peer's record claims that pane (#1112 x #1114) | 1.5 | 1.2 | 1.30 | in-process name_self + label resolution + guard |
| 207 | id grammar: the three built-in drivers answer exactly as the registry's table did (#1141 review) | 1.5 | 1.1 | 1.45 | grammar table × 3 drivers, in-process |
| 1 | resolve: falls back to plain when neither tmux nor herdr is present | 1.5 | 0.7 | 2.09 | absorbs file startup: bats preprocessing this 4,879-line file is ~1.1 / 0.5 s over the floor |
| 194 | seam: a seat resolved by its LABEL is refused when a peer's record claims the label's pane (#1112 x #1114) | 1.5 | 1.1 | 1.36 | same shape as 195 |
| 77 | orca: enumerate_panes lists every live handle under the one measured instance... | 1.5 | 0.5 | 3.26 | fake-orca execs. Process-bound, highest ratio |

The remaining 186 tests total 123.0 s macOS / 58.6 s ubuntu. Each is the fixture (~0.37 / ~0.22) plus a few fake-binary execs and in-process registry calls.

| group (title prefix) | tests | macOS s | ubuntu s | ratio | test numbers |
|---|---|---|---|---|---|
| orca: | 32 | 21.5 | 8.6 | 2.49 | 60-62, 64-76, 78-93 |
| herdr: (driver ops) | 25 | 15.4 | 6.7 | 2.31 | 13, 14, 38-43, 45-56, 58, 107-109, 205 |
| herdr naming: | 16 | 10.8 | 4.8 | 2.26 | 110-112, 114-119, 122-128 |
| tmux: | 17 | 10.7 | 4.4 | 2.45 | 12, 22-37 |
| self-identity: | 16 | 7.4 | 4.4 | 1.68 | 181-186, 188-193, 196-199 |
| resolve | 12 | 7.4 | 3.2 | 2.30 | 2-4, 7, 100, 113, 129-131, 204, 206, 210 |
| plain: | 12 | 6.9 | 2.8 | 2.50 | 15-21, 101-105 |
| terminal_name_self | 7 | 6.8 | 4.5 | 1.51 | 132-134, 167-170 |
| titles starting "a ..." (#1044 naming failures, #1051 refs) | 7 | 6.4 | 4.1 | 1.57 | 143, 144, 146, 147, 150, 159, 160 |
| pane_state | 10 | 5.4 | 2.2 | 2.48 | 152-157, 161-164 |
| naming on/off, failure messages | 7 | 4.8 | 2.8 | 1.70 | 139-141, 200-203 |
| placement guard (rest) | 4 | 4.1 | 2.8 | 1.44 | 172, 173, 177, 180 |
| everything else | 21 | 15.3 | 7.4 | ~2.1 | 8, 9, 11, 57, 94-99, 106, 145, 149, 151, 158, 165, 166, 187, 208, 209, 211 |

The groups with a ratio of 1.4-1.7 (self-identity, terminal_name_self, placement guard, the "a ..." tests) are where in-process interpretation, and so the bats trap, weighs most. The ~2.5 groups (orca, plain, tmux, pane_state) are fixture plus fake-binary spawns.

## Proposals

### 1. Count the herdr retry pauses instead of sleeping them (tests 142, 148; test-only)

- **What to change:**
  - In test 148, after `agmsg_terminal_load herdr` (L3151), add a shadowing stub: `sleep() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/slept"; }`.
  - After the never-recovers assertions (L3184-3185), add `[ "$(grep -c '^0.1$' "$BATS_TEST_TMPDIR/slept")" -eq 57 ]`. The 57 is 3 + 3 + 1 + 50.
  - In test 142, define the same stub right before the `HERDR_AGENT_GET_FAIL=1` run (L2981), and assert 50 pauses after it.
- **Why it works:**
  - The herdr driver is sourced into the test shell (`agmsg_terminal_load`), so its `sleep 0.1 2>/dev/null || true` (ops.sh:1404, :1474) resolves to the function.
  - bats runs each test in its own process, so the stub cannot leak into another test.
  - Neither test asserts wall time; both assert call counts (4, 4, 2/1, 51, 1 in 148). The retry's progress is driven by the fake's counter files, not by time, so behaviour is identical.
- **What it adds:** today nothing pins that the retry pauses at all. Deleting the `sleep` from ops.sh would keep every test green. The new count assertion pins it.
- **Measured locally:** test 148 went from 7.9 s to 2.3 s (bats startup subtracted) with the stub and the 57-pause assertion, and passes.
- **Tests:** 142, 148.
- **Estimate: ~11.5 s macOS / ~10.9 s ubuntu.**
  - Fixed sleep removed: 5.0 s (142) + 5.7 s (148) on both OSes.
  - Plus 107 `sleep` execs: ~7 ms each on macOS, ~2 ms on ubuntu.
- **test_only:** yes. **Coverage risk:** none; coverage goes up.

### 2. Keep the bats DEBUG trap out of the sandbox's library frames (test-only, one line)

- **What to change:** at the end of `setup()` (after L37), add:

  ```bash
  declare -F bats_add_debug_exclude_path >/dev/null && bats_add_debug_exclude_path "$TEST_SKILL_DIR/"
  ```

  On macOS, also add the `pwd -P` form of the directory.
- **A stronger variant** is the guarded trap `trap '[[ "${BASH_SOURCE-}" == "$TEST_SKILL_DIR"/* ]] || bats_debug_trap "$BASH_SOURCE"' DEBUG`, which is the one measured below. On `test_self_name.bats` the exclusion function achieved ~80% of the guarded trap's saving.
- **Why it is safe:**
  - The code under test is unchanged.
  - Stack traces for the test file's own lines are kept. A test that failed in both variants (178, locally) was reported at the same assertion line with and without the guard.
- **What does not work:** setting `BATS_DEBUG_EXCLUDE_PATHS` from the environment, because bats 1.13 resets the array before reading the variable.
- **Measured locally (guarded variant, wall time minus ~1.0 s bats startup):**

  | tests | before (s) | after (s) | change |
  |---|---|---|---|
  | test 174 | 3.4 | 1.2 | −65% |
  | 9 placement-guard tests | 16.4 | 13.1 | −20% |
  | 9 orca input_draft tests | 3.5 | 3.2 | −10% |

- **Tests:** all; mostly the interpreter-heavy ones (174, 142, 148's non-sleep part, 6, 5, 44, 120, 179, 178, and the self-identity / terminal_name_self / placement / #1044 groups).
- **Estimate: ~18 s macOS / ~14 s ubuntu.**
  - Basis: −20% on the tests with ratio ≤ 1.8 (about 45% of ubuntu time), −8% on the rest: ~13% of 108 s.
  - macOS is discounted ×0.7: interpretation costs ~1.6× there against ~3× for spawns, so the trap is a smaller share. That gives ~9% of 204 s.
- **test_only:** yes. **Coverage risk:** none. Diagnosability is unchanged.

### 3. Copy an initialised fixture instead of re-running `init-db.sh` + chmod per test (test-only, shared helper)

- **What to change:**
  - Give `setup_test_env` (test_helper.bash:42-116) an opt-in cache: build `scripts/` + chmod + `init-db.sh` once per file into `$BATS_FILE_TMPDIR/fixture`, from `setup_file`.
  - On every call, `cp -Rp` that directory into the fresh `mktemp -d`, then do the `HOME`/`TMPDIR` steps as today.
- **Why it is safe:**
  - Each test still gets a private copy. This file writes into its copy (`scripts/drivers/terminals/stubby` in test 150, `plugins/terminals/probe`, records), so sharing one tree, for example through a symlink, would not be safe; a copy is.
  - The DB `init-db.sh` creates is path-independent (schema only, WAL checkpointed on exit).
- **Tests:** all 211.
- **Estimate: ~17 s macOS / ~8 s ubuntu.**
  - Basis: locally `init-db.sh` + chmod are ~39 of the 68 ms in a setup+teardown (task brief). Scaled to CI's 0.2 / 0.1 s per setup+teardown, that is ~0.08 / ~0.04 s per test, × 211.
  - The same change would save ~2 / ~1 s in `test_self_name.bats` and helps every one of the 107 files that use `setup_test_env`.
- **test_only:** yes. **Coverage risk:** low. It is a fixture-construction change, and `test_self_name.bats` test 18 already guards the environment `setup_test_env` must produce.

### 4. Pin `AGMSG_AGENT_PID=""` in `setup()` (test-only)

- **What to change:** add `export AGMSG_AGENT_PID=""` in `setup()`.
- **What it removes:** the `ps` walk in the 4 `join.sh` and 2 `actas-claim.sh` runs of tests 135-138 (`agmsg_resolve_project` → `agmsg_agent_pid`, `resolve-project.sh:489-531`).
- **Why it changes no result:**
  - On CI the walk reaches pid 1 without finding an agent, which is the same branch the empty pin takes. That includes the owner-token derivation `actas-claim.sh` does through `instance-id.sh`.
  - Locally, under Claude Code, the walk does find the `claude` process. The pin makes local runs match CI.
- **Tests:** 135-138.
- **Estimate: ~4 s macOS / ~3 s ubuntu.** Basis: 6 walks × ~0.65 / ~0.52 s, from the fixture decomposition in `test_remote.md`. The exec-count lower bound is ~2 / ~0.8.
- **test_only:** yes. **Coverage risk:** none. No test here asserts project resolution.

## Risks and notes

- **Not proposed: an env knob that shrinks herdr's retry budget.**
  - After #1, the never-recovers case still runs 51 fake-herdr round trips (~1.5-2.5 s macOS, ~0.5 s ubuntu).
  - A knob in the style of `AGMSG_TEST_SYNC_START_READY_CEILING` (`remote.sh:3194-3233`) could cut that to a handful.
  - But the herdr driver states a policy against env-controlled bounds (ops.sh:568-571, "The bound is FIXED, not an env surface"), and test 148 deliberately pins the production count (51).
- **Totals are mostly additive.** #1 removes sleep time, which #2 does not touch. #2 and #3 overlap only through the fixture's `init-db.sh`, which runs as a subprocess and is untouched by the trap. All four come to about **~50 s macOS / ~36 s ubuntu**, about 25% / 33% of the file.
- **Two smaller fixed waits** could take the same counting stub; each costs 0.3 s or less per run, so they are listed rather than proposed:
  - `sleep 0.3` in tmux poke (`tmux/ops.sh:562`, test 31)
  - `sleep 0.1` in plain spawn (`plain/ops.sh:227`, tests 102-104)
- **Production cross-reference:** making the registry readers fork-free (`test_self_name.md` proposal 5) would also cut this file's in-process time. I have no per-test fork counts for this file, so I give no estimate.
- **Test 1 carries file startup.** Its 1.5 / 0.7 s includes ~1.1 / ~0.5 s of bats preprocessing this 4,879-line file. Splitting the file would not remove that; it would be paid once per file.
- **Shard balance:** this file sat on macOS shard 5 (1177 s), not the critical shard 3 (1382 s). The proposals reduce total CPU; the critical path improves once `.github/scripts/bats-file-seconds.tsv` (checked-in weight 200 s) is refreshed.
