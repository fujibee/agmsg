# tests/test_self_name.bats — where the CI time goes

Data: CI run 41607512279 (main @ 64723d6, shard 3 on both OSes), `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/per-test-41607512279.tsv`. Code read at main @ 551764e; the file and everything it drives are unchanged since 64723d6.

Local measurements were taken on Linux, 4 cores, under a background strace sweep (load 3-7), bats 1.13.0 and bash 5.2.21. A/B runs were made on copies of the test file in `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/survey/deepdive/rst/fakerepo/` (symlinked `scripts/`, `test_helper.bash` and `helpers/`); the repo itself was not modified. Wall times there are noisy, so each A/B also reports user CPU.

## Summary

- **Size:** 29 tests, **192.5 s macOS / 70.7 s ubuntu**. Test 6 alone is 23.8 / 10.2 s; 12 tests make up 72% of the macOS time.
- **macOS/ubuntu ratio:** 2.3-3.6 for every test, so the file is process- and interpreter-bound. The only fixed wait is test 16's `sleep 1` (L539).
- **The naming slow half is ~83% of the file.** About 30 calls of it run in-process (`agmsg_self_name_on_action`, `agmsg_terminal_name_self_safe`), each costing **~5.0-5.4 s macOS / ~1.9 s ubuntu** for tmux and **~6.1 / ~2.2** for herdr. Basis: test 11 = 1 naming = 5.27 / 2.01; test 3 = 2 namings = 11.1 / 3.95; test 15 = 1 herdr naming = 6.45 / 2.37; floor (tests 24-25) = 0.29 / 0.10.
- **Why one naming costs that much — two compounding reasons:**
  - **(a) About 600 forks per naming.** Measured with an xtrace of one tmux naming outside bats (`rst/selfname_xtrace.sh`): 594 subshells. Most come from registry lookups that re-read driver and type manifests through subshells on every call (counts are subshells from one naming):

    | function | location | subshells | why |
    |---|---|---|---|
    | `agmsg_type_get` | — | 90 | — |
    | `agmsg_driver_bases` | `driver-registry.sh:47-49` | 80 | re-forks `_agmsg_driver_root` on each call |
    | `agmsg_terminal_get` | `terminal-registry.sh:123-126` | 75 | three subshells per key |
    | `agmsg_terminal_dir` | `:104-116` | 44 | — |
    | `agmsg_type_dir` | — | 30 | — |
    | `agmsg_terminal_candidates` | — | 29 | — |
    | `agmsg_detect_cli_type` | — | 20 | — |

    Each fork copies the large bats test process; that is the part macOS pays ~3× for.
  - **(b) bats' DEBUG trap runs before every command of that library code.**
    - bats-exec-test runs with `set -eET` and installs `trap 'bats_debug_trap "$BASH_SOURCE"' DEBUG` (bats-core `lib/bats-core/tracing.bash:385`).
    - With functrace on, every simple command of the sourced library first runs `bats_debug_trap` (path normalisation, an exclude loop, array copies, stack capture). That applies both in the test shell and inside every `$(...)`.
    - Measured locally on tests 1 + 3:

      | variant | wall (s), ~0.7 s bats startup subtracted | user CPU (s), whole run |
      |---|---|---|
      | as is | 8.9 | 7.7 |
      | sandbox excluded with `bats_add_debug_exclude_path "$TEST_SKILL_DIR/"` | 4.9 | 4.2 |
      | guarded trap that skips library frames | 3.9 | 3.1 |

      All variants pass. The code under test is identical in all three.
- **Proposals, test-only unless marked:**
  1. Exclude the sandbox's library frames from the trap, one line in `setup()`: **~38 s macOS / ~26 s ubuntu**.
  2. Fold two tests that repeat another test's arrange and action into it: **~11 / ~4**.
  3. Optionally, merge two pairs that only differ after a shared first naming: **~11 / ~4**.
  4. Test 16's `sleep 1` → wait for the next second only if needed: **~1 / ~1**.
  5. Production change: fork-free registry readers, **~45 / ~12**.

## Where the time goes

These 12 rows are 72.4% of the file's macOS time and include every test over 5 s. Unit costs used in the driver column:

| step | macOS s | ubuntu s |
|---|---|---|
| tmux naming | ~5.2 | ~1.9 |
| herdr naming | ~6.1 | ~2.2 |
| `_join_unnamed` (a `join.sh` subprocess; pinned by `AGMSG_AGENT_PID=""` at L30 and the fake `ps` at L50-58, so it does no walk) | ~0.45 | ~0.17 |
| fast-half read (mark matches: one `display-message` / `pane get`) | ~0.4 | ~0.15 |
| per-test floor | 0.29 | 0.10 |

| # | title | macOS s | ubuntu s | ratio | driver |
|---|---|---|---|---|---|
| 6 | another seat in the same pane does NOT take it while the first seat's record claims it (#1114) | 23.8 | 10.2 | 2.33 | 11 `_join_unnamed`; 4 `actas-claim.sh` subprocesses (each a full naming in a fresh bash, L320, L329, L341, L352); 2 in-process namings (alice, then bob's refused attempt via `run`); 1 `agmsg_terminal_name_self_safe` (L363); ~25 `_mark`/`_placement` reads, each re-sourcing a lib in the test shell |
| 5 | the name removed while pane and server are unchanged IS seen now (#1130) | 14.4 | 4.0 | 3.60 | join + 2 tmux namings (the first, and the one after `_clear_fake_label`) + 1 fast read |
| 16 | herdr: mark matching -> no call; socket recreated (server restart) -> named again | 14.4 | 5.8 | 2.49 | join + 2 herdr namings + 1 fast read + **`sleep 1`** (L539, 1.0 s fixed) |
| 4 | mark present, same pane, but the tmux server restarted: named again | 13.0 | 3.9 | 3.34 | 2 tmux namings |
| 17 | herdr: a seat moved to another herdr session is named again | 12.6 | 4.4 | 2.90 | 2 herdr namings |
| 28 | the environment, the mark and the record all name the SAME wrong pane -- one action moves it (#1130) | 12.5 | 4.5 | 2.78 | join + 2 herdr namings (the second resolves by label: pane list + get) |
| 3 | mark present, but I am in another pane: named again, and the mark follows | 11.1 | 3.9 | 2.81 | 2 tmux namings |
| 13 | named once but never recorded: the next action writes the missing record (#1109) | 8.7 | 3.1 | 2.79 | join + `agmsg_terminal_name_self_safe` (mark only) + 1 tmux naming |
| 8 | the action names first, then a boot path: same key both times | 8.0 | 3.0 | 2.66 | 1 tmux naming + `agmsg_terminal_name_self_safe` |
| 29 | a seat whose environment IS its own pane still short-circuits (#1130 control) | 7.9 | 2.9 | 2.76 | join + 1 herdr naming + 1 fast read |
| 9 | a hand-started seat: the action RECORDS its placement, not only the label (#1109) | 6.5 | 2.2 | 2.93 | join + 1 tmux naming. Same arrange and action as test 10 |
| 15 | herdr: the pane comes from HERDR_PANE_ID with no session id, and the mark carries the socket generation | 6.5 | 2.4 | 2.72 | 1 herdr naming |

The other 17 tests total 53.2 / 20.4 s:

- 10, 11, 1, 2, 12, 7: one naming each, 3.6-6.1 s macOS.
- 20-22: subprocess commands (`send.sh`, `inbox.sh`, `history.sh`), whose naming runs outside the bats process.
- 14, 18, 19, 23-27: under 3.1 s.

## Proposals

### 1. Keep bats' DEBUG trap out of the library code under test (test-only, one line)

- **What to change:** at the end of `setup()` (after L68), add:

  ```bash
  declare -F bats_add_debug_exclude_path >/dev/null && bats_add_debug_exclude_path "$TEST_SKILL_DIR/"
  ```

  On macOS, add the `pwd -P` form of the directory too. `TEST_SKILL_DIR` sits under `/var/folders`, and a library sourced through a resolved `/private/var/...` path would not match the prefix.
- **A stronger variant**, measured at −56% instead of −45%: re-install the trap with a guard, `trap '[[ "${BASH_SOURCE-}" == "$TEST_SKILL_DIR"/* ]] || bats_debug_trap "$BASH_SOURCE"' DEBUG`. It relies more directly on a bats internal, the function name.
- **Why it is safe:**
  - The code under test runs unchanged.
  - bats still records stack traces for every line of the test file, so a failing assertion is reported at its own line. Verified with a deliberately failing assertion in the guarded copy of `test_terminal_registry.bats`, which was reported at the same assertion line as without the guard. Removing the trap entirely would instead blame the `trap` line, so that is not proposed.
- **What does not work:** setting `BATS_DEBUG_EXCLUDE_PATHS` from the environment. In bats 1.13, `bats_setup_tracing` resets the array before reading the variable; I measured no gain with it.
- **Tests:** all, mainly the ~30 in-process namings in tests 1-13, 15-17, 27-29.
- **Estimate: ~38 s macOS / ~26 s ubuntu** (guarded variant ~48 / ~32).
  - The basis is the local A/B on tests 1 + 3 (−45%), applied to the in-process naming time, about 160 s macOS / 58 s ubuntu.
  - Ubuntu behaves like the local Linux box. macOS is discounted to about −24%: its forks cost ~3.5× ubuntu's, while pure interpretation costs only ~1.6× (the ratio of the CPU-bound test 174 in `test_terminal_registry.bats`). So the trap is a smaller share of a macOS naming.
- **test_only:** yes. **Coverage risk:** none. Diagnosability is unchanged.

### 2. Fold two tests that repeat another test's arrange and action into it (test-only)

- **a. Test 11 (L444) into test 1 (L186).**
  - Both run `_install_fake_tmux; _under_tmux /tmp/s 4242 %3; agmsg_self_name_on_action team alice` with no join; that is exactly the #1391 "unregistered" state.
  - 11 asserts no placement record and one naming call. Test 1 already asserts the naming call.
  - Add `[ -z "$(_placement team alice)" ]` to test 1, together with test 11's #1391 comment.
  - **Saves ~5.0 / ~1.9.**
- **b. Test 9 (L407) into test 10 (L421).**
  - Both run `_join_unnamed team alice; _install_fake_tmux; _under_tmux ...; agmsg_self_name_on_action team alice`.
  - Test 10 asserts the record's ref, project and type, which covers 9's placement check. Add 9's `[ "$(_name_calls)" -eq 1 ]` to test 10.
  - **Saves ~6.2 / ~2.1.**
- **Tests:** 1, 9, 10, 11.
- **Estimate: ~11 s macOS / ~4 s ubuntu.** Basis: the CI seconds of tests 9 and 11, minus one assertion each.
- **test_only:** yes. **Coverage risk:** none. Arrange, action and every assertion survive, and only the test count drops.

### 3. Optional: merge two pairs that differ only after a shared first naming (test-only)

- **3 + 4 (L217, L228):** name at `%3`, then move to `%7` (3's checks), then restart the server with the same pane (4's checks, now on `%7`).
- **16 + 17 (L521, L544):** name, then a fast read, then recreate the socket (16), then move to another socket path (17).
- **Saves one first naming each.**
- **Tests:** 3, 4, 16, 17.
- **Estimate: ~11 s macOS / ~4 s ubuntu.** Basis: one tmux naming (5.2 / 1.9) plus one herdr naming (6.1 / 2.2).
- **test_only:** yes. **Coverage risk:** low.
  - Each second scenario now starts from the state the first left; it is still a correctly named seat.
  - Against it: the file header presents each case as its own pinned claim with its own control, and a failure in the first half hides the second. That is why it is optional.

### 4. Test 16: wait for the next second only when needed (test-only)

- **What to change:** at L539, replace `rm -f "$HERDR_SOCKET_PATH"; sleep 1; : > "$HERDR_SOCKET_PATH"` with:
  1. Read the old socket's ctime the way `terminal_epoch` does (`herdr/ops.sh:339-340`: `stat -f %c`, falling back to `stat -c %Z`).
  2. `rm -f` the socket.
  3. Poll `date +%s` until it is greater than that ctime.
  4. Recreate the socket.
- **Why it is safe:** the comment's requirement is that the recreation crosses a whole-second boundary, because ext4 reuses the inode at once. The new loop checks that explicitly instead of assuming it from a fixed sleep. The socket was created at L523, and two namings (≥3.5 s even on ubuntu) have run since, so the loop normally exits at once.
- **Tests:** 16.
- **Estimate: ~1.0 s macOS / ~1.0 s ubuntu.**
- **test_only:** yes. **Coverage risk:** none.

### 5. Production change: fork-free registry readers (not test-only)

- **What to change:**
  - Compute `_agmsg_driver_root` once when `driver-registry.sh` is sourced (the lib directory does not move).
  - Read `terminal.conf`/`type.conf` keys with a `while read` loop instead of `$(agmsg_terminal_dir)` + `grep | head` + strip (`terminal-registry.sh:123-140`, and the clone `agmsg_type_get` in `type-registry.sh:103`).
  - Have `agmsg_terminal_dir` read the bases without a subshell.
- **Why fork-free rather than cached:** it removes most of the ~320 of 594 forks in one naming that the table in the summary attributes to these readers, and it has none of a cache's invalidation questions. Trust and plugin directories can change inside one process (`agmsg_driver_trust`, `AGMSG_PLUGIN_DIRS`), which is why `_agmsg_agent_binaries` (`resolve-project.sh:350-360`) refuses to cache that path.
- **Estimate: ~45 s macOS / ~12 s ubuntu** for this file. Basis: ~55% fewer forks in a naming; on macOS the forks are ~3.7 of the ~5.2 s per naming, on ubuntu about 1 of 1.9 s; × ~30 namings.
  - It overlaps with #1, since the trap overhead inside those functions also disappears.
  - It also speeds up `test_terminal_registry.bats` and real `send`/`inbox` runs.
- **test_only:** no. **Coverage risk:** medium. It rewrites the manifest parser, whose quoting and whitespace rules must stay identical; `test_terminal_registry.bats` tests 11 and 207-211 pin those rules.

## Risks and notes

- **Totals are not additive.** #1 shrinks every naming, so #2 and #3 then save about 55-75% of the figures given (they are measured against today's per-naming cost). Test-only #1 + #2 + #4 come to about **~45 s macOS / ~29 s ubuntu**.
- **The file deliberately runs the primitive in-process against fakes** ("This file's whole subject is the naming primitive itself", L61-66). #1 keeps that; it only stops bats from tracing the library frames.
- **No hand-written arrange state.** I do not propose replacing any test's first naming with a hand-written mark or record. Test 28's comment explicitly prefers state "reproduced through the code that creates it rather than hand-written", and the fixture would go stale silently if the writer's format changed.
- **The process walk is not a cost here.** `setup()` already pins `AGMSG_AGENT_PID=""` (L30) and fakes the two `ps` shapes the type walk uses (L50-58). Both are consistent with the walk finding in `test_remote.md`.
- **`bats_add_debug_exclude_path` is a bats function, not a documented flag.** CI pins bats 1.13.0. With the `declare -F` guard, a future bats without it only loses the speedup.
- **Raw data** is in `rst/`: `sn1.xtrace`, the subshell attribution in `selfname_xtrace.sh`, and the A/B taps `sn_*.tap`.
