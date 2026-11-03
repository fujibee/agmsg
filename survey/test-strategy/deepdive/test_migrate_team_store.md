# test_migrate_team_store.bats: where the CI time goes

Data: CI run 41607512279 (main @ 64723d6), `per-test-41607512279.tsv`, macOS shard 6 and ubuntu shard 6. Code read at main @ 551764e. Local checks (Linux, loaded box): a file-tree diff of what the setup writes, and 5 single tests run from a scratch copy of the file with the proposed setup and with the original. Paths are repo-relative; `Lnnn` means `tests/test_migrate_team_store.bats:nnn`.

## Summary

- **167 s macOS / 95 s ubuntu** for 26 tests. Every test costs 4.7-10 s on macOS and 3.0-5.4 s on ubuntu, and the macOS/ubuntu ratio is a flat ~1.8x. The file is fork/exec-bound; no test waits on a timer.
- **`setup()` (L10-18) runs four `join.sh` per test: alpha/ann, alpha/bob, beta/ann, beta/bob, i.e. 104 joins per file run.** The tests that do nearly nothing else show the floor:
  - #11 (only greps install.sh) takes 4.88 s / 2.96 s.
  - #10 (migrate fails at once) takes 4.71 s / 3.00 s.
  - #9 (migrate fails at once) takes 5.16 s / 2.99 s.
- With the bare fixture at ≈ 0.45 s / 0.15 s, **the four joins cost ≈ 4.4 s macOS / 2.75 s ubuntu per test**, about 66% of the file's macOS time and 75% of its ubuntu time. Each join is ≈ 1.1 s / 0.69 s. A large share of each join is `agmsg_agent_pid` walking the CI process tree to pid 1 (10-11 hops, 3 `ps` per hop; scripts/lib/resolve-project.sh:526).
- **The four joins write only `teams/alpha|beta/{config.json,roster.jsonl}`.** This was verified with `find -newer` across TEST_SKILL_DIR, TMPDIR and HOME; `db/messages.db` is untouched (same md5). The project paths (`/tmp/alpha-ann` …) are not under TEST_SKILL_DIR, so the arrange is byte-identical in every test except for ids and timestamps. It can be produced once per file and copied.
- **M1 saves ≈ 110 s macOS / ≈ 69 s ubuntu (≈ 66% / 73% of the file).** Locally, five tests went from 3.8-5.4 s to 1.0-1.3 s each, all green. M2 is a fallback with about half the effect.

## Where the time goes

Driver legend:

- **F4**: the per-test setup.
  - `setup_test_env` (test_helper.bash:42-116: `cp -R` of 257 files, init-db, ≈ 0.45 s / 0.15 s).
  - Four `join.sh` calls (L14-17), ≈ 4.4 s / 2.75 s together. Basis: #11, #10 and #9 above.
  - `teardown_test_env` (no ps reap unless the rm fails).
- **send**: one `scripts/send.sh` (bash + sqlite3).
- **migrate**: one `scripts/internal/migrate-team-store.sh` run.
- **sqlite3**: one direct `sqlite3` probe or insert in the test body.

The table lists every test: all 22 tests over 5 s plus the 4 cheapest, which show the floor.

| # | title | macOS s | ubuntu s | mac/ubu | cum. macOS % | driver |
|---:|---|---:|---:|---:|---:|---|
| 24 | migrate: the empty-event case also gets a destination high-water that is not behind the copi... | 9.96 | 5.42 | 1.84 | 6.0 | F4 + 2 more `join.sh` (gamma, L601-602) + 2 send + migrate + send + storage reads |
| 23 | migrate: a new per-team message is deliverable after migration when the copied cursor exceed... | 8.36 | 4.34 | 1.92 | 11.0 | F4 + 4 send + migrate + send + storage_list_unread / storage_watch_after |
| 8 | migrate: a moved team can still be renamed, and its store follows | 7.58 | 3.82 | 1.98 | 15.5 | F4 + send + migrate + `rename-team.sh` + `history.sh` |
| 20 | migrate: a cursor absent from the destination is refused | 7.07 | 3.56 | 1.98 | 19.7 | F4 + send + migrate + 2 sqlite3 + migrate (refused) |
| 22 | migrate: re-entry completes when the destination has more than the shared store | 6.92 | 3.98 | 1.74 | 23.9 | F4 + 3 send + migrate + 2 sqlite3 + migrate |
| 5 | migrate: new messages keep arriving after the move | 6.86 | 3.88 | 1.77 | 28.0 | F4 + 2 send + migrate + `inbox.sh` |
| 12 | migrate: a destination that vanished does not take the shared rows with it | 6.84 | 3.53 | 1.94 | 32.1 | F4 + send + migrate + sqlite3 + migrate (refused) |
| 21 | migrate: a cursor that is not an integer is refused, and the shared copy survives | 6.68 | 3.60 | 1.86 | 36.1 | F4 + send + migrate + 3 sqlite3 + migrate (refused) |
| 14 | migrate: a destination that cannot be read is refused, not assumed complete | 6.64 | 3.55 | 1.87 | 40.1 | F4 + send + migrate + sqlite3 + migrate (refused) |
| 17 | migrate: a message id reused for the SAME content is not refused | 6.60 | 3.70 | 1.78 | 44.0 | F4 + send + migrate + 2 sqlite3 + migrate |
| 6 | migrate: running it again is a no-op | 6.58 | 3.62 | 1.82 | 48.0 | F4 + send + migrate + cksum + migrate |
| 19 | migrate: a cursor that advanced in the destination does not block re-entry | 6.55 | 3.59 | 1.83 | 51.9 | F4 + send + migrate + 2 sqlite3 + migrate |
| 15 | migrate: a destination whose keys collide with different content is refused | 6.50 | 3.51 | 1.85 | 55.8 | F4 + send + migrate + 2 sqlite3 + migrate (refused) |
| 18 | migrate: a cursor at a different position is refused | 6.48 | 3.57 | 1.82 | 59.7 | F4 + send + migrate + 2 sqlite3 + migrate (refused) |
| 2 | migrate: only the named team moves | 6.32 | 3.79 | 1.67 | 63.5 | F4 + 2 send + migrate |
| 4 | migrate: the history is still readable afterwards | 6.22 | 3.62 | 1.72 | 67.2 | F4 + send + migrate + `history.sh` |
| 16 | migrate: a message id reused for different content is refused | 6.21 | 3.55 | 1.75 | 70.9 | F4 + send + migrate + 2 sqlite3 + migrate (refused) |
| 1 | migrate: the seq the containment check compares is stored as an integer | 6.10 | 3.59 | 1.70 | 74.6 | F4 + send + migrate + sqlite3 probes (test 1 also absorbs bats file start-up) |
| 26 | migrate: the link between an event and its legacy row survives the move (#710) | 6.01 | 3.76 | 1.60 | 78.2 | F4 + send + migrate + `history.sh` + sqlite3 |
| 13 | migrate: a destination missing some of the shared rows is refused | 5.99 | 3.45 | 1.73 | 81.8 | F4 + send + migrate + sqlite3 + migrate (refused) |
| 7 | migrate: refuses to merge into a store that already exists | 5.54 | 3.21 | 1.72 | 85.1 | F4 + send + sqlite3 + migrate (refused) |
| 3 | migrate: the moved team is removed from the shared store | 5.49 | 3.41 | 1.61 | 88.4 | F4 + send + migrate |
| 9 | migrate: a team that does not exist is refused | 5.16 | 2.99 | 1.73 | 91.5 | F4 + migrate (fails at once): **the fixture alone** |
| 11 | migrate: installing moves nothing | 4.88 | 2.96 | 1.65 | 94.4 | F4 + one `grep` of install.sh: **the fixture alone, unused** |
| 10 | migrate: a team name that cannot be a directory is refused | 4.71 | 3.00 | 1.57 | 97.2 | F4 + migrate (fails at once) |
| 25 | migrate: a non-integer source cursor refuses the FIRST migration attempt, before anything is... | 4.66 | 3.35 | 1.39 | 100.0 | F4 + send + sqlite3 + migrate (refused before writing) |

Observations:
- On top of the ~4.7-4.9 s macOS floor (#10, #11), one send plus one or two migrate runs adds ~0.6-1.1 s (#3: 5.49 s, #13: 5.99 s), and a migrate that refuses at once adds ≤ 0.3 s (#9). The heaviest acts are #23 (5 sends, migrate and the storage contract functions, ≈ 3.5 s) and #24 (two more joins plus 3 sends, ≈ 5 s).
- Nothing in the file sleeps or polls. The only time-related code is `date -u` used to share one timestamp (#16, #17, #22; #723).

## Proposals

### M1. Produce the four registrations once per file and copy them into each test

- **Change.** Replace L14-17 of `setup()` with a lazily built template in `$BATS_FILE_TMPDIR`. This works under `bats -f` and needs no `setup_file`; a `setup_file` + `teardown_file` pair would be equivalent.

  ```bash
  setup() {
    setup_test_env
    SHARED="$TEST_SKILL_DIR/db/messages.db"
    export SKILL_DIR="$TEST_SKILL_DIR"
    # The four registrations are identical in every test and touch only
    # teams/<team>/{config.json,roster.jsonl} (no path under TEST_SKILL_DIR),
    # so join.sh produces them once per file and each test gets a fresh copy.
    local tpl="$BATS_FILE_TMPDIR/teams-template"
    if [ ! -d "$tpl" ]; then
      bash "$SCRIPTS/join.sh" alpha ann claude-code /tmp/alpha-ann >/dev/null
      bash "$SCRIPTS/join.sh" alpha bob claude-code /tmp/alpha-bob >/dev/null
      bash "$SCRIPTS/join.sh" beta  ann claude-code /tmp/beta-ann  >/dev/null
      bash "$SCRIPTS/join.sh" beta  bob claude-code /tmp/beta-bob  >/dev/null
      mkdir -p "$tpl" && cp -R "$TEST_SKILL_DIR/teams/." "$tpl/"
    else
      cp -R "$tpl/." "$TEST_SKILL_DIR/teams/"
    fi
  }
  ```

- **Tests:** all 26. The first test of a run builds the template; the other 25 copy it.
- **Savings:** 25 × 4.4 s ≈ **110 s macOS**, 25 × 2.75 s ≈ **69 s ubuntu**. The copy of 4 small files costs ~0.02 s per test.
  - Basis: the F4 floor from #11 (4.88 s / 2.96 s), #10 (4.71 s / 3.00 s) and #9 (5.16 s / 2.99 s), minus the bare fixture.
  - Local check, same 5 tests, original setup against M1: #2 4.87 → 3.90 s (this test built the template); #6 3.82 → 1.02 s; #8 4.27 → 1.32 s; #19 4.90 → 1.24 s; #24 5.43 → 3.83 s (#24 still runs its own two gamma joins). All passed.
- **test_only:** yes. **Coverage risk: low.**
  - What the file verifies is migrate-team-store.sh. join.sh is the arrange, and join.sh still produces the template.
  - Each test gets its own copy, so in-test mutations cannot leak: migrate flipping the partition in `config.json`, #8's `rename-team.sh`, #24's gamma joins.
  - Team and member ids, and `created_at`, become the same in every test. No test reads or compares them. The cursor and message rows the tests insert key on team and agent *names*.
  - CI runs each file serially (`.github/scripts/run-bats-timed.sh`, no `--jobs`), so the lazy build cannot race. If `--jobs` were ever enabled, build the template in `setup_file` instead.

### M2. `export AGMSG_AGENT_PID=""` in `setup()` (fallback, or complement)

- **Change.** Add the line 14 other files already carry, for example test_delivery.bats:10 and test_actas_integration.bats:19. It pins `agmsg_agent_pid`'s "no agent ancestor" answer (scripts/lib/resolve-project.sh:483-499). That is the answer the 10-11-hop CI walk reaches anyway, so it removes that walk, about 44% of a CI join's forks.
- **Savings.**
  - Alone (without M1): 106 joins × ≈ 0.46 s / 0.29 s ≈ **49 s macOS / 31 s ubuntu**. Basis: a CI join takes 1.1 s / 0.69 s, of which ~42% is the walk.
  - On top of M1: only 6 joins remain (the template build and #24's two), ≈ **2.8 s / 1.7 s**.
- **test_only:** yes. **Coverage risk: low.** The resolved project path is the explicit `/tmp/...` argument either way, and the walk is covered by test_instance_id.bats and test_resolve_project.bats.

## Risks and notes

- **Not proposed: folding #24's gamma team into the template.** It would save 2 joins (≈ 2.2 s / 1.4 s) but changes the fixture of the other 25 tests. Not worth it.
- **Not proposed: merging tests.** The comments argue against it: each table is asserted separately because "one of them getting it right hides the others", and #12-#22 each isolate one containment rule (and say so in their comments). After M1 the per-test overhead is ~0.5 s macOS, so merging would buy little anyway.
- **What remains after M1** (≈ 57 s macOS / 26 s ubuntu) is the fixture (`setup_test_env`, a suite-wide topic) plus the act: send.sh, migrate-team-store.sh and the readers.
- **If the template ever goes stale.** If join.sh's output format changes, the template changes with it, because it is regenerated by join.sh on every file run. Nothing is checked in.
