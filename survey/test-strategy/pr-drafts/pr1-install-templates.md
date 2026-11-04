Test-only.

test_install.bats is the slowest file in the suite: 764 s on macOS and 238 s on ubuntu in run 41607512279 (491-550 s on macOS in the #1884 measurement). Most of that is install.sh itself: a fresh install costs about 3.2 s on macOS and 0.95 s on ubuntu, and 65 tests begin with an install that is only there so the test has something to act on.

`_restore_install [--marker <dir>] [install.sh args]` builds each kind of install for real the first time a test asks for it (from this tree, with that test's environment, into an empty HOME under `$BATS_FILE_TMPDIR`), and later tests copy that tree. What they assert on is still the real installer's output.

What makes the copy equivalent:

1. An install writes its own HOME path into exactly three text files: the launcher, the Antigravity shim and `run/agmsg-launcher.path`. Only those are rewritten. Checked for all six templates used here (default, `--agent-type codex`, and the `.copilot`, `.config/opencode`, `.hermes` and `.gemini/config` markers): no symlinks, and no binary file holds the path. A default and a codex install differ only in `install_id` and `created_at`.
2. After the copy, the test fails if the template directory's name appears anywhere in the copy, in any file and any quoting. Probed: an installer that writes its path into one more text file, or into a binary file, turns the helper red.
3. Paths that need shell quoting (the installer writes some through `printf %q`) and Windows (Git Bash writes another path form) install for real every time.
4. The template's path is published by rename, so tests run with `bats --jobs` cannot read a half-written path.

65 tests switch: 48 that start from the default install, 7 from an `--agent-type codex` install, and 10 that create one agent marker directory first. Test 1 (the fresh-install smoke test) and the tests about what install.sh prints still run it themselves, and so does the first test that needs each template.

Measured locally (Linux container, 4 cores, bats 1.13.0, otherwise idle), whole file, before and after run alternately:

| | before | after |
|---|---:|---:|
| wall time, 2 runs each | 398 s, 379 s (mean 388 s) | 300 s, 301 s (mean 300 s, -23 %) |
| processes created, 2 runs each | 159,018, 159,002 | 120,285, 120,233 (-24 %) |
| tests | 118 ok | 118 ok |

Each run is in its own PID namespace (`unshare --pid --fork --mount-proc`), so the process count is exact: it is the last PID allocated inside the namespace. Inside it, pid 1 is the wrapper shell, so code that walks the process tree to pid 1 takes fewer hops than on a CI runner; compare the two columns, not against CI.

Expected in CI: 59 installs avoided at ~3.2 s macOS / ~0.95 s ubuntu, minus 65 copies at ~0.3 s / ~0.07 s, so about -170 s on macOS and -50 s on ubuntu for this file. This PR's own bats-timings artifacts will show the real figure.

Not in this PR (follow-ups from the same analysis):

1. Test 94 keeps a newline-named fixture in scripts/ through both updates, which makes the manifest fall back to per-file sha256 (about 14 s extra on macOS).
2. Test 97 runs 20 installs one after another (about 41 s on macOS could be saved by running the per-type pairs in parallel).
3. install.sh runs one `cmp` per shipped file (256) on every `--update`; a batched comparison would speed up every install run in every suite. That is a product change.

Checks run: `bats tests/test_install.bats` 118/118 before and after; `.github/scripts/check-enforced-assertions.sh` at the baseline (610); `AGMSG_PRIVATE_NAMES=none node scripts/check-private-names.mjs` clean; the converted tests with a TMPDIR that contains a space give the same results as main.
