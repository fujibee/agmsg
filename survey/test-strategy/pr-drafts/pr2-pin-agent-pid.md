Test-only.

join.sh, watch.sh, session-start.sh and the other entry scripts look for an agent ancestor by walking the process tree to pid 1 (`agmsg_agent_pid`, scripts/lib/resolve-project.sh): about 3 `ps` calls per hop, and 10-11 hops on a CI runner. With no agent ancestor, which is the CI case, the walk finds nothing. That is exactly the answer `AGMSG_AGENT_PID=""` gives at once (#93), and 15 test files already pin it in `setup()` for that reason. This pins it in 26 more.

How the files were chosen:

1. Candidates: every file that runs an entry script that walks (join.sh, whoami.sh, actas-claim.sh, watch.sh, reset.sh, session-start.sh, session-end.sh, check-inbox.sh, spawn.sh) and did not already pin the variable in `setup()`. That is 59 files.
2. Each candidate was read for a test that builds an agent ancestor, relies on `CLAUDE_PID`, or asserts a pid-keyed instance id, owner or lock. 57 have none. Two have one test each that exercises the walk (test_local_team_ids.bats #4, test_watch_process_count.bats #1). A second pass that tried to refute each "safe" verdict found nothing. Tests that need a specific pid already pass their own `AGMSG_AGENT_PID`, and that still wins over the export.
3. Each candidate was run with and without the pin. The results were the same in every file.
4. This PR takes the 26 files that saved at least 5 s locally. Left alone: test_resolve_project.bats (the walk's own file), the two files above, and files that save little.

test_watch.bats, test_watch_install_changed.bats and test_watch_agmsgd_note.bats pinned it on MSYS2 only, because there the walk could give watch.sh and the test's own `_iid` different instance ids. They now pin it on every host, which also keeps their expectations true when the suite runs under an agent process.

Measured locally (Linux container, 4 cores, bats 1.13.0, two files at a time):

| | before | after |
|---|---:|---:|
| the 26 files, total wall time | 2618 s | 1987 s (-24 %) |
| one join.sh, processes created (2 runs) | 325, 347 | 275, 274 |
| one join.sh, execs (2 runs) | 135, 126 | 108, 106 |

The process tree in that container is 5 levels deep. On a CI runner the walk takes 10-11 hops, so each call saves more there. In run 41607512279 the 26 files took 3683 s of macOS and 2309 s of ubuntu bats time; at the local -24 % that is about -880 s on macOS and -550 s on ubuntu per full run. This PR's own bats-timings artifacts will show the real figure.

Checks run: the 26 files on this branch, with the same results as a run with the variable set from the environment and as a run without it. The tests that fail in that container fail the same way in all three runs: tests whose fixture makes a write fail through chmod (the container runs as root, so the write succeeds) and engine-timing tests in test_remote.bats. `.github/scripts/check-enforced-assertions.sh` is at the baseline (610); `scripts/check-private-names.mjs` is clean.
