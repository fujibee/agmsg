# tests/test_remote.bats — where the CI time goes

Data: CI run 41607512279 (main @ 64723d6), `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/per-test-41607512279.tsv` and the shard-5 job logs. Code read at main @ 551764e; this file, `tests/test_helper.bash` and everything under `scripts/` that it drives are unchanged since 64723d6, except `scripts/internal/install-baseline.mjs`, which this file does not use.

Local measurements were taken on Linux, 4 cores, with a background strace sweep running (load 3-7), bats 1.13.0 and bash 5.2.21. Process counts come from a full-file `strace -f -e execve` run that the sweep made; I attributed each exec to a test with `rst/remote_table.py`. Two caveats about that run:

- `age` is installed locally, so the 19 tests that skip on CI ran there.
- It ran as root, so tests 87 and 88 skipped there.

Scripts and raw outputs are in `/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad/survey/deepdive/rst/`.

## Summary

- **Size:** 152 tests, **554.6 s macOS / 253.5 s ubuntu**. It is the largest file in the suite, but no single test is large: the slowest is 11.5 s, and it takes 77 tests to reach 70% of the macOS time.
- **macOS/ubuntu ratio:** almost every test sits at 2.0-3.0. That points to process spawning (fork/exec of bash, node, python3, sqlite3, ps), not to fixed waits. No test pays a timeout, and every wait in the file is an event poll.
- **The per-test fixture is the biggest cost.** A test that is skipped on CI still pays `setup()` and `teardown()`, and costs **1.6 s macOS / 0.96 s ubuntu** (tests 49, 52, 84, 108-111). Across 152 tests that is about 243 s macOS / 146 s ubuntu, or 44% / 58% of the file.
- **Inside the fixture, the largest piece is a process-tree walk in `join.sh`.** `setup()` runs `join.sh` (L19), which calls `agmsg_resolve_project` (`join.sh:93`) → `agmsg_agent_pid` (`scripts/lib/resolve-project.sh:489-531`).
  - The walk climbs from the shell to pid 1, running three `ps` calls plus `tr`, `awk` and `basename` at each hop.
  - On CI the chain is about 10 hops: bats-exec-test → bats-exec-file → bats-exec-suite → bats → run-bats-timed.sh → step shell → Runner.Worker → Runner.Listener → hosted-compute-agent (from the shard log's `ps -ef`).
  - Nothing on that chain is an agent, so the walk always runs to the end and finds nothing.
  - Estimated cost: **about 0.65-0.7 s macOS / 0.5-0.55 s ubuntu per `join.sh`**, and a CI run makes about **175 `join.sh` calls**: one in `setup()` per test, plus about 23 inside tests.
  - In the local trace, 97% of the file's 6,029 `ps` execs came from this walk: 33 per `join.sh`, 177 `join.sh` runs.
- **Test bodies:** each `remote.sh connect` adds about 1.3 s macOS / 0.5 s ubuntu (test 5: 2.9/1.5 against the 1.6/0.96 floor). The cost is node endpoint validation, registration over curl, `migrate-team-store.sh`, then a node sync-engine start and its readiness poll (`remote.sh:3317-3335`). That poll is an event wait at 0.01 s steps; the engine's own startup is the cost. A CI run makes about 80 engine starts and about 97 connects.
- **Proposals, test-only unless marked:**
  1. One line, `export AGMSG_AGENT_PID=""` in `setup()`: **~110 s macOS / ~90 s ubuntu** (lower bound 60/23).
  2. Copy a once-per-file snapshot of the joined fixture instead of rebuilding it per test: **~75 s / ~27 s more**.
  3. Merge four groups of tests that rebuild the same two-connect or truncated-config arrange: **~30 s / ~12 s**.
  4. Move the 43 tests that never contact the mock server into their own file without it: **~8 s / ~5 s**, plus shard balance.
  5. Two small poll fixes: **~5 s / ~9 s**.
  6. Optionally, runtime mock knobs instead of ~30 server restarts: **~7 s / ~3.5 s**.

## Where the time goes

### The fixture (paid by all 152 tests)

| component | macOS s | ubuntu s | basis |
|---|---|---|---|
| bats per-test overhead | ~0.03 | ~0.02 | the fastest tests suite-wide: 0.027 / 0.017 |
| `setup_test_env` + `teardown_test_env` | ~0.2 | ~0.1 | Copies 257 files (cp -R, test_helper.bash:70), runs chmod, runs `init-db.sh` (:81), and does `rm -rf` in teardown. Basis: the fastest tests of files whose `setup()` is only `setup_test_env` (test_config.bats 0.22/0.12, test_team.bats 0.23/0.12) |
| `join.sh`, minus the walk | ~0.4-0.5 | ~0.12-0.17 | test_doctor.bats, whose `setup()` is `setup_test_env` + `AGMSG_AGENT_PID=""` + `join.sh`; its fastest tests total 0.81 / 0.34 including a doctor call |
| **`join.sh` process walk** | **~0.65-0.75** | **~0.5-0.55** | The remainder of the 1.6 / 0.96 floor. It agrees with test_team.bats test 2 (one unpinned `join.sh` + a file check: 1.84 / 0.87 against a 0.23 / 0.12 floor). Exec counts alone give a lower bound: about 70 execs per walk (7 execs + 16 forks per hop, measured with `rst/walk_depth.sh`) × 4.5-6 ms / 1.7-2.2 ms per exec ≈ 0.35 / 0.13. The floor's low macOS/ubuntu ratio (1.67, against 2-3 for the rest of the file) fits `ps` being relatively expensive on the ubuntu runner |
| python3 mock server start + `wait_for_file_contains` (0.1 s ticks) + kill/wait | ~0.2 | ~0.11 | locally 110 ms, including one 0.1 s tick. The port file exists, empty, before python starts, so the first check always fails |
| **total (skip-only tests on CI)** | **1.6** | **0.96** | CI: tests 49, 52, 84, 108, 109, 110, 111 |

### Per test (tests sorted by macOS time, down to 70% of the file's macOS time)

How to read the columns:

- **driver:** "fixture" is the table above.
- **remote.sh x N:** subcommand invocations.
- **+N join / +N mock server:** beyond the fixture's one of each.
- **engine starts:** `node remote-sync.mjs run`.
- **polled sleep:** the sum of the `sleep` arguments the test's processes issued, from readiness/stop polls and the test's own waits. It is time spent polling for an event, not a fixed wait.

The exec count is local. Every test below has a macOS/ubuntu ratio of 1.6-3.8, so it is process-bound.

| # | title | macOS s | ubuntu s | mac/ubu | driver (counts from a local strace run) |
|---|---|---|---|---|---|
| 86 | remote pull and connect: announce the client version, and 'unknown' when VE... | 11.5 | 4.4 | 2.60 | fixture + remote.sh disconnect x3, connect x2, pull x2; +1 mock server, 4 engine starts, 4.6s polled sleep (2680 execs) |
| 11 | set-endpoint: moves a connected team with history to a new address of the s... | 10.5 | 3.6 | 2.89 | fixture + remote.sh set-endpoint x2, connect; +1 join, 2 engine starts, 1.9s polled sleep (1373 execs) |
| 70 | status --json (aggregate): a team whose config could not be read gets an ex... | 9.5 | 4.3 | 2.21 | fixture + remote.sh connect x2, status; +2 join, 2 engine starts, 1.2s polled sleep (1670 execs) |
| 68 | status --json: with no <team>, emits one JSONL line per connected team | 9.5 | 3.4 | 2.79 | fixture + remote.sh connect x2, status; +1 join, 2 engine starts, 2.2s polled sleep (1638 execs) |
| 69 | status: a team name containing a single quote doesn't break status or statu... | 9.5 | 2.5 | 3.75 | fixture + remote.sh status x2, connect; +1 join, 1 engine start, 0.9s polled sleep (870 execs) |
| 146 | connect: flipping between two servers keeps one archive entry per server (#... | 9.3 | 3.5 | 2.69 | fixture + remote.sh connect x4; +1 mock server, 4 engine starts, 1.5s polled sleep (1774 execs) |
| 58 | status: with no <team> lists every locally-known connected team | 8.4 | 3.3 | 2.52 | fixture + remote.sh connect x2, status; +1 join, 2 engine starts, 2.5s polled sleep (1558 execs) |
| 75 | status <team> [--json]: the human and --json forms classify every config sh... | 8.2 | 3.4 | 2.41 | fixture + remote.sh status x14, connect; +1 join, 1 engine start (1035 execs) |
| 149 | remote status: a path-bearing archived endpoint is displayed host-only, kep... | 6.9 | 3.1 | 2.25 | fixture + remote.sh connect x3, status; +1 mock server, 3 engine starts, 1.6s polled sleep (1361 execs) |
| 145 | connect: a round trip A -> B -> A restores A's binding and its partition ro... | 6.7 | 2.9 | 2.34 | fixture + remote.sh connect x3; +1 mock server, 3 engine starts, 1.2s polled sleep (1264 execs) |
| 100 | remote pull: applies seven roster events alongside seventy-three messages | 6.5 | 3.2 | 2.02 | fixture + remote.sh pull; +1 mock server (836 execs) |
| 56 | connect: a second connect does not re-register, it resumes (Done-when 5, #143) | 6.3 | 2.1 | 2.97 | fixture + remote.sh connect x2; 2 engine starts, 1.3s polled sleep (788 execs) |
| 12 | set-endpoint: an unclearable cycle record does not cost the running engine ... | 6.1 | 2.2 | 2.81 | fixture + remote.sh connect, set-endpoint; 1 engine start, 1.1s polled sleep (877 execs) |
| 144 | connect: pointing at a different server archives the replaced binding (#849) | 6.0 | 2.4 | 2.52 | fixture + remote.sh connect x2; +1 mock server, 2 engine starts, 1.5s polled sleep (999 execs) |
| 101 | remote pull: a stream that carried the roster keeps the ordinary advice (#743) | 5.8 | 2.9 | 1.99 | fixture + remote.sh pull; +1 mock server, 1 engine start, 1.1s polled sleep (938 execs) |
| 93 | remote pull: a same-named different team is refused WITH a way out (#680) | 5.7 | 2.8 | 2.05 | fixture + remote.sh pull x2; +1 join (748 execs) |
| 130 | remote pull: the unlock line it prints can actually be run | 5.6 | 2.2 | 2.54 | fixture + remote.sh pull, unlock; +1 mock server (535 execs) |
| 148 | remote status: shows the replaced endpoint after a re-point (#849) | 5.4 | 2.3 | 2.35 | fixture + remote.sh connect x2, status; +1 mock server, 2 engine starts, 1.7s polled sleep (956 execs) |
| 107 | remote pull: an observed age envelope prevents plaintext push | 5.3 | 2.3 | 2.30 | fixture + remote.sh pull; +1 mock server (564 execs) |
| 96 | remote pull: the way out survives a team with a space and a quote (#680) | 5.3 | 2.0 | 2.65 | fixture + remote.sh pull; +1 join (518 execs) |
| 17 | set-endpoint: an engine started while it runs ends up running on the new ad... | 5.2 | 2.6 | 1.99 | fixture + remote.sh connect, set-endpoint, sync; 3 engine starts, 5.6s polled sleep (968 execs) |
| 91 | remote pull: refuses a team that already has history | 5.2 | 2.1 | 2.47 | fixture + remote.sh pull; +1 join (538 execs) |
| 65 | status --json: reports state=disconnected after disconnect | 5.1 | 1.9 | 2.77 | fixture + remote.sh connect, disconnect, status; 1 engine start, 1.3s polled sleep (978 execs) |
| 19 | connect: the printed recovery command is shell-safe for a hostile team name | 5.1 | 2.6 | 1.97 | fixture + remote.sh connect x2; +1 join, 1 engine start, 1.4s polled sleep (897 execs) |
| 151 | remote status: an archived endpoint stored by an older version with raw con... | 5.1 | 2.2 | 2.27 | fixture + remote.sh connect x2, status; +1 mock server, 2 engine starts, 1.4s polled sleep (814 execs) |
| 16 | set-endpoint: a legacy binding without a revision still cannot overwrite a ... | 5.0 | 2.3 | 2.20 | fixture + remote.sh connect, disconnect, set-endpoint; 1 engine start, 5.7s polled sleep (977 execs) |
| 152 | pull: re-pointing an already-bound team archives the replaced binding too (... | 5.0 | 2.6 | 1.89 | fixture + remote.sh pull; +1 join (712 execs) |
| 73 | status (aggregate, text): an unreadable team is reported and suppresses the... | 5.0 | 2.3 | 2.18 | fixture + remote.sh connect, status; +1 join, 1 engine start, 1.2s polled sleep (661 execs) |
| 88 | remote connect: a start refusal is reported, and the binding still stands (... | 5.0 | 2.3 | 2.12 | fixture + restart_mock_server + read-only engine pidfile + pull/connect whose engine start is refused (skipped in the local run, which was root, so no counts) |
| 54 | connect: starts a background sync engine that disconnect stops (Done-when 4) | 5.0 | 1.7 | 2.87 | fixture + remote.sh connect, disconnect; 1 engine start, 1.0s polled sleep (905 execs) |
| 99 | remote pull: the cloned team can be read with the ordinary commands | 4.9 | 2.0 | 2.45 | fixture + remote.sh pull (548 execs) |
| 9 | connect: refuses to re-anchor a binding to a different server instance | 4.9 | 2.4 | 2.03 | fixture + remote.sh connect x3, disconnect; 2 engine starts, 1.4s polled sleep (730 execs) |
| 125 | remote pull: a candidate failing field validation is refused, not shown | 4.8 | 2.3 | 2.09 | fixture + remote.sh pull x4; +4 mock server, 0.8s polled sleep (331 execs) |
| 55 | connect: mints team_id and member_ids for a team that predates local ids | 4.7 | 1.8 | 2.68 | fixture + remote.sh connect; 1 engine start, 1.4s polled sleep (541 execs) |
| 89 | remote pull: starts a background sync engine that disconnect stops | 4.6 | 2.2 | 2.14 | fixture + remote.sh disconnect, pull; +1 mock server, 1 engine start, 1.3s polled sleep (855 execs) |
| 106 | remote pull: no declaration is recorded as unknown, and unlock names the fix | 4.6 | 1.9 | 2.39 | fixture + remote.sh pull, unlock; +1 mock server (487 execs) |
| 72 | status <team>: the text form distinguishes unreadable from unconnected too,... | 4.5 | 2.3 | 2.00 | fixture + remote.sh connect, status; +1 join, 1 engine start, 0.9s polled sleep (646 execs) |
| 15 | set-endpoint: a concurrent disconnect is not overwritten by the verified wr... | 4.5 | 2.2 | 2.00 | fixture + remote.sh connect, disconnect, set-endpoint; 1 engine start, 4.8s polled sleep (922 execs) |
| 147 | connect: reconnecting to the same server does not create an archive entry (... | 4.5 | 2.2 | 2.08 | fixture + remote.sh connect x2; 2 engine starts, 1.3s polled sleep (783 execs) |
| 60 | disconnect: a pulled no-auth team does not report a failed credential revoke | 4.5 | 1.9 | 2.35 | fixture + remote.sh disconnect, pull (515 execs) |
| 103 | remote pull: a declared-sealed EMPTY team without the key does not start it... | 4.4 | 1.9 | 2.36 | fixture + remote.sh pull; +1 mock server (471 execs) |
| 74 | status <team> --json: a lock that cannot be acquired is reported as unreada... | 4.4 | 2.3 | 1.93 | fixture + remote.sh connect, status; +1 join, 1 engine start, 1.5s polled sleep (814 execs) |
| 124 | remote pull: --team-id still resolves a shared name | 4.4 | 1.9 | 2.34 | fixture + remote.sh pull; +1 mock server (473 execs) |
| 87 | remote pull: a start refusal is reported, and the pull still succeeds (#730) | 4.3 | 1.9 | 2.24 | fixture + restart_mock_server + read-only engine pidfile + pull/connect whose engine start is refused (skipped in the local run, which was root, so no counts) |
| 85 | remote pull: clones a team, keeping the id the server gave | 4.3 | 2.0 | 2.18 | fixture + remote.sh pull; +1 mock server, 1 engine start, 1.3s polled sleep (656 execs) |
| 26 | redaction: a cipher-profile mismatch does not print it | 4.2 | 1.8 | 2.32 | fixture + remote.sh connect x2; 1 engine start, 1.1s polled sleep (679 execs) |
| 97 | remote pull: a caller that owns the guidance gets the ids, not the routes | 4.2 | 2.0 | 2.16 | fixture + remote.sh pull; +1 join (507 execs) |
| 71 | status <team> --json: an unreadable config is distinguishable from a genuin... | 4.2 | 2.3 | 1.82 | fixture + remote.sh status x2, connect; +1 join, 1 engine start, 1.0s polled sleep (667 execs) |
| 25 | redaction: a roster mismatch does not print it | 4.2 | 1.8 | 2.31 | fixture + remote.sh connect x2; 1 engine start, 1.3s polled sleep (684 execs) |
| 20 | redaction: adoption success does not print the capability | 4.2 | 2.1 | 2.00 | fixture + remote.sh connect x2; 2 engine starts, 1.4s polled sleep (780 execs) |
| 95 | remote pull: a DISCONNECTED local team is still offered the rename (#680) | 4.2 | 2.0 | 2.10 | fixture + remote.sh pull; +1 join (519 execs) |
| 13 | set-endpoint: refuses a different server instance at the new address, namin... | 4.2 | 2.2 | 1.93 | fixture + remote.sh connect, set-endpoint; +1 mock server, 2 engine starts, 1.9s polled sleep (892 execs) |
| 102 | remote pull: an encrypted team with NO messages is still recorded as encrypted | 4.2 | 1.9 | 2.23 | fixture + remote.sh pull; +1 mock server (476 execs) |
| 129 | remote pull: a wrong protocol, server id, or root name is refused | 4.2 | 2.0 | 2.11 | fixture + remote.sh pull x3; +3 mock server, 0.6s polled sleep (307 execs) |
| 105 | remote pull: an unreadable local history stops the pull, loudly | 4.1 | 2.1 | 2.00 | fixture + remote.sh pull; +1 join, +1 mock server (504 execs) |
| 94 | remote pull: a CONNECTED local team is not told to rename itself (#680) | 4.1 | 2.0 | 2.07 | fixture + remote.sh pull; +1 join (517 execs) |
| 28 | connect: refuses to adopt a registration whose roster is not this team's | 4.0 | 1.8 | 2.23 | fixture + remote.sh connect x2; 1 engine start, 0.8s polled sleep (650 execs) |
| 62 | disconnect: no replacement can land while the engine it chose is being stopped | 4.0 | 1.9 | 2.10 | fixture + remote.sh connect, disconnect; 1 engine start, 1.8s polled sleep (629 execs) |
| 112 | remote unlock --authenticated-bundle-stdin: the captured bundle is 0600 wha... | 4.0 | 1.8 | 2.19 | fixture + remote.sh unlock; +1 join (485 execs) |
| 64 | status --json: reports the strict schema for an active connection | 4.0 | 1.8 | 2.21 | fixture + remote.sh connect, status; 1 engine start, 1.2s polled sleep (648 execs) |
| 48 | connect: when the server's name differs, it is quoted AS the server's — nev... | 4.0 | 2.4 | 1.64 | fixture + remote.sh connect; +1 join, +1 mock server, 1 engine start, 1.1s polled sleep (666 execs) |
| 92 | remote pull: refuses a team whose history is in the LEGACY table | 3.9 | 1.9 | 2.02 | fixture + remote.sh pull; +1 join (496 execs) |
| 121 | remote pull: a name is enough — no UUID is carried by hand | 3.9 | 1.9 | 2.06 | fixture + remote.sh pull (483 execs) |
| 14 | set-endpoint: re-running from the partial state repairs the stored sync con... | 3.8 | 1.9 | 2.03 | fixture + remote.sh connect, set-endpoint; 1 engine start, 1.4s polled sleep (700 execs) |
| 22 | redaction: an unreadable roster response does not print it | 3.8 | 1.8 | 2.11 | fixture + remote.sh connect x2; 1 engine start, 1.0s polled sleep (657 execs) |
| 53 | connect: moves the team into its own per-team store (Done-when 2) | 3.8 | 1.5 | 2.51 | fixture + remote.sh connect; 1 engine start, 1.1s polled sleep (432 execs) |
| 90 | remote pull: does not take a roster from the server | 3.7 | 1.8 | 2.11 | fixture + remote.sh pull (466 execs) |
| 18 | set-endpoint: refuses a disconnected team and names connect as the delibera... | 3.7 | 1.9 | 1.98 | fixture + remote.sh connect, disconnect, set-endpoint; 1 engine start, 0.7s polled sleep (786 execs) |
| 21 | redaction: an unreadable capabilities response does not print it | 3.7 | 1.7 | 2.14 | fixture + remote.sh connect x2; 1 engine start, 1.3s polled sleep (479 execs) |
| 8 | connect: a POST that committed but lost its response recovers on retry | 3.6 | 1.8 | 2.00 | fixture + remote.sh connect x2; 1 engine start, 1.5s polled sleep (527 execs) |
| 23 | redaction: a server-instance mismatch does not print it | 3.6 | 1.7 | 2.10 | fixture + remote.sh connect x2; 1 engine start, 0.7s polled sleep (475 execs) |
| 120 | remote connect without --e2ee: a broken SHA-256 tool does not block it | 3.5 | 1.5 | 2.35 | fixture + remote.sh connect; 1.1s polled sleep (436 execs) |
| 61 | disconnect: refuses when the binding was replaced after it chose one | 3.5 | 1.8 | 1.99 | fixture + remote.sh connect, disconnect; 0.9s polled sleep (522 execs) |
| 24 | redaction: a team-name mismatch does not print it | 3.5 | 1.8 | 1.95 | fixture + remote.sh connect x2; 1 engine start, 1.0s polled sleep (623 execs) |
| 150 | connect: refuses an endpoint carrying a raw control byte (#849) | 3.4 | 1.6 | 2.15 | fixture + remote.sh connect x2; 1 engine start, 1.5s polled sleep (444 execs) |
| 59 | disconnect: stops the engine and clears local state | 3.2 | 1.7 | 1.90 | fixture + remote.sh connect, disconnect; 1 engine start, 1.2s polled sleep (935 execs) |
| 29 | connect: the capability path never reaches the terminal | 3.1 | 1.6 | 1.97 | fixture + remote.sh connect; 1 engine start, 1.3s polled sleep (433 execs) |

## Proposals

### 1. Pin `AGMSG_AGENT_PID=""` in `setup()` (test-only, one line)

- **What to change:** add `export AGMSG_AGENT_PID=""` after `setup_test_env` (L6), before `join.sh` (L19).
- **What the variable does:** it is the documented test hook for this exact walk (`resolve-project.sh:483-498`: "This makes instance-id keying (#93) deterministic for the test suite regardless of the ambient process tree"). An empty value makes `agmsg_agent_pid` return 1 at once, and `agmsg_resolve_project` (`:710-736`) then goes on to its ancestor/git/pwd fallbacks.
- **Why it changes no result:** on CI the walk climbs to pid 1, finds no agent and returns 1 — the same branch. Locally, under Claude Code, it finds the `claude` process, looks for `run/proj.<pid>.project` in the fresh sandbox, finds none, and falls through to the same place.
- **What else reads it:** nothing in `remote.sh`, the engine or the drivers. `remote.sh` only takes `_agmsg_pid_alive_local` from `instance-id.sh` (L66-72).
- **Precedent:** 14 other files already export this, e.g. test_doctor.bats `setup()`, test_self_name.bats:30, test_delivery.bats:10. It also covers the about 23 in-test `join.sh` calls (tests 11, 19, 48, 68-75, 91-97, 105, 112, 152) and the ones run in `PEER_SKILL_DIR`.
- **Tests:** all 152.
- **Estimate: ~110 s macOS / ~90 s ubuntu per full run** (about 175 calls × 0.65 / 0.52 s). The basis is the fixture decomposition above. The exec-count lower bound is 60 s / 23 s.
- **test_only:** yes. **Coverage risk:** none. No assertion in this file is about project resolution; test_resolve_project.bats owns the walk.

### 2. Build the joined fixture once per file and copy it per test (test-only)

- **What to change:**
  - Add a `setup_file()` that runs, inside a subshell so nothing leaks into later tests: `setup_test_env`, the pinned `join.sh testteam alice claude-code /tmp/project-a`, then moves the result to `$BATS_FILE_TMPDIR/template`.
  - In `setup()`, replace L6 and L19 with the cheap half of `setup_test_env`: two `mktemp -d`, `cp -Rp "$BATS_FILE_TMPDIR/template/." "$TEST_SKILL_DIR"`, the `HOME`/`TMPDIR`/`SCRIPTS`/`TYPES` exports, and an `AGMSG_TEST_REAL_TMPDIR` default.
  - `teardown()` is unchanged.
- **Why it is safe:**
  - `join.sh` writes three files: `teams/testteam/config.json`, `teams/testteam/roster.jsonl` and `db/messages.db`. None of them names the sandbox path (checked with `rst/remote_setup_bench.sh`). WAL is checkpointed when sqlite3 exits, so copying `messages.db` is enough.
  - Each test still gets its own private copy, so mutation stays per test.
- **What changes:**
  - `team_id`/`member_id` and `created_at` are the same in every test instead of fresh. That is harmless because every test has its own fresh mock server. `PEER_SKILL_DIR` tests join on their own.
  - Tests that call `teardown_test_env`/`setup_test_env` again inside their body keep working, because `setup_test_env` is untouched.
- **What it saves per test, on top of #1:** the pinned `join.sh` (~0.45 / 0.15) plus `init-db.sh` and the three chmods (~0.08 / 0.04).
- **Tests:** all 152.
- **Estimate: ~75 s macOS / ~27 s ubuntu on top of #1.** Basis: test_doctor.bats floor, × 152. Without #1 it would save ~180 / ~110, and the in-test joins would keep the walk.
- **test_only:** yes. **Coverage risk:** low. The fixture's state is byte-identical except for the shared IDs and timestamps, and no test reads a join timestamp.

### 3. Merge tests that rebuild the same expensive arrange (test-only)

Every assertion is kept; only test boundaries change. This file already writes multi-step stories (test 9, test 86), so longer tests fit its style.

- **a. Test 58 (L1152) into test 68 (L1355).**
  - Both connect `testteam`, join a second team, connect it, then read the aggregate status (58 the text form, 68 `--json`).
  - Append 58's `run remote.sh status` and its two name checks to 68.
  - **Saves 58 minus one status call: ~8.0 / ~3.1.**
- **b. Tests 71, 72 and 73 (L1417, L1431, L1445) into one test.**
  - All three run the same `join beta` + `connect beta` + `_truncate_team_config beta`, then read the state:
    - 71: `status beta --json` and `status ghostteam --json`
    - 72: `status beta`, plus the "Error: stepping" check
    - 73: aggregate `status`
  - All are reads of one state.
  - **Saves two arranges: ~8.9 / ~4.3.**
  - Test 74 (L1456, lock variant) could join as a first step with a valid config, before the truncation: another ~4.0 / ~2.1. That is left optional because its injection differs.
- **c. Test 148 (L3225) into test 144 (L3139).**
  - Same steps: connect to A, start the second server, connect to B. 148 then only adds `status` and two greps.
  - **Saves ~5.1 / ~2.2.**
- **d. Test 146 (L3199) into test 145 (L3165).**
  - 146 is 145's A → B → A followed by one more connect to B, then asserts `previous_count = 1` and `previous_bindings[0]` is A.
  - Append that connect and the two assertions to 145's end.
  - **Saves 146 minus one connect: ~8.0 / ~2.95.**

- **Tests:** 58, 68, 71-73, 144-146, 148.
- **Estimate: ~30 s macOS / ~12 s ubuntu.** Basis: the CI seconds of the removed tests, minus 0.3 / 0.1 s per status call that moves and 1.3 / 0.5 s per connect that moves.
- **test_only:** yes. **Coverage risk:** low. Nothing is dropped, but a failure early in a merged test hides the later checks' verdicts, and the test names get longer.

### 4. Give the 43 tests that never contact the mock server their own file (test-only)

- **What to change:** move these tests to e.g. `tests/test_remote_offline.bats`, whose `setup()` is `setup_test_env` + pinned `join.sh`, with no python server and no `cleanup_sync_engines`:
  - doctor tests 1, 2, 80-84, 115-118 and 131-143
  - endpoint refusals before the network: 3, 4, 6, 7, 46
  - python3-absent tests 77-79
  - tests 27, 31, 33, 57, 63, 66, 67, 76, 108, 112, 114
- **How they were found:** no `ENDPOINT`, `MOCK_`, `mock_server`, `_test/` or capability helper anywhere in the test's region (`rst/remote_server_use.tsv`).
- **Why join is kept:** test 2 reads `testteam`'s config, and the doctor sweep would see a different team set without it.
- **Precedent:** the repo already splits remote coverage across 15+ `test_remote_*.bats` files.
- **Tests:** the 43 above.
- **Estimate: ~8 s macOS / ~5 s ubuntu.** Basis: 43 × (python start + first 0.1 s tick + kill), ~0.2 / ~0.12 each.
  - Shard balance is an extra benefit: this is the heaviest file (557 s macOS here; 471 s in `.github/scripts/bats-file-seconds.tsv`).
  - It did not sit on the critical shard in this run: macOS shard 5 totalled 1177 s against 1382 s on shard 3.
- **test_only:** yes. **Coverage risk:** low. The moved tests never reach the server, and a moved test that turns out to need it fails loudly, it cannot pass silently.

### 5. Two small poll fixes (test-only)

- **a. Mock-port wait.**
  - `wait_for_file_contains` (test_helper.bash:454-461) checks first, then sleeps 0.1 s; each tick runs `grep`.
  - The port file is created empty by the redirect before python starts (L32), so the first check always fails and every server start pays at least one full 0.1 s tick.
  - Replace the three call sites (L34, L106, L3115) with a local loop: `read -r p < file` + `case` (no exec) and `sleep 0.02`. Keep the 30 s ceiling.
  - About 187 starts per run. Saves ~30-40 ms each on ubuntu; on macOS the extra `sleep` execs eat most of the gain.
- **b. Engine reap in teardown.**
  - `cleanup_sync_engines` (L40-62) sends TERM, then `wait_for_pid_exit` checks at once and then every 0.1 s.
  - The engine exits synchronously in its TERM handler (`remote-sync.mjs:4643-4649`), so the first 0.1 s tick is pure waste.
  - Poll 20 × 0.01 s first, then 0.1 s. This is the cadence `agmsg_stop_pid` already uses (test_helper.bash:600-604); that helper itself cannot be used, because the engine is not a job of the test shell.
  - About 60 waits per run (`ps -o stat=` count in the local trace).
- **Estimate: ~5 s macOS / ~9 s ubuntu combined.** Basis: (a) 187 × ~0.01 s macOS / ~0.03 s ubuntu; (b) ~55 waits × ~0.05 / ~0.065 s.
- **test_only:** yes. **Coverage risk:** none. Both remain event waits with the same ceilings.

### 6. Optional: change mock knobs at runtime instead of restarting the server (test-only)

- **What to change:**
  - 27 `restart_mock_server` call sites (L740-2891) restart python only to change a knob that `mock_remote_server.py` reads from the environment at startup:
    - `MOCK_TEAM_CIPHER_PROFILE` (14 sites)
    - `MOCK_PULL_AGE*` (12)
    - `MOCK_LOOKUP_BAD`, `MOCK_PULL_TEAM_ID`, `MOCK_DUPLICATE_NAME`, `MOCK_HEALTH_TEAM_ID`, `MOCK_CONNECT_*`
  - A `/_test/knobs` endpoint (the server already has `/_test/rotate-server-id` and `/_test/drop-next-connect`) would turn each restart into one curl.
- **Tests:** the 27 sites. That is about 30 restarts per CI run (about 189 server starts, counting tests 87/88 − 152 in `setup()` − 7 `start_second_mock_server`), including the per-mode loop of `assert_lookup_rejected` (L2842).
- **Estimate: ~7 s macOS / ~3.5 s ubuntu.** Basis: 30 × (python start + tick + kill), ~0.25 / ~0.12.
- **test_only:** yes; it changes `tests/helpers/mock_remote_server.py`. **Coverage risk:** low-medium.
  - A restart also resets the server's registrations, so each site must be checked for relying on a fresh server.
  - The `setup()` comment (L7-10) shows the authors already guard against knobs leaking between tests.

## Risks and notes

- **Uncertainty of #1.** The CI cost of one walk is inferred from two angles:
  - the fixture decomposition (0.65-0.75 / 0.5-0.55 s)
  - test_team vs test_doctor (≥1.0 / ≥0.5 s)

  A pure exec-count model gives only 0.35 / 0.13 s. macOS runners are noisy: on the same shard, `join.sh` looked ~1.5 s in test_team.bats and ≤0.8 s in test_roster_journal.bats. The change is one line, so one CI run settles the number.
- **Totals are not additive.**
  - #2 removes the `setup()` join, which takes most of #1's saving with it. #1 + #2 together come to about 190 s macOS / 120 s ubuntu.
  - #3 and #4 are measured against today's per-test cost, so they shrink by about 1.2 / 0.7 s per removed test once #1-#2 land.
- **Considered and not proposed:**
  - **Shortening connect's readiness wait** (`AGMSG_TEST_SYNC_START_READY_SECONDS/_CEILING`, `remote.sh:3210-3233`). No test here runs that wait to its ceiling; it ends on the engine's capabilities marker.
  - **Skipping the engine start in tests that only need a binding.** `connect` has no flag for it, and adding one would change production code to save about 0.3-0.5 s per connect.
  - **Test 9's #1176 DIAG block.** It is cheap: a few greps and tails, printed only on failure. Leave it.
- **Suite-wide follow-up.** Pinning `AGMSG_AGENT_PID=""` belongs in every file that runs `join.sh`/`actas-claim.sh` without it. Two examples with the same symptom on CI:
  - test_team.bats: one `join.sh` ≈ 1.6 / 0.75 s
  - test_roster_journal.bats

  Files that test the walk itself (test_resolve_project, test_instance_id, test_session_start_*) must keep their own handling, so this should stay per file, not go into `setup_test_env`.
- **What is in `rst/`:**
  - `remote_all.tsv`: per-test counts for all 152 tests
  - `test_remote.full.trace`: the raw trace, 246 MB
  - `remote_setup_bench.sh`, `walk_depth.sh`, `join_execs.sh`: the micro-benchmarks
