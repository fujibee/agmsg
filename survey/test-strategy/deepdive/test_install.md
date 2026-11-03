# tests/test_install.bats — where the CI time goes

Data: CI run 41607512279 (main @ 64723d6), `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/per-test-41607512279.tsv`. Code read at main @ 551764e. Since 64723d6 only `scripts/internal/install-baseline.mjs` changed among the files this suite runs. Local measurements: Linux, 4 cores, load ~5 (a background strace sweep was running), bash 5.2, bats 1.13.0. Local scripts and evidence are in `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/survey/deepdive/prof/`.

## Summary

- 118 tests, **762 s macOS / 237 s ubuntu**: the single heaviest file in the suite, about 10.6% of all macOS bats time.
- The file runs `install.sh` about **200 times** (about 130 fresh installs and 70 `--update`), plus 14 `uninstall.sh` runs.
  - A fresh install costs about **3.2 s on macOS and 0.95 s on ubuntu**. That comes from the 1-install tests 37, 41, 56, 59, 73, 86 and 96.
  - An `--update` costs about **3.9 s and 1.05 s**. That comes from the fresh + update tests 38, 39, 42, 43, 74, 75, 87, 91 and 92, at about 7.1 s and 2.0 s each.
  - So install runs are **about 90% of the file's time**.
- The macOS/ubuntu ratio is about 3.4 for nearly every test, which points at process spawning. Locally with strace, a fresh install is **674 forks and 318 execs**; an `--update` is **743 forks and 497 execs**, 256 of them `cmp`. The `update − fresh` difference (0.7 s macOS for about 180 more execs) puts a macOS exec at about 3.5 ms.
- Outliers on top of that:
  - Test 94: a fixture forces the per-file sha256 fallback, which costs 518 Perl `shasum` processes per update.
  - Test 97: 20 install runs in one test.
  - Test 22: a real agmsgd is started and stopped.
  - Test 32: a sync engine is started and restarted, plus a fixed `sleep 1`.
- **Biggest test-only lever:** run the plain default install once per file and copy it into each test's HOME. 53 tests start with exactly that install as arrange-only work, so this saves about **150 s macOS and 47 s ubuntu**.
- The other test-only changes below (marker templates, merging the upgrader tests, test 94's fixture, running test 97's types in parallel, test 32) add about 90 s macOS and 30 s ubuntu. All test-only changes together save **about 240 s macOS (−31%) and 77 s ubuntu (−32%)**.
- Three small changes to `install.sh` / `install-manifest.sh` would speed up every install run in every suite. In this file alone they save about 100 s macOS and 30 s ubuntu.

## Where the time goes

The table lists every test over 5 s macOS: 62 tests, 608 s, **79.8%** of the file. **[P1]** marks a test whose first statement is the plain default install, which proposal 1 can replace with a copy. "fresh" means one `install.sh` run without `--update`.

| # | title | macOS s | ubuntu s | ratio | driver |
|---|---|---|---|---|---|
| 97 | install: bare --update preserves every renderable type's SKILL.md fla... | 69.5 | 19.3 | 3.6 | 20 install.sh runs: per renderable type (10), fresh `--agent-type t` + bare `--update`, sequential, one HOME (L2129-2142) |
| 94 | install --update: moves removed/overwritten scripts/ files to .trash/... | 40.0 | 16.1 | 2.5 | fresh + 2 `--update`. The newline-named fixture (L2042-2046) stays in scripts/, so both updates fall back to per-file `agmsg_sha256`: 518 Perl `shasum` + 257 `cmp` per update. Locally 13.6-15.2 s per update vs 1.5 s for a normal one **[P1]** |
| 18 | uninstall: removes only the targeted install, leaving a second instal... | 20.7 | 7.1 | 2.9 | 4 installs (5 marker dirs + CODEX_HOME profile), 2 joins, delivery setup, 2 uninstalls; two scenarios in one test |
| 22 | install: --update starts an agmsgd that was turned on again, instead ... | 15.4 | 7.5 | 2.0 | fresh + `--update` that starts a real agmsgd (node) and waits for it to be ready (0.1 s poll), then `daemon.sh stop` (0.1 s poll) **[P1]** |
| 32 | install --update: replaces a running sync engine with one on the new ... | 15.0 | 5.7 | 2.6 | fresh + join + `remote.sh sync start` (fake engine) + `--update` that restarts it (the fake handles TERM only after its `sleep 1` ends, L784-789) + fixed `sleep 1` (L828) + status; teardown TERM + poll **[P1]** |
| 15 | install: Antigravity TUI shim replaces its symlink without writing th... | 13.5 | 2.2 | 6.1 | fresh + bare `--update` (symlinked shim). 6x ubuntu, while other 2-run tests are ~7 s: probably single-sample noise **[P1]** |
| 8 | install --update: an owned Codex shim is removed while agmsgd is on, ... | 12.7 | 4.1 | 3.1 | fresh + codex-shim-install + 2 `--update` (daemon intent on, then off) **[P1]** |
| 80 | install: --update --cmd DOES reclaim a Codex shim whose owner install... | 11.5 | 3.9 | 2.9 | 2 fresh (codex) + 2 shim installs + 2 `--update` **[P1]** |
| 107 | install writes a completion manifest, --update carries install_id and... | 11.2 | 3.2 | 3.5 | fresh + 3 `--update` (manifest gen / install_id) + sqlite reads |
| 112 | install cancellation waits for the active writer before clearing its ... | 11.1 | 3.5 | 3.2 | fresh + 2 fault-injected background `--update` (writer stub, 0.02 s polls) + uninstall + recovery `--update` |
| 13 | install: Antigravity TUI shim preserves foreign files and refreshes i... | 10.4 | 4.3 | 2.4 | fresh (`run`) + 2 bare `--update` + second install |
| 34 | install: AGMSG_STORAGE_PATH override works against the installed skill | 9.8 | 2.0 | 4.9 | fresh + 2 joins + send + inbox under AGMSG_STORAGE_PATH (`join.sh` is ~190 execs) **[P1]** |
| 79 | install: --update --cmd does NOT steal a Codex shim owned by another ... | 9.8 | 2.9 | 3.3 | 2 fresh (codex) + shim install + `--update` **[P1]** |
| 64 | install --update: adds missing Codex run writable_root for existing i... | 9.6 | 2.0 | 4.9 | pre-made ~/.codex/config.toml + fresh + `--update` |
| 9 | install --update: a Codex shim that cannot be put back is reported wi... | 9.5 | 3.6 | 2.6 | fresh + shim install + 2 `--update` **[P1]** |
| 113 | install cancellation before writer pid publication keeps the incomple... | 9.3 | 3.0 | 3.1 | fresh + 3 `--update` (one fault-injected in the background) + recovery |
| 26 | install --update: does NOT touch a user-added driver's own SKILL.md u... | 9.0 | 2.0 | 4.4 | fresh + `--update` with a user-added driver dir **[P1]** |
| 115 | uninstall preserves recovery through removal and cannot delete a late... | 8.9 | 2.9 | 3.1 | fresh + fault-injected background uninstall + `--update` + recovery uninstall + uninstall + reinstall |
| 62 | install/update/uninstall: CODEX_HOME isolates the default Codex confi... | 8.8 | 2.2 | 4.1 | CODEX_HOME profile: fresh + `--update` + uninstall |
| 21 | install: --update restores scripts/lib even if it went missing | 8.8 | 2.8 | 3.1 | fresh + 2 joins + rm scripts/lib + `--update` + send **[P1]** |
| 81 | install: AGMSG_CODEX_SHIM_FORCE=1 --update --cmd reclaims a Codex shi... | 8.7 | 2.9 | 3.0 | 2 fresh (codex) + shim + forced `--update` **[P1]** |
| 25 | install --update: removes a pre-rename drivers/terminals/{herdr,plain... | 8.6 | 2.1 | 4.2 | fresh + `--update` (pre-rename driver SKILL.md files) **[P1]** |
| 3 | install: --update refreshes an owned Antigravity TUI shim but prints ... | 8.5 | 2.3 | 3.8 | fresh + `--update` **[P1]** |
| 100 | install --update: clears group-write on a binding an older release le... | 8.2 | 2.4 | 3.5 | fresh + binding fixture + `--update` (#804) **[P1]** |
| 27 | install: --update --cmd updates the named skill even when a backup sk... | 8.1 | 1.9 | 4.2 | fresh + backup-shaped dir + `--update --cmd` **[P1]** |
| 42 | install --update: refreshes the OpenCode skill if it was previously i... | 8.1 | 2.0 | 4.0 | marker dir + fresh + tamper + `--update` |
| 19 | uninstall --all --yes: removes every install and the shared shim (#1400) | 8.0 | 2.7 | 3.0 | ~/.claude marker + 2 fresh + `uninstall --all` |
| 104 | install --update: corrects a binding under a dot-leading team name (#... | 8.0 | 2.1 | 3.8 | fresh + binding fixture + `--update` (#804) **[P1]** |
| 103 | install --update: does not follow a symlinked binding to something ou... | 7.8 | 2.2 | 3.5 | fresh + binding fixture + `--update` (#804) **[P1]** |
| 38 | install --update: refreshes the Copilot skill if it was previously in... | 7.8 | 2.0 | 3.9 | marker dir + fresh + tamper + `--update` |
| 7 | install --update: a failing Antigravity shim step warns once, and the... | 7.7 | 2.3 | 3.3 | fresh + shim install + `--update` through a failing `mv` stub **[P1]** |
| 74 | install --update: refreshes the Hermes skill if it was previously ins... | 7.7 | 2.0 | 3.8 | marker dir + fresh + tamper + `--update` |
| 24 | install: --update refreshes uninstall.sh even if it went missing | 7.6 | 2.0 | 3.7 | fresh + rm uninstall.sh + `--update` **[P1]** |
| 58 | install: --update refreshes the recorded VERSION | 7.5 | 1.9 | 3.9 | fresh + `--update` (VERSION) **[P1]** |
| 101 | install --update: leaves a binding the readers already accept alone (... | 7.5 | 2.3 | 3.3 | fresh + binding fixture + `--update` (#804) **[P1]** |
| 118 | install/update/uninstall: CHANGELOG is copied, refreshed, and removed... | 7.4 | 2.0 | 3.7 | CODEX_HOME profile: fresh + `--update` + `uninstall --keep-data` |
| 102 | install --update: clears other-write on a binding left 0646 (#804) | 7.3 | 2.3 | 3.2 | fresh + binding fixture + `--update` (#804) **[P1]** |
| 105 | install --update: does not touch or announce bindings on Windows (#804) | 7.3 | 2.3 | 3.2 | fresh + binding fixture + `--update` (#804) **[P1]** |
| 43 | install --update: installs OpenCode skill for upgraders without prior... | 7.3 | 2.1 | 3.5 | fresh + marker dir + bare `--update` **[P1]** |
| 31 | install: --update warns to re-register delivery hooks (#133) | 7.3 | 1.9 | 3.8 | fresh + `--update` (asserts the hook warning) **[P1]** |
| 45 | install --update: removes legacy Windows runner and sqlite shim | 7.2 | 2.0 | 3.6 | Windows-forced fresh + legacy files + `--update` |
| 39 | install --update: installs Copilot skill for upgraders without prior ... | 7.1 | 2.0 | 3.6 | fresh + marker dir + bare `--update` **[P1]** |
| 14 | install: a second install's Antigravity TUI shim left owned by the fi... | 7.0 | 2.1 | 3.3 | fresh + second install (`run`) **[P1]** |
| 1 | install: fresh install ships scripts/lib and the commands actually run | 7.0 | 2.7 | 2.6 | fresh + 2 joins + send + inbox (keep it as the in-test fresh-install smoke test) |
| 87 | install --update: installs Grok Build skill for upgraders without pri... | 7.0 | 2.0 | 3.5 | fresh + marker dir + bare `--update` **[P1]** |
| 76 | install: --update re-points an existing Codex monitor shim to the new... | 6.9 | 2.0 | 3.5 | fresh + shim install + `--update` **[P1]** |
| 75 | install --update: installs Hermes skill for upgraders without prior s... | 6.8 | 2.0 | 3.3 | fresh + marker dir + bare `--update` **[P1]** |
| 35 | install: actas-claim runs in a fresh shell with no inherited env | 6.7 | 2.4 | 2.8 | fresh + join + actas-claim under `env -i` **[P1]** |
| 57 | install: recorded VERSION uses the core tag lineage, not a co-located... | 6.5 | 1.5 | 4.2 | `cp -R` of the repo into a synthetic source + git init/tag + fresh install from it |
| 92 | install --update: refreshes the Antigravity skill | 6.5 | 2.0 | 3.2 | marker dir + fresh + tamper + `--update` |
| 28 | install: --update with no --cmd refuses to guess between two real ins... | 6.4 | 1.9 | 3.3 | 2 fresh + Windows-forced `--update` refusal **[P1]** |
| 77 | install: --update does NOT create a Codex shim when none was installed | 6.3 | 1.8 | 3.4 | fresh + `--update` **[P1]** |
| 91 | install --update: installs Antigravity skill for upgraders without pr... | 6.2 | 2.0 | 3.1 | fresh + marker dir + bare `--update` **[P1]** |
| 72 | install: --agent-type hermes gets its own dedicated file, shared SKIL... | 6.2 | 2.0 | 3.0 | ~/.hermes + fresh `--agent-type hermes` + second fresh `--agent-type gemini` |
| 83 | install: bare --update migrates this machine's own pre-#553 (owner-un... | 6.2 | 2.0 | 3.1 | fresh (codex) + legacy shim + bare `--update` **[P1]** |
| 78 | install: a second, differently-named install does NOT clobber the fir... | 5.8 | 1.8 | 3.2 | fresh (codex) + shim + second fresh install (`run`) **[P1]** |
| 111 | install stops before pruning when the lock child dies during scripts ... | 5.7 | 1.8 | 3.2 | fresh + fault-injected background `--update` (lock child killed) + 2 recovery uninstalls |
| 10 | install --update: with agmsgd off an owned Codex shim is refreshed as... | 5.6 | 2.2 | 2.6 | fresh + shim + `--update` **[P1]** |
| 84 | install: a second, differently-named FRESH install does NOT silently ... | 5.2 | 2.0 | 2.6 | fresh (codex) + legacy shim + second fresh install **[P1]** |
| 93 | install --update: removes the legacy top-level Antigravity resume helper | 5.2 | 1.9 | 2.7 | fresh + legacy file + bare `--update` **[P1]** |
| 90 | install: skips Antigravity skill when its markers are absent | 5.0 | 0.9 | 5.4 | fresh only (absence check). 5.4x ubuntu, while other 1-run tests are ~3.2 s: probably noise **[P1]** |
| 53 | install: watch.sh self-cleans a prior watcher on re-invocation for th... | 5.0 | 1.7 | 3.0 | fresh + 2 background watch.sh runs (0.1 s pidfile polls) + `_agmsg_kill_confirmed` **[P1]** |

The other 56 tests make up 154 s macOS. Most of them are one fresh install at 2.8-4.7 s. A few are pure renderer or manifest unit tests under 0.5 s (tests 4, 5, 47, 48, 50, 51, 63, 108, 109). Tests 12 and 16 run on Linux only; their first step is also the plain install.

Where an install run spends its time (local strace and xtrace, `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/survey/deepdive/prof/`):

- Every `--update` runs `cmp -s` once per shipped file in `agmsg_stage_overwrite_backups`: 256 execs (install.sh:232-247, cmp at :239).
- Every install, fresh or update, runs the prune membership check as a nested bash loop of about 21,000 iterations (install.sh:299-305, the inner `for s in "${shipped[@]}"` at :300).
- 78 `dirname` execs per fresh install. 53 of them come from libraries under the installed `scripts/lib/` being sourced with `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`.
- 44 `grep`, 34 `head` and 23 `sqlite3` execs.

## Proposals

Estimates are measured against today's baseline. Where proposals overlap, the combined saving is less than the sum; the notes say where.

### 1. Install the plain default once per file and copy it into each test (test-only)

- **What to change:**
  - Add `setup_file`. It applies the same `unset` and `export` lines as `setup()` (L10-27), creates `BASE_HOME="$(mktemp -d)"` with the same `mktemp` as `FAKE_HOME`, so the dirname and path length match and `_fake_home_is_scratch` (L173-180) still holds, then runs `HOME="$BASE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg` once and exports the path.
  - Add `teardown_file` to remove it.
  - Add a helper `_restore_default_install` that does the following, and use it in place of the first line of each [P1] test:
    1. `cp -Rp "$BASE_HOME/." "$FAKE_HOME/"`
    2. rewrite every file that `grep -rlF -- "$BASE_HOME" "$FAKE_HOME"` lists, with `sed "s|$BASE_HOME|$FAKE_HOME|g" f > tmp && cat tmp > f`. `cat` keeps the mode; the launcher is 0711.
    3. assert `refute grep -rqF -- "$BASE_HOME" "$FAKE_HOME"`. Use `refute`, not `! grep`: `.github/scripts/check-enforced-assertions.sh` rejects a non-final `!`.
- **Why the path rewrite is safe:** in a default install only three files hold the absolute HOME path: `~/.local/bin/agmsg`, `~/.agents/bin/agy-tui` and `run/agmsg-launcher.path`, all plain text with literal (not `pwd -P`) paths. `install.db` and the manifest hold none. If a future install writes the path anywhere else, the final `refute grep` fails loudly instead of letting the test silently use the template.
- **Tests (53 on macOS):** 3, 7, 8, 9, 10, 14, 15, 17, 21, 22, 23, 24, 25, 26, 27, 28, 29, 31, 32, 34, 35, 37, 39, 41, 43, 53, 56, 58, 59, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 86, 87, 90, 91, 93, 94, 98, 100, 101, 102, 103, 104, 105, 114. Ubuntu adds the Linux-only tests 12 and 16.
  - 37, 41 and 86 first `rm -rf` a marker that a fresh HOME doesn't have, which is a no-op.
  - 78-84 install with `--agent-type codex`. Locally, `diff -r` of that install against the default one differs only in install_id, created_at and the three HOME-path files.
  - **Leave test 1 as a real install** (the file's fresh-install smoke test), and leave every test that asserts on the install's own output (`run env ... install.sh`, for example tests 2, 6, 11 and 13) alone.
- **Estimate: saves ~150 s macOS and ~47 s ubuntu.**
  - Basis: 53 × (3.2 s fresh install − ~0.3 s restore) − 3.2 s for the one install in `setup_file` on macOS. On ubuntu: 55 × (0.95 − 0.07) − 0.95.
  - The restore, rewrite, check and `rm` took **69 ms** locally (`prof/restore_bench.sh`, 10 iterations). I assumed ×4 for macOS.
- **test_only:** yes. **Coverage risk:** low.
  - The bytes each test asserts on still come from the real `install.sh` run from the current tree, so the header's goal (L3-6, "the packaged artifact ... is what gets validated") still holds.
  - What goes away is 53 repeats of the same fresh install. Fresh installs still run in-test in tests 1, 2, 6, 11, 13, 19, 36, 40, 72, 96 and others.
  - Per-test HOMEs stay unique, so a leaked process can't contaminate the next test.
  - This is the first `setup_file` in `tests/` (none exists today); bats 1.13 supports it.

### 2. Share installs for the marker-directory tests, and optionally merge the "upgrader" tests (test-only)

- **2a. Keyed templates.** Extend proposal 1's helper to build a template on first use for each set of marker dirs:
  - `.copilot`: tests 36 and 38
  - `.config/opencode`: tests 40 and 42
  - `.hermes`: tests 69, 70 and 74
  - `.gemini/config`: tests 88, 92 and 95

  Every test keeps its own name and assertions.
  - **Estimate: saves ~16 s macOS and ~5 s ubuntu.** Basis: 6 installs avoided (3.2 s / 0.95 s each), minus 10 restores (0.3 s / 0.07 s each).
  - Coverage risk: low (same reasoning as 1).
- **2b. Merge the five near-identical "installs X skill for upgraders without prior skill" tests** (39 Copilot, 43 OpenCode, 75 Hermes, 87 Grok Build, 91 Antigravity; L952-962, L993-1000, L1664-1671, L1923-1932, L1954-1961). The merged test restores the default install, asserts none of the five skill dirs exists, creates all five markers, runs one bare `--update`, and asserts each SKILL.md and its `whoami.sh ... <type>` line.
  - **Estimate: saves ~17 s macOS and ~4.5 s ubuntu after proposal 1** (4 × (3.9 s update + 0.3 s restore); 4 × (1.05 + 0.07)). Without proposal 1 it saves ~28 s and ~8 s.
  - Coverage risk: low-medium. One update with all five markers present is not quite five separate updates: an interaction between marker types would be masked or exposed differently, and the first failing type hides the rest. The titles reference distinct review findings, so reviewers may prefer to keep them separate.

### 3. Test 94: remove the newline fixture before the second update (test-only)

- **What to change:** after the first update's assertions (after L2074, before the gen-2 leftover at L2076-2080), add `rm -rf "$SK/scripts/$evil_name"`.
- **Why it costs so much today:**
  - The `x\n..` directory (L2042-2046) is left in place by design: the prune refuses to move it (install.sh:295-297).
  - Because one relative path is unsafe, `agmsg_install_manifest_write` drops batch hashing for **all** files (install-manifest.sh:256-274). Each of the ~259 files then goes through `agmsg_sha256`, which runs a known-answer self-test before every digest. That is 2 Perl `shasum` per file.
  - Reproduced locally: every update in that state takes **13.6-15.2 s against 1.5 s** normally, with 518 `shasum` execs (`prof/t94_repro.sh`).
- **What it keeps:** the second update only asserts the generation reset (L2083-2086). The escape assertions (L2070-2072) belong to the first update, which keeps the fixture.
- **Tests:** 94.
- **Estimate: saves ~14.5 s macOS and ~6.5 s ubuntu.** Basis: the excess per slow update is (40.0 − 3.2 − 2 × 3.9) / 2 on macOS and (16.1 − 0.95 − 2 × 1.05) / 2 on ubuntu.
- **test_only:** yes. **Coverage risk:** low. Note that the header comment (L1996-2006) asks for "one test, everything in the same run". This keeps a single test, but the second update would no longer run with the escape fixture present. Proposal 6c avoids that trade-off.

### 4. Test 97: run the 10 per-type install + update pairs concurrently (test-only)

- **What to change:** in L2129-2142, give each type its own HOME under `$BATS_TEST_TMPDIR` and run `install --agent-type t`, the `grep`, `--update --cmd`, and the `grep` again as one background job. Launch them in batches of 3-4 (bash 3.2 has no `wait -n`), record each job's status and log, then assert per type and `cat` the log of any type that failed.
- **Why it works:** CI runs one bats file at a time with no `--jobs` (`.github/scripts/run-bats-timed.sh:63`), so the runner's other cores are idle during this test: 3 vCPU on macOS, 4 on ubuntu.
  - The installs share nothing per HOME. The lock handshake bound is 30 s (`install-op-lock.sh:69`), far above any contention delay.
  - `git describe --dirty` on the shared source tree is read-mostly and gentle about the index lock.
- **Tests:** 97.
- **Estimate: saves ~41 s macOS and ~12 s ubuntu** (69.5 → ~28 s, 19.3 → ~7 s). Basis: 10 independent pairs at ~6.9 s / 1.9 s each, and an assumed ~2.5x (macOS) / ~2.8x (ubuntu) speedup on 3-4 cores. This is an assumption, not a measurement.
- **test_only:** yes. **Coverage risk:** medium.
  - Today all 10 installs share one HOME. Running them separately drops that incidental co-existence, though nothing asserts on it.
  - Parallel load adds a small flake risk, and the test gets more complex.
- **Rejected alternative:** skipping the bare `--update` for the six dedicated-file types. The comment at L2117-2127 says that keeping the shared file on codex across the bare `--update` "is still exactly what #846 guards for them too".

### 5. Test 32: replace the fixed sleep and make the fake engine respond to TERM (test-only)

- **What to change:**
  - L828: replace `sleep 1` with a bounded poll, at most 10 × 0.1 s, until `kill -0 "$old_pid"` fails. Keep the 1 s ceiling so the assertion is no weaker.
  - L789: change the fake's loop to `while :; do sleep 1 & wait $!; done`. `wait` is interrupted by the trap, so `trap "exit 0" TERM INT` takes effect at once. Today both the update's engine stop and teardown's `_agmsg_kill_confirmed` wait for the current `sleep 1` to end.
- **Tests:** 32.
- **Estimate: saves ~1.5 s macOS and ~1.5 s ubuntu.** These are fixed waits: about 1 s from the sleep, plus about 0.5 s on average for each of two TERM deliveries.
- **test_only:** yes. **Coverage risk:** low.

### 6. Make every install run cheaper (production code, not test-only)

These help this file and every other suite that runs `install.sh`: test_plugin_install, test_install_op_lock, test_watch_install_changed and others.

- **6a. One batched comparison instead of 256 `cmp`** in `agmsg_stage_overwrite_backups` (install.sh:232-247).
  - Hash the staged tree and the installed tree with the existing `_agmsg_install_manifest_hash_batch` (2 calls in total), or pre-filter with a single `diff -rq` and run `cmp` only on the candidates.
  - Keep `cmp` for names that fail the safe-name check, and keep the NUL-delimited enumeration.
  - **Estimate: saves ~50 s macOS and ~7 s ubuntu.** Basis: 71 updates × (256 × ~3.5 ms − ~0.2 s for the batch) on macOS, and 71 × ~0.1 s on ubuntu.
  - Coverage risk: low. Test 94's backup assertion for the edited `send.sh` (L2060) and its byte-for-byte checks on the shipped file (L2054-2055) cover this path.
- **6b. Prune membership through one newline-delimited string and `case`** instead of the nested loop (install.sh:299-305). This is bash 3.2-safe. `rel` has already passed `agmsg_scripts_rel_is_safe` (no newline) before the comparison, and quoting `"$rel"` inside the pattern keeps glob characters literal.
  - Micro-benchmark on bash 5.2 (`prof/prune_bench.sh`): **79 ms → 8 ms per install run**, with the same 151 hits.
  - **Estimate: saves ~10 s ubuntu and ~30 s macOS** over about 199 runs. The macOS figure assumes bash 3.2 is 2-3x slower on this loop; I did not measure it. After proposal 1 there are about 140 runs, so roughly 7 s and 20 s.
  - Coverage risk: low. Test 94's prune and trash assertions cover it.
- **6c. Batch the safe names and fall back to per-file hashing only for unsafe ones** in `agmsg_install_manifest_write` (install-manifest.sh:253-276).
  - The helper's own comment says the caller "falls back to agmsg_sha256 for any other name" (install-manifest.sh:44-49), but the code falls back for every file once a single name is unsafe.
  - Test 108 already checks that an unsafe name's recorded digest equals `agmsg_sha256`'s (L2555-2569), so the per-name fallback stays covered.
  - **Estimate: saves ~29 s macOS and ~13 s ubuntu** on test 94 (both slow updates become normal). This replaces proposal 3.
  - Coverage risk: low.

## Risks and notes

- **Measurement basis.** One CI run (macos_n = ubuntu_n = 1). The macOS samples for tests 15 (13.5 s) and 90 (5.0 s) are out of line with tests of the same shape, so I made no specific proposal for them. All the other per-install averages are consistent within ±15% across dozens of tests.
- **Overlap.**
  - Proposal 6 makes each install cheaper, so proposals 1 and 4 save less once 6 lands, and the reverse.
  - Proposal 3 is superseded by 6c.
  - With 1 + 2a + 2b + 3 + 4 + 5 (all test-only), the file goes from ~762 s to ~520 s on macOS and from ~237 s to ~160 s on ubuntu.
  - Adding 6a and 6b (6c replaces 3) brings it to roughly 450 s macOS and 140 s ubuntu.
- **Conventions.**
  - No test file in the repo uses `setup_file` today. Proposals 1 and 2a introduce it and should be reviewed as a pattern.
  - Repo culture strongly prefers one property per named test, which is why 2b is optional and 2a is the default.
  - Proposals 1 and 3-5 change no assertion.
- **Smaller items I skipped:**
  - Test 57 copies the whole repo (`cp -R "$REPO_ROOT/."`, then `rm -rf .git`, then `git add -A` over ~33 MB) to fake a tag history. Copying only what `install.sh` reads would save perhaps 1-2 s on macOS, but missing a file would break the test.
  - Tests 18, 22, 107 and 112-115 exercise multi-install, daemon or fault-injection paths whose cost is the behaviour under test. Their polls are already 0.02-0.1 s.
- **Cross-suite note.** Each fresh install execs `dirname` 78 times, mostly from the `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` idiom at library source time (53 under the installed `scripts/lib/`). Replacing it with parameter expansion across `scripts/lib/*.sh` could save on the order of 0.2-0.3 s per install on macOS, and similar fractions in every suite. It touches many files, so measure it before proposing it.
- **Shard balance.** At 764 s the file fills about 64% of an average 6-shard slot (~1199 s), so LPT can still place it and no split is needed. After any of these changes land, refresh its row in `.github/scripts/bats-file-seconds.tsv`.
