# test_spawn.bats: where the CI time goes

Data: CI run 41607512279 (main @ 64723d6), `per-test-41607512279.tsv`, macOS shard 4 and ubuntu shard 4. Code read at main @ 551764e. Local checks on Linux (bash 5.2, loaded box): strace fork/exec counts, a micro-benchmark, and 5 single tests run from a scratch copy of the file. Paths below are repo-relative; `Lnnn` means `tests/test_spawn.bats:nnn`.

## Summary

- **653 s macOS / 270 s ubuntu** for 122 tests. This is the second-heaviest file on macOS after test_install.bats, and about 54% of an average 6-shard macOS budget (~1200 s). The median test takes 4.7 s on macOS and 1.8 s on ubuntu.
- The time is spread evenly across the file. Nearly every test pays the same ~4 s macOS / ~1.7 s ubuntu for three things: the per-test fixture, one arrange `join.sh` and one `spawn.sh` run. Measured with strace, an arrange join costs about 330 forks / 157 execs locally. In CI it is closer to ~430 / ~210, because `agmsg_agent_pid` finds no agent ancestor and walks to pid 1: 11 hops on the macOS runner and 10 on ubuntu, with 3 `ps` calls per hop. A `spawn.sh --no-wait` run costs about 760 forks / 300 execs, including spawn's own internal join. The macOS/ubuntu ratio on these tests is 2.3-3x. That points at fork/exec cost, not at waiting.
- Outliers:
  - #47 (21.7 s / 26.3 s) is a fork loop over /usr/bin and /bin.
  - #89 and #118 repeat the arrange join on every loop iteration.
  - #86 waits out the herdr NOT-READY bound. That bound is fixed by design.
  - #113 runs the herdr naming budget, also fixed by design, with exact counts asserted.
  - #104 runs a nested bats.
  - Six readiness tests let a 1-2 s timeout elapse.
- **Test-only proposals P1-P6 save about 185 s macOS / 100 s ubuntu (28% / 37%) without changing any assertion.** That leaves roughly 470 s / 170 s. An optional shared-fixture step (P7) saves another ~55 s / 17 s. Two product changes help this file and every caller of spawn.sh: P8 saves ~38 s / 19 s and P9 roughly 30 s / 12 s.

Rough split of the 650 s macOS (the ubuntu figures are in parentheses):
- About 123 arrange joins × ~1.4 s ≈ 172 s (×0.65 ≈ 79 s).
- About 128 spawn.sh runs ≈ 240 s (≈ 100 s). Of that, ~38 s (19 s) builds an error-message string that is never printed.
- The fixture: 122 × ~0.7 s ≈ 85 s (×0.18 ≈ 22 s).
- #47's loop ≈ 17 s (24 s).
- Fixed bounds in #86 and #113 ≈ 25 s (11 s): each test's time minus ~4.2 s (1.75 s) for F + J + S.
- Readiness timeouts: 7 s (7 s).
- Six end-to-end codex boot runs ≈ 15 s (7 s).

## Where the time goes

Driver legend (each row lists its components):

- **F**: per-test fixture. `setup_test_env` (test_helper.bash:42-116: `cp -R` of 257 files, init-db), 10 stub files with one `chmod` exec each (L13-16, L23), and a teardown that **always** runs `_reap_test_skill_dir_procs` (L47). That call is one full `ps -eo pid=,args=` + awk (test_helper.bash:159). Basis for its cost: #3, which dies at the name check, takes 0.83 s macOS / 0.22 s ubuntu including spawn.sh's library sourcing.
- **J**: one arrange `bash "$SCRIPTS/join.sh" <team> existing <type> "$PROJ"`. That call reaches `agmsg_resolve_project` (scripts/join.sh:93) and then `agmsg_agent_pid`, which walks up to 20 parent hops (scripts/lib/resolve-project.sh:526) with `compat_get_ppid` + `compat_get_comm` + `compat_get_cmdline` = 3 `ps` per hop. Cost about **1.4 s macOS / 0.65 s ubuntu**. Basis: #6/#7 (join + spawn failing early: 2.78/2.92 s macOS, 1.14/1.14 s ubuntu) against #8/#30 (no join: 1.35/1.47 s, 0.47/0.47 s).
- **S**: one `spawn.sh` run. It includes spawn's internal `join.sh` (spawn.sh:431, with `AGMSG_RESOLVE_PROJECT=0`, so no walk), the eager `SUPPORTED_LIST` (spawn.sh:132), the boot script write, the terminal launch and the placement record. A full `--no-wait` run costs about 2.0 s macOS / 0.85 s ubuntu: #12 (4.18 s / 1.74 s) minus F and J.
- **H**: herdr fake (`_setup_fake_herdr`, L1177). Every herdr call is a bash stub exec. Each process-info probe also costs a `sed` and 2 `sqlite3` calls in the driver (scripts/drivers/terminals/herdr/ops.sh:503-511).
- **D**: an extra `delivery.sh set|status` call.
- **T1/T2**: a readiness wait that must elapse. It is a `sleep 1` per tick (spawn.sh:1065-1071) with `--ready-timeout 1` or `2`.
- **B**: the boot script runs end to end: codex-shim.sh, then codex-monitor, then the fake `codex app-server` (bash plus a python listener, L1842-1882). The test pays the boot run itself and the reap in teardown.

The table covers the tests that make up the first 70% of the file's macOS time. Every test over 5 s falls inside that set.

| # | title | macOS s | ubuntu s | mac/ubu | cum. macOS % | driver |
|---:|---|---:|---:|---:|---:|---|
| 47 | spawn: errors when $TMUX is set but tmux is not on PATH | 21.65 | 26.25 | 0.82 | 3.3 | **L**: per-file `$(basename)` + `ln -s` over /usr/bin and /bin (L669-677), ~2-5k fork/exec; + F J S. Equal on both OSes = loop, not timing |
| 86 | spawn req1: a NOT-READY pane (foreground process running) is not typed — fail with reason, p... | 18.80 | 7.72 | 2.44 | 6.2 | **H50**: fixed NOT-READY bound, 50 x (process-info probe + `sleep 0.1`) (herdr/ops.sh:576); + F J H S |
| 89 | spawn req1: a numeric-STRING pid is UNKNOWN on BOTH arms and either field (json_type must be... | 16.57 | 6.63 | 2.50 | 8.8 | 4 x (J + H S): arrange join sits inside the 4-response loop (L1495); 3 re-joins are redundant |
| 113 | spawn-side naming: herdr bounds a persistent agent_not_found and reports unnamed (#1100) | 14.94 | 6.82 | 2.19 | 11.1 | **N50**: herdr naming budget: 51 `agent get` + 48 `agent rename` stub execs (each runs `grep -c` on the call log) + 50 stub-`sleep` execs; counts asserted exactly; + F J S |
| 118 | spawn-side naming: EVERY driver non-value key prefix reads back as NOT named (seam with #106... | 13.57 | 6.38 | 2.13 | 13.2 | 4 x (J + S): one join per non-value prefix + mutation guard (L2224, L2236) |
| 104 | spawn: a test that fails after the launch leaves no fake app-server behind (teardown reap) | 10.74 | 4.80 | 2.24 | 14.8 | nested `bats -f` re-run of #103 (L1780; re-parses the 2.3k-line file) = J D S B + reap check |
| 85 | spawn: herdr split fails closed on a malformed or unusable response | 9.90 | 3.33 | 2.97 | 16.3 | J + 3 x H S (each spawn fails at placement) |
| 58 | spawn: readiness handshake times out (status=timeout, exit 3) when nothing attaches | 9.39 | 4.50 | 2.09 | 17.8 | J + D + S + **T2** (`--ready-timeout 2`, L857) |
| 61 | spawn: an unrecognized delivery status from the real command keeps the wait fail-closed (#647) | 8.57 | 3.00 | 2.86 | 19.1 | J + D (real `delivery.sh status`) + S + **T1** (L900) |
| 22 | spawn: codex boots fresh when no rollout backs the record (#339) | 8.37 | 1.92 | 4.37 | 20.4 | J + role-session seed + S (codex); 4.4x ratio vs #21 (same shape, 4.7 s): macOS runner noise |
| 23 | spawn: forwards CODEX_HOME across a terminal environment boundary (#1436) | 8.25 | 2.63 | 3.14 | 21.6 | J + 2 x S + 2 boot-script runs (stub shell) |
| 48 | spawn: codex spawns the codex CLI | 8.12 | 1.84 | 4.42 | 22.9 | J + S (codex, readiness skipped); outlier vs #50/#53 (same commands, ~5 s) |
| 55 | spawn: macOS terminal launch does not steal focus (Terminal and iTerm) | 7.82 | 0.19 (skip) | n/a | 24.1 | macOS only: 2 x J + 2 x S through launch_macos_terminal (`open` stub) |
| 62 | spawn: unrecognized delivery status keeps the readiness wait fail-closed (#647) | 7.72 | 2.75 | 2.81 | 25.3 | J + fake delivery.sh + S + **T1** (L917) |
| 57 | spawn: readiness handshake returns status=ready when the watcher attaches | 7.57 | 3.23 | 2.34 | 26.5 | 2 x J (existing + alice) + D + S (sentinel touched at launch, no wait) |
| 59 | spawn: a monitor-capable type skips readiness when project delivery is off (#647) | 7.45 | 2.05 | 3.63 | 27.6 | J + D (`set off`) + S (skip path, the `--ready-timeout 2` never elapses) |
| 108 | spawn: inherited resolution overrides (real binary, monitor, launcher) do not steer a spawne... | 7.32 | 3.02 | 2.42 | 28.7 | J + D + S + **B** |
| 71 | spawn: a CONFIRMED start (handshake) is the only path that proves startup (status=ready) | 7.08 | 2.53 | 2.80 | 29.8 | 2 x J (existing + alice) + S (ready at launch) |
| 103 | spawn: a spawned codex reaches the real binary WITH --remote (argv read from the boot script... | 7.04 | 3.03 | 2.33 | 30.9 | J + D + S + **B** |
| 75 | spawn: launch_in_tmux runs the boot script via bash -l on Windows (#335) | 7.03 | 2.46 | 2.87 | 32.0 | J + 2 x S (tmux + uname stubs) |
| 51 | spawn: claude-code boot prompt keeps the / slash prefix (#283) | 6.87 | 1.71 | 4.02 | 33.0 | F J S |
| 60 | spawn: a failed delivery status keeps the readiness wait fail-closed (#647) | 6.77 | 2.72 | 2.49 | 34.1 | J + fake delivery.sh + S + **T1** (L887) |
| 84 | spawn: herdr --window reads root_pane.pane_id past a nested object | 6.70 | 2.04 | 3.28 | 35.1 | F J H S |
| 110 | spawn: a shim-stack control variable that does not exist yet is still cleared (namespace, no... | 6.65 | 3.04 | 2.19 | 36.1 | J + D + S + **B** (+ env dump) |
| 63 | spawn: a known delivery prefix with a suffix remains unrecognized (#647) | 6.60 | 2.74 | 2.41 | 37.1 | J + fake delivery.sh + S + **T1** (L934) |
| 31 | spawn: no --model leaves the launch flag-free | 6.46 | 1.71 | 3.77 | 38.1 | F J S |
| 83 | spawn: herdr split tolerates reordered keys in the pane object | 6.44 | 2.14 | 3.01 | 39.1 | F J H S |
| 107 | spawn: an inherited PATH-wrapper install (AGMSG_CODEX_SHIM_WRAPPER/SCRIPT_DIR) cannot repoin... | 6.42 | 3.19 | 2.01 | 40.1 | J + D + S + **B** |
| 106 | spawn: an inherited AGMSG_CODEX_SHIM_DISABLE=1 does not make a spawned codex seat bypass the... | 6.41 | 3.02 | 2.12 | 41.1 | J + D + S + **B** |
| 105 | spawn: a codex seat spawned FROM a bridged codex seat still reaches the real binary WITH --r... | 6.38 | 3.09 | 2.07 | 42.1 | J + D + S + **B** |
| 73 | spawn: --boot-prompt "" is treated as no task (no-op, not an error) | 6.31 | 1.69 | 3.73 | 43.1 | F J S |
| 64 | spawn: a suffixed explicit off status does not skip readiness (#647) | 6.09 | 2.72 | 2.24 | 44.0 | J + fake delivery.sh + S + **T1** (L951) |
| 82 | spawn: herdr split picks result.pane.pane_id even when another pane object follows it | 6.09 | 1.95 | 3.13 | 44.9 | F J H S |
| 43 | spawn: falls back to ~/.agmsg/config/spawn_options.yaml when the env var is unset | 5.85 | 1.71 | 3.42 | 45.8 | F J S (+ HOME spawn-options file) |
| 78 | spawn: herdr split --split v maps to --direction down | 5.62 | 1.85 | 3.04 | 46.7 | F J H S |
| 81 | spawn: tmux takes priority over herdr (backward compat for tmux-inside-herdr) | 5.55 | 1.67 | 3.32 | 47.5 | F J S (tmux stub + herdr env) |
| 45 | spawn: --boot-prompt appends an initial task to the actas prompt | 5.39 | 1.72 | 3.14 | 48.4 | F J S |
| 11 | spawn: --team disambiguates a multi-team project | 5.38 | 2.49 | 2.16 | 49.2 | 2 x J + S + identities.sh |
| 24 | spawn: boot script unsets the type's session-identity vars (#294) | 5.34 | 1.73 | 3.10 | 50.0 | F J S |
| 36 | spawn: opencode launches opencode with --prompt (not a bare positional) | 5.32 | 1.76 | 3.02 | 50.8 | F J S |
| 69 | spawn: a no-handshake type (readiness_sentinel=no) reports startup UNCONFIRMED, not a bare s... | 5.31 | 1.70 | 3.12 | 51.7 | F J S (codex, no-handshake) |
| 77 | spawn: herdr split — launches in a herdr pane with herdr: placement record | 5.30 | 1.98 | 2.68 | 52.5 | F J H S |
| 50 | spawn: codex boot prompt uses the $ skill prefix, not / (#283) | 5.21 | 1.85 | 2.82 | 53.3 | F J S (codex) |
| 25 | spawn: does NOT unset a type's credential/detect vars (#294) | 5.18 | 1.72 | 3.02 | 54.1 | F J S (gemini) |
| 79 | spawn: herdr --window uses tab create and extracts root_pane pane_id | 5.16 | 1.94 | 2.66 | 54.9 | F J H S (`--window`) |
| 38 | spawn: injects spawn-options flags from AGMSG_SPAWN_OPTIONS_FILE | 5.13 | 1.74 | 2.94 | 55.6 | F J S (+ spawn-options YAML) |
| 112 | spawn-side naming: herdr retries agent_not_found until detection then confirms the key (#1100) | 5.08 | 2.04 | 2.49 | 56.4 | F J H S (2 real 0.1 s retries replaced by stub sleep) |
| 70 | spawn: --no-wait says 'launched' (never 'spawned'), and its unconfirmed NOTE differs from re... | 5.07 | 1.68 | 3.01 | 57.2 | F J S |
| 80 | spawn: herdr --window falls back to split when HERDR_WORKSPACE_ID is unset | 5.07 | 1.85 | 2.74 | 58.0 | F J H S |
| 28 | spawn --model: codex launch uses its -m model flag | 5.00 | 1.72 | 2.90 | 58.8 | F J S |
| 33 | spawn: gemini launches gemini with a bare positional prompt | 5.00 | 1.81 | 2.76 | 59.5 | F J S |
| 74 | spawn: --boot-prompt folds the initial task into the boot prompt (codex) | 4.97 | 1.78 | 2.79 | 60.3 | F J S (codex) |
| 41 | spawn: only the spawned type's section applies, not another type's | 4.92 | 1.72 | 2.86 | 61.0 | F J S |
| 29 | spawn --model: grok-build launch uses its --model flag | 4.90 | 1.70 | 2.89 | 61.8 | F J S |
| 26 | spawn: grok-build launches the plain grok CLI with the actas prompt | 4.84 | 1.72 | 2.82 | 62.5 | F J S |
| 35 | spawn: copilot launches copilot with --interactive (not a bare positional) | 4.84 | 1.72 | 2.81 | 63.3 | F J S |
| 46 | spawn: without --boot-prompt the boot script carries no extra task text | 4.83 | 1.73 | 2.80 | 64.0 | F J S |
| 27 | spawn --model: claude-code launch includes its --model flag + id | 4.83 | 1.70 | 2.85 | 64.8 | F J S |
| 44 | spawn: actas prompt uses the install command name (not hardcoded agmsg) | 4.82 | 1.74 | 2.78 | 65.5 | F + `cp -R` of the whole skill dir + J + S |
| 9 | spawn: errors when the project belongs to multiple teams without --team | 4.77 | 1.96 | 2.43 | 66.3 | F + 2 x J + S (fails at team resolution) |
| 18 | spawn: falls back to fresh when the record's transcript is gone (#339) | 4.75 | 1.87 | 2.53 | 67.0 | J + role-session seed + S |
| 20 | spawn: a type without resume_arg never resumes (#339) | 4.72 | 2.00 | 2.36 | 67.7 | J + role-session seed + S (gemini) |
| 34 | spawn: antigravity launches agy with --prompt-interactive (not a bare positional) | 4.72 | 1.73 | 2.72 | 68.4 | F J S |
| 21 | spawn: codex resumes via the 'resume' subcommand right after the cli (#339) | 4.71 | 1.95 | 2.41 | 69.2 | J + role-session seed + S (codex) |
| 40 | spawn: a false spawn-options value suppresses that flag | 4.70 | 1.74 | 2.71 | 69.9 | F J S |
| 32 | spawn: cursor launches cursor-agent with a bare positional prompt | 4.67 | 1.82 | 2.56 | 70.6 | F J S |

Notes on the table:
- #22 and #48 run 4.4x slower on macOS than ubuntu. Tests with the same shape run ~2.5x (#21 at 4.7 s, #50 at 5.2 s, #53 at 4.4 s), so these two are runner noise, not a cost of their own. The hang sampler runs `ps -ef` + `lsof` every 30 s on the same 3-core macOS runner.
- #55 is skipped on ubuntu. It exercises `launch_macos_terminal`.

## Proposals

Savings are per full CI run, i.e. one macOS leg plus one ubuntu leg. They are computed independently. Where two proposals overlap, the note says so.

### P1. #47: build the tmux-less PATH with one `ln` per directory (L669-677)

- **Change.** The loop forks `$(basename "$f")` and execs `ln -s` once per entry of /usr/bin and /bin. On merged-usr ubuntu it visits every name twice. Replace it with:

  ```bash
  local d
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    ln -s "$d"/* "$notmux"/ 2>/dev/null || true   # first dir wins on duplicates, as the [ -e ] check did
  done
  rm -f "$notmux/tmux"
  ```

  GNU and BSD `ln` both continue past "File exists" when given several sources. The argv is 1-2.5k names, about 50 KB, well under ARG_MAX (macOS 1 MB, Linux 2 MB).
- **Tests:** #47.
- **Savings:** **≈ 17.5 s macOS, ≈ 24.5 s ubuntu.**
  - Basis: #47 takes 21.65 s / 26.25 s; a comparable join + spawn test (#12, 4.18 s / 1.74 s, less its `identities.sh`) takes ≈ 4.0 s / 1.7 s.
  - Local check: the loop took 7.36 s, the per-dir `ln` 0.03 s, and both produced the same 1160 links (diff empty). The whole test dropped from 14.4 s to 2.55 s with the replacement.
- **test_only:** yes. **Coverage risk: none.** The PATH contents are the same, and the asserted message (`tmux binary is not on PATH`) comes from the same branch.

### P2. Drop arrange joins that only make team auto-resolution succeed; pass `--team` instead

- **Change.** In the tests below, delete `bash "$SCRIPTS/join.sh" <team> existing <type> "$PROJ"` and add `--team <team>` (the same team name the join used) to each `spawn.sh` call in the test. Spawn's own pre-join (spawn.sh:431) creates the team when it does not exist yet.
  - #6, #7 and #99: the join is dead today, so delete the line and nothing else. #6/#7 fail at the CLI check (spawn.sh:243) before `resolve_team` (spawn.sh:345). #99 never spawns.
  - #89: move the in-loop re-join (L1495) out of the loop, i.e. drop it and pass `--team myteam`.
  - #118: drop both joins (L2224, L2236) and pass `--team seamteam`; spawn's internal join registers each `seamN` name anyway.
  - #55: drop both joins.
  - #57/#71: drop only the `existing` join. Keep `join myteam alice`, because `_ready_path` needs alice's member id before the spawn.
- **Tests (86 with one join removed):** 6, 7, 12-15, 19, 23-29, 31-48, 50-54, 58-70, 73-94, 96-102, 111-117. **Extra joins removed:** #89 +3 (its single join line runs 4 times), #118 4, #55 2 (macOS only), #57 1, #71 1. Total: 97 macOS / 95 ubuntu.
- **Kept on purpose:**
  - #9, #10, #11: team resolution is what they test.
  - #16-18 and #20-22: they seed a role-session record against the team. The record path is name-keyed (role-session.sh:71-84), so these could probably go too, but they are excluded conservatively.
  - #56: the member id feeds the lock path.
  - #119, #120: the ready path needs the member id.
  - #121: caller-pane scenario.
  - #122: the subject is join itself.
  - #103, #105-108, #110: their boot run goes through codex-monitor with whatever identities the project has. Excluded until verified; P4 still applies to them.
- **Evidence.**
  - Strace, fresh sandbox: arrange join + auto-resolved spawn costs 333 + 760 forks and 157 + 302 execs. `spawn.sh ... --team myteam` alone costs 767 forks / 311 execs.
  - The two boot scripts are identical modulo temp-dir names.
  - Locally, #13 dropped from 2.60 s to 1.42 s and #31 from 1.93 s to 1.38 s, with all assertions passing.
- **Savings:** joins removed = 97 macOS / 95 ubuntu, × 1.4 s / 0.65 s (basis in legend **J**) = **≈ 136 s macOS, ≈ 62 s ubuntu.**
- **test_only:** yes. **Coverage risk: low.** The assertions are untouched. These tests stop exercising single-candidate auto-resolution as a side effect, but #10, #16-18, #20-22, #56, #57, #71 and #119-121 still auto-resolve, and #9/#11 cover the multi-team case. Boot-script content, placement and naming do not depend on how the team was chosen; the boot-script diff confirms this.

### P3. Readiness tests: shorten waits that do not need to elapse

- **Change.**
  - #60-64: change `--ready-timeout 1` to `--ready-timeout 0` (L887, L900, L917, L934, L951). The validation at spawn.sh:183 accepts 0. The loop at spawn.sh:1065-1071 is still entered, and it reports `status=timeout ... after=0s` with exit 3 at once. Checked locally with a failing delivery.sh: the "keeping readiness wait" message, `status=timeout` and rc=3 all appear.
  - #58: change `--ready-timeout 2` to `1` (L857), so one test still observes a real elapsed tick.
- **Tests:** #58, #60, #61, #62, #63, #64.
- **Savings:** **≈ 6 s macOS, ≈ 6 s ubuntu** (5 × 1 s + 1 s; the timeout is `sleep 1` per tick, identical on both OSes).
- **test_only:** yes. **Coverage risk: low.** These tests (#647) prove the wait is *not skipped*: `status=timeout` with exit 3, against `launched-unconfirmed` / `note=no-monitor-delivery`. That distinction survives a 0 s budget. If 0 were ever rejected, the tests would fail loudly, not pass vacuously.

### P4. Pin `AGMSG_AGENT_PID=""` for the arrange joins that remain

- **Change.** Run the arrange joins with an empty `AGMSG_AGENT_PID`, either with `export AGMSG_AGENT_PID=""` in `setup()` or through a one-line `_arrange_join` helper. The hook exists so tests do not depend on the ambient process tree (resolve-project.sh:483-488), and 14 files already export it in setup (e.g. test_delivery.bats:10, test_actas_integration.bats:19, test_install.bats:23). In CI the walk returns empty anyway, so the outcome is identical. Locally it stops the walk from landing on the developer's own claude/codex process.
- **Evidence.**
  - CI tree depth, from the sampler's ps listings: join.sh → bats-exec-test → … → hosted-compute-agent → 1 is 11 hops on macOS and 10 on ubuntu.
  - Local strace (codex join, 7-hop tree): 362 → 240 forks, 180 → 127 execs, 21 → 0 `ps`.
  - Scaled to 11 hops, the walk is ~44% of a CI join's forks and ~40% of its execs, i.e. ~0.6 s macOS / ~0.28 s ubuntu per join.
- **Tests:** with P2, the remaining joins: #9 ×2, #10, #11 ×2, #16-18, #20-22, #56, #57, #71, #119-122 (#122 ×2), and #103, #105-108, #110. That is ≈ 25 joins.
- **Savings:** with P2, **≈ 15 s macOS / ≈ 7 s ubuntu**. Without P2, ≈ 123 joins × 0.6 s / 0.28 s ≈ 74 s / 34 s.
- **test_only:** yes. **Coverage risk: low.** Prefer scoping it to the arrange joins. Exported file-wide, it would also reach the boot runs of #103-110. That is harmless in CI, where the walk finds no codex ancestor, but needlessly broad.

### P5. Teardown: reap only when the test started the fake codex stack

- **Change.** Set a flag in `_install_fake_codex_bridge_stack` (L1842) and call `_reap_test_skill_dir_procs` in teardown (L47) only when it is set. When the rm fails, `teardown_test_env` already reaps on its own (test_helper.bash:238-258). Today the reap's full `ps -eo pid=,args=` + awk runs in all 122 tests, but only #103, #105-108, #110 (and #104's inner run of #103) start detached processes.
- **Savings:** ~116 skipped scans × ~0.05 s macOS / ~0.01 s ubuntu ≈ **6 s / 1 s**. Basis: the sampler shows ~490 processes on the macOS runner against ~50 on ubuntu. The per-scan cost was not measured, so read this as ±50%.
- **test_only:** yes. **Coverage risk: low-medium.** The comment at L41-46 deliberately says "always", but the reason it gives is the fake app-server, and the flag still covers that. #104 keeps proving the reap end to end.

### P6. `setup()`: one `chmod` for all stubs

- **Change.** At L13-16 and L23, write the 10 stub files, then run `chmod +x "$STUB_BIN"/*` once instead of once per file.
- **Savings:** 9 execs × 122 tests ≈ 1100 process launches ≈ **4 s macOS / 1.3 s ubuntu**. Basis: ~3.5 ms / ~1.2 ms per fork+exec, derived from #12's ~1260 forks in 4.18 s / 1.74 s.
- **test_only:** yes. **Coverage risk: none.**

### P7. (Optional, second step) Run the shared spawn once for tests that only read its result

- **Change.** Move these tests to a companion file, e.g. `tests/test_spawn_boot_script.bats`, whose `setup_file` builds one fixture and runs each spawn once, saving the output, the boot-script path and the placement record. Each `@test` then only asserts against those files.
  - **G1:** #12, #13, #14, #19, #24, #31, #46, #51, #52, #54, #65, #70, #91, #98. All run exactly `spawn.sh claude-code alice --project "$PROJ" --no-wait` after the same join, then only read the boot script, the output or the placement record.
  - **G2:** #48, #50, #53, #66. All run `spawn.sh codex reviewer --project "$PROJ"` and only read.
- **Savings (incremental after P2):** **≈ 55 s macOS / ≈ 17 s ubuntu.** Basis: the 18 tests sum to 87.4 s / 31.4 s, less P2's 18 joins (25.2 s / 11.7 s), less the shared cost of 2 × (F + S) + 18 × ~0.08 s / ~0.03 s. This also splits the file, which helps shard balance. It overlaps P8 by ~5 s / 3 s, because 16 fewer spawn runs remain for P8 to speed up.
- **test_only:** yes. **Coverage risk: medium**, mostly about convention:
  - No file in this repo uses `setup_file`. The norm is a fresh `setup_test_env` per test.
  - The shared state must stay read-only.
  - One broken spawn would turn 14 tests red at once.
  - Test names and issue references can be kept unchanged.

### P8. (Product) Compute `SUPPORTED_LIST` only when an error message needs it

- **Change.** spawn.sh:132 runs `spawnable_types | paste | sed` on every invocation: ~20 `agmsg_type_get` calls plus known-types, sort, paste and sed. The result is read only by two `die` messages (spawn.sh:134, :139). Turn it into a function called from those two lines.
- **Savings.**
  - #2 against #3 isolates the cost: #2 dies just after line 132, #3 just before it. That gives 1.21 − 0.83 = 0.38 s macOS and 0.41 − 0.22 = 0.19 s ubuntu per run.
  - Part of that is `agmsg_is_known_type`, which stays, so take ~0.30 s / 0.15 s.
  - About 126 spawn.sh runs pass line 132 → **≈ 38 s macOS / ≈ 19 s ubuntu** in this file. Real spawns and other suites that spawn gain too.
- **test_only:** no. **Coverage risk: none.** #1 and #2 still get the same list in their error text.

### P9. (Product, larger) Fewer forks in the type registry

- **Change.**
  - `agmsg_known_types` and `_agmsg_type_warn_untrusted` run `name="$(basename "$dir")"` per type (scripts/lib/type-registry.sh:43, :80). That is 41 `basename` execs per spawn and 13 per join. `${dir%/}` followed by `${d##*/}` gives the same name with no fork.
  - `agmsg_type_get` (type-registry.sh:103-121) forks a subshell for `agmsg_type_dir` and a `grep | head` pipeline per key: 41 `grep` + 44 `head` per spawn. A `while IFS= read -r` key reader keeps the "never source a manifest" rule and needs no fork.
- **Savings:** rough, **≈ 30 s macOS / ≈ 12 s ubuntu** here, about 0.25 s / 0.1 s per join + spawn pair. Basis: these changes remove ~120 of ~1060 forks and ~100 of ~460 execs per pair. The suite-wide effect would be larger.
- **test_only:** no. **Coverage risk: medium.** The plugin/trust semantics must not change; see the caching caveat at resolve-project.sh:352-374. test_type_registry.bats covers the registry.

## Risks and notes

- **Not proposed: #86.** Its 50 × 0.1 s NOT-READY bound is deliberately not an env knob. herdr/ops.sh:568-574 argues that a knob could arrive empty or zero and silently skip the observation, and L1449 repeats this. Only P2 applies to it (saves its join). The ~14 s macOS / ~6 s ubuntu that remain are the bound itself. Each iteration is slower on macOS (2.4x) because the probe spawns a bash stub, `sed` and two `sqlite3`.
- **Not proposed: #113.** The exact counts (51 `agent get`, 48 `agent rename`, 50 sleeps) are the contract under test, and `sleep` is already stubbed. A micro-option: the fake herdr runs a `grep -c` over the whole call log on every `agent rename`/`agent get` (L1231, L1241); a counter file would avoid ~100 `grep` execs, ≈ 0.4 s macOS. Not worth the churn.
- **Not proposed: #104.** The nested `bats -f` (L1780) is the only way to observe a real failing test's teardown. It inherits P4's saving through its inner run of #103. P2 leaves #103 alone pending verification.
- **Not proposed: #85, #89 (after P2), #118 (after P2).** Their iterations over response shapes and prefixes are the point.
- **Convention check.** The comments that argue *for* waits or separations in this file are honoured: #86 bound, #113 counts, the #104 meta-test, and the one-assertion-per-line style in the codex tests. P7 is the only proposal that cuts against a convention (no `setup_file` anywhere in the repo), which is why it is optional.
- **macOS variance.** In this run, files on macOS shard 2 ran at a 1.0-1.2x macOS/ubuntu ratio and those on shard 3 at 2.7-3.2x, all on the same image, macos-26-arm64. So macOS seconds depend on which runner a file lands on. The macOS estimates above use this run's shard-4 numbers.
- **Shard balance.** Even after P1-P6, ~470 s of macOS time sits in one file, and `.github/scripts/bats-file-seconds.tsv` still lists 531 s for it. Refresh the table after the changes. Splitting the herdr/naming tests (#77-92, #111-121) into their own file gives the LPT partitioner finer grain, but saves no CPU time.
- **Fixture.** The `setup_test_env` cost itself (`cp -R` of 257 files + init-db) is a suite-wide topic and is not counted here.
