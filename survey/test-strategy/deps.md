# Changed files -> affected bats files: can agmsg compute it mechanically?

Survey of `fujibee/agmsg` @ `551764e` (read-only): 155 `tests/*.bats`, 958 tracked files (257 under `scripts/`).
Everything here was produced by the scripts in this directory; numbers below are from the run recorded in
`compare_summary.json`, `select_sim.json` and `patterns.json` (dynamic coverage: see "Data").

## Verdict

1. **Yes, the mapping can be computed mechanically, with high recall.** `static_deps.py` (a ~1200-line regex
   analyzer, no shell parser) recovers 0.996 of the repo files that strace saw the 67 traced test files open
   (micro recall, "call" closure; 63/67 files have recall 1.0). All 5 residual (test file, file) misses are top-level non-code files (`VERSION`, `package.json`, `README.md`): 2 are fixture files the dynamic mapper took for repo files, 1 is node's implicit `package.json` lookup, 2 are unexplained `README.md` opens (see "Biggest misses").
2. **It breaks in predictable places**, listed with counts and file:line in "Patterns": data-driven registries
   (driver/type/terminal dirs chosen at runtime, `template=` in `type.conf`), paths handed to functions or to an
   interpreter held in a variable, inline `bash -c 'source "$1"' _ PATH`, whole-tree readers (git grep, CI
   scanners, node fixtures that copy or digest `scripts/`), OS branches that a Linux trace never takes, and files
   generated at test time (rendered `SKILL.md`, install manifests).
3. **Precision is low** (micro 0.216 for "call"): static closures average 93.6 files per test file vs
   20.3 actually opened. The over-approximation is structural (all storage/partition drivers, all type
   templates, all ext-tool manifests, macOS-only helpers, mentions in hint strings).
4. **The gain from impact selection is limited by a shared core, not by the analyzer.** 107/155 files call
   `setup_test_env`, which runs `scripts/internal/init-db.sh` -> `scripts/lib/storage.sh` -> `compat.sh`,
   `validate.sh`, `sqlpath.sh` (opened by every traced setup_test_env user), and statically also
   `driver-registry.sh`, `plugin-cmd.sh` and the storage drivers (loaded lazily, so opened by fewer). A change to
   any of those selects 130-133 test files (97% of CI seconds). Replaying the last 300 first-parent commits on main
   (`a32136d..551764e`), the robust selector picks on average 60.2% of CI seconds per commit (median
   77.5%); the distribution is bimodal: 35% of commits (docs/app/test-only) need < 20%, 62%
   need >= 70%, and 27% need >= 95%.

## Outputs in this directory

| file | content |
|---|---|
| `static_deps.py` | the analyzer: `python3 -I static_deps.py <repo> <outdir>` (about 7 s) |
| `static_closure.tsv` | **recommended static closure** (`test_file, dep_file, via`), = the "call" mode below |
| `static_closure_strict.tsv` / `_call.tsv` / `_loose.tsv` | the three recursion modes (same columns) |
| `edges.tsv` | per-file edges `src_file, dep_file, kind, qual, line` for every file reached |
| `unresolved.tsv` | sites the analyzer flagged: dynamic source/exec, eval, repo-wide scans, registry data, JS computed paths |
| `patterns.py`, `patterns.json`, `patterns.tsv` | regex census of the idioms in "Patterns" (counts + every matching line) |
| `compare.py`, `compare_per_test.tsv`, `compare_summary.json` | static vs strace, per test file and aggregated |
| `fanin.tsv` | for every file: how many test files depend on it (strict / call / loose / strace / call-or-strace) |
| `select_sim.py`, `select_sim.json`, `select_sim_commits.tsv` | replay of 300 main commits through the selector, priced in CI seconds |
| `extract_reads_norm.py`, `keep_traces.sh`, `dyn_reads/` | re-extraction of the strace traces with `..` normalized (see "Data") |
| `README.tmpl.md`, `fill_readme.py` | this file is rendered from the template with the current numbers |
| `probe_readme/` | the one single-test retrace (`bats -f 'umask 002' tests/test_binding_mode.bats`) used to chase a `README.md` read |

`via` reads `<kind>[+<qual>]:<referencing file>:<line>` for the first edge (BFS) that reached the dep, or
`self`, `load`, `helper(<fn>)>...:tests/test_helper.bash:<line>`. kind = `source | exec | call | assign | data`;
qual = `glob` (explicit `*` in the source), `dyn` (wildcard standing for an unresolved variable), `suffix` (base
unknown, matched by path suffix), `scan` (directory expanded because a grep -r/find/git grep reads it),
`manifest:<fn>` (file named by a `type.conf` key that `<fn>` dereferences), `import`, `join`, `name`, `literal`.

## How `static_deps.py` resolves dependencies

Per test file it seeds: the file itself; `load`ed helpers; and only the `tests/test_helper.bash` functions the
file calls (plus the helpers those call): `setup_test_env` contributes `bash "$TEST_SKILL_DIR/scripts/internal/init-db.sh"`
(test_helper.bash:81), `_ready_path` contributes `scripts/lib/actas-lock.sh` (:229), `bulk_send_direct` contributes
`scripts/lib/storage.sh` (:775), `agmsg_renderable_types` contributes `scripts/lib/type-registry.sh` (:267),
`_decoy_cmdline` contributes `scripts/lib/compat.sh` (:728). The `cp -R scripts/.` at :70 and the `chmod` globs at
:71-78 are not counted as reads (they copy, they do not read).

Then, for the test file and transitively for every shell / node / python file it reaches, it extracts every
path expression and resolves it against `git ls-files`:

* **Bases.** `$SCRIPTS`->`scripts/`, `$TYPES`->`scripts/drivers/types/`, `$BATS_TEST_DIRNAME`->`tests/`,
  `$TEST_SKILL_DIR`/`$SKILL_DIR` in tests -> skill root but only its `scripts/` subtree (that is all
  `setup_test_env` copies; `$TEST_SKILL_DIR/VERSION` is a sandbox file), `$SKILL_DIR` in product code -> skill
  root, `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, `$(dirname "$0")`, `${BASH_SOURCE%/*}` -> the file's
  own dir, `$(cd X && pwd)` -> X, `$(git rev-parse --show-toplevel)` -> root. Every other variable is resolved
  from all its assignments in the same file (`x=...`, `local/export/readonly x=...`, `${x:=...}`, `${x:-default}`,
  `for x in <words or globs>`), flow-insensitively, recursively (memoized, cycle-guarded).
* **Positional parameters.** `$1..$3` inside a function take the literal words of that function's call sites in
  the same file: `scripts/windows/dispatch.sh:96-98` `run_script() { local script="$1"; bash "$SCRIPT_DIR/../$script" ... }`
  resolves to the 17 `run_script inbox.sh|send.sh|join.sh ...` call sites instead of 43 files under `scripts/`.
* **Unknown base.** Suffix matching: `.../skills/<name>/<rest>` -> `<rest>` at the root (install sandboxes such as
  `$FAKE_HOME/.agents/skills/agmsg/scripts/send.sh`), else the longest suffix of the path that names tracked files
  (`$1/lib/hash.sh` -> `scripts/lib/hash.sh`); one-component suffixes only if distinctive (`_delivery.sh`,
  `type.conf`) and <= 15 matches; a suffix must keep a literal component; a trailing `/` or a bare variable as last
  component means "directory".
* **Wildcards.** An explicit glob counts as all its matches ("a loop over a glob is all matches"); a variable
  inside a path becomes `*` (`$base/storage/$name.sh` -> `scripts/drivers/storage/*.sh`) and is kept only while it
  matches <= 25 files.
* **Scans.** On a line with `grep -r/-R/--include`, `git grep`, `git ls-files`, `find`, `.rglob(` or `os.walk(`, a
  path that resolves to a repo directory expands to every file under it (filtered by `-name`/`--include`);
  `git grep` in a test with no narrowing pathspec (exclusions `:!x` do not narrow) expands to the whole tree.
  `cd DIR` / `git -C DIR` / `pushd DIR` targets are working directories, not scan roots.
* **Edge kinds** come from the command word of the pipeline segment the path sits in: `source X`/`. X`
  (also `bash -c 'source X'`, `BASH_ENV=X`) -> `source`; path in command position or after
  `bash/sh/node/python3/exec/run/timeout/xargs/env` or after an interpreter held in a variable
  (`"$node_path" "$SCRIPT_DIR/daemon/channels/storage-gate.mjs"`, daemon.sh:1103) -> `exec`; after a known read-only
  command (`grep cat sed awk head cp ln [ test printf echo jq git sqlite3 ...`) or a redirect -> `data`; `x=PATH` and
  `for x in PATH` -> `assign`, upgraded to `source`/`exec`/`call` where `$x` is later used that way; after any
  other word (a shell function such as `agmsg_sync_autostart`) -> `call`.
* **Registry manifests.** For keys in `scripts/drivers/**/*.conf` whose value names a file (`template=` in 10
  `type.conf`, `spawn_wrapper=codex-shim.sh`), the functions whose body does `agmsg_type_get <name> <key>`
  (`agmsg_type_template_path`, `_agmsg_renderable_types`, `is_terminal_template`) are found, and every file that
  calls one gets edges to all files that key names.
* **JS/Python.** Relative `import ... from`, `import()`, `require()`, `new URL('./x', import.meta.url)`;
  `join(...)`/`path.join(...)`/`resolve(...)` evaluated over `__dirname`, `import.meta.dirname`,
  `dirname(fileURLToPath(import.meta.url))` and constants derived from them (`daemon/db.mjs:10` ->
  `scripts/daemon/schema.sql`); string literals that start with a top-level dir; bare `'identities.sh'` literals
  (codex-bridge.js:352 `runScript("identities.sh", ...)`); python `HERE/'x'`.
* **Sandbox rule.** A test that does not run `install.sh`/`setup.sh`/`uninstall.sh`/`bin/agmsg.js` only has
  `scripts/` in its skill dir, so edges from `scripts/**` to files outside `scripts/` (`$SKILL_DIR/VERSION` in
  codex-monitor.sh:285, remote-sync.mjs:52) are dropped for it. Without this, every `VERSION` bump (20 of the last
  300 commits) selected 72 test files.
* **Recursion modes.** `strict` follows only `source`/`exec` edges (a script that is grepped, copied or named in
  a message is a leaf); `call` also follows `call` edges; `loose` follows everything. Another test file reached by
  a scan (`find tests -name '*.bats'`) is always a leaf.

Closure sizes over all 155 files (files per test file): strict median 65 (p25 27, p75 101), call median 101 (p25 34, p75 177),
loose median 212 (p25 212, p75 214); one file (`test_capability_docs.bats`, `git grep` over the tree at :32) is 958.

## Static vs dynamic (strace) read-sets

### Data and its caveats

The background sweep (`tools/strace_sweep.sh`, `strace -f -e trace=execve,openat`) writes one
`survey/strace/reads/<test>.tsv` per finished file; 72 of 155 existed when this was last run (the sweep goes
alphabetically, 3 files at a time: `test_actas_integration` .. `test_locator` were done except `test_delivery`, `test_install` (still running), and the rest
of the alphabet (`test_remote*`, `test_spawn`, `test_watch*` ...) had not started). Four properties of that data
matter:

1. **The sweep's extractor drops every path containing `..`** (`tools/extract_reads.py` maps without
   `normpath`), e.g. `/tmp/X/scripts/internal/../lib/storage.sh` from init-db.sh:5 or
   `/home/user/agmsg/tests/../scripts/x.sh`. `keep_traces.sh` hard-links each raw trace while the sweep writes it and
   `extract_reads_norm.py` re-extracts it with `..` normalized: on the 26 files caught this way it recovered
   25 (test file, repo file) pairs in 13 of them (`test_dispatch` alone +6: every script
   `dispatch.sh:98` runs through `$SCRIPT_DIR/../$script`; `storage.sh` for test_hash/test_herdr_cli_routing/
   test_ext_tool_*). The other files use the original, so their dynamic sets undercount: among the traced
   setup_test_env users that only have the original extraction, 18/18 open `init-db.sh` but only 11 show
   `storage.sh`, which init-db.sh:5 sources for every one of them through `$SCRIPT_DIR/../lib/storage.sh`.
2. **Copies done by node are counted as reads.** The sweep only filters `cp/rsync/tar/...` by process name;
   `tests/agmsgd_status_display.test.mjs:15` `cpSync(join(repo,'scripts'), ...)` makes `test_agmsgd_status` "read"
   215 files exactly 11 times each.
3. **Fixture files whose path suffix names a tracked file are mapped to it.** `test_cut_release.bats:35-36` writes
   `$BATS_TEST_TMPDIR/repo/VERSION` and `.../package.json`; the mapper reports them as the repo's `VERSION` and
   `package.json`.
4. **Linux only, openat only.** macOS-only branches are absent, and `[ -f X ]`/`[ -x X ]` (stat) are invisible, so a
   static dep that is only existence-checked never shows up as "read".

Test files that open >= 150 repo files are **whole-tree readers** and are reported apart instead of scored:
`test_agmsgd_daemon_sh.bats` (strace 259 files, static call closure 195); `test_agmsgd_entrypoint.bats` (strace 259 files, static call closure 195); `test_agmsgd_status.bats` (strace 261 files, static call closure 198); `test_capability_docs.bats` (strace 483 files, static call closure 958); `test_enforced_assertions.bats` (strace 157 files, static call closure 157).

### Results (67 scored test files)

| mode | avg static deps (these files) | micro precision | micro recall | macro precision | macro recall | files with recall 1 |
|---|---|---|---|---|---|---|
| strict | 69.9 | 0.286 | 0.986 | 0.414 | 0.985 | 58/67 |
| call (recommended) | 93.6 | 0.216 | 0.996 | 0.369 | 0.994 | 63/67 |
| loose | 170.9 | 0.118 | 0.997 | 0.263 | 0.995 | 64/67 |

Dynamic sets average 20.3 files on the same test files. Over all 155 files the average closure is
82.0 (strict), 115.7 (call), 196.6 (loose) files.

### Biggest misses (strace opened it, the static closure does not have it)

"call" mode, all remaining pairs:

| test file | file | why |
|---|---|---|
| `test_binding_mode.bats` | `README.md` | opened 7 times from the checkout (cwd-relative); origin not identified (raw trace gone); one single-test retrace (`bats -f 'umask 002'`) did not reproduce it |
| `test_codex_bridge.bats` | `package.json` | 5 successful opens next to 356 failed probes: node's module-type lookup walks parent dirs for `package.json`; the successful ones are a fixture or the checkout's own file -- an implicit read no static rule sees |
| `test_cut_release.bats` | `VERSION` | dynamic artifact: test_cut_release.bats:35 writes `$BATS_TEST_TMPDIR/repo/VERSION` (a fixture), mapped by path suffix to the repo file |
| `test_cut_release.bats` | `package.json` | dynamic artifact: test_cut_release.bats:36 writes `$BATS_TEST_TMPDIR/repo/package.json` |
| `test_instance_id.bats` | `README.md` | opened 7 times from the checkout itself (`where=repo` in dyn_reads); origin not identified |

Additional misses of "strict" mode (fixed by "call"): `scripts/lib/{operator-guidance,shquote,require-python3}.sh`
in `test_codex_bridge_launcher` and `test_harness_self_name_off` (they are sourced by `remote.sh`, which runs only
because `actas-claim.sh:324` / `session-start.sh:339` pass `"$SKILL_DIR/scripts/remote.sh"` to
`agmsg_sync_autostart`, which executes `"$remote_sh"` in `scripts/lib/sync-autostart.sh`), `scripts/lib/watch-stuck-map.sh`
in `test_despawn`, `scripts/lib/sqlite-output.sh` in `test_install_op_lock` (`source "$1"` with the path passed as an
argument). Earlier iterations of the analyzer also missed, and now resolve: `scripts/daemon/schema.sql` (7 files;
`join(dirname(fileURLToPath(import.meta.url)), "schema.sql")` without the `path.` prefix), the daemon modules behind
`"$running_node" "$SCRIPT_DIR/daemon/status.mjs"` (daemon.sh:695), the 10 `template.md` (type.conf `template=`),
and dispatch.sh's `run_script` targets.

### Biggest over-approximations (static dep, never opened under strace)

Number of the 67 scored files where the "call" closure has the file but strace never opened it:

| file | scored files where static-only |
|---|---|
| `scripts/drivers/ext-tools/slack/tool.conf` | 50 |
| `scripts/drivers/ext-tools/jev/tool.conf` | 50 |
| `scripts/drivers/storage/jsonl-read-cursor.jq` | 48 |
| `scripts/drivers/storage/jsonl-unread.duckdb.sql` | 48 |
| `scripts/drivers/types/antigravity/mac-process-info.py` | 48 |
| `scripts/agmsg` | 48 |
| `scripts/drivers/partition/per-team.sh` | 47 |
| `scripts/drivers/types/antigravity/bridge-read-guard.sh` | 47 |
| `scripts/drivers/types/antigravity/bridge-read-guard.mjs` | 47 |
| `scripts/drivers/storage/jsonl.sh` | 47 |
| `scripts/internal/jsonl-sync.mjs` | 47 |
| `scripts/daemon/liveness.mjs` | 47 |
| `scripts/daemon/executor.mjs` | 46 |
| `scripts/internal/sync-cipher.mjs` | 46 |
| `scripts/internal/wire-kinds.mjs` | 46 |
| `scripts/internal/strict-jsonl.mjs` | 44 |

They fall into: data-driven alternatives that this configuration never selects (`storage/jsonl.sh` and its
helpers `jsonl-sync.mjs`, `*.jq`, `*.duckdb.sql`; `storage/sqlite-sync.sh` -> `sync-cipher.mjs`,
`wire-kinds.mjs`, `strict-jsonl.mjs`; `partition/per-team.sh`); registry enumeration that only stats
(`ext-tools/*/tool.conf`, every `types/*/type.conf`); manifest-named files of other types (`types/*/template.md`);
macOS-only code (`antigravity/mac-process-info.py`, used under `Darwin`); lazily loaded code that file-level
reachability cannot rule out (`lib/bridge-read-guard.sh`, `daemon/liveness.mjs`, `daemon/executor.mjs`: loaded only
when a daemon/bridge is live); and mentions (`scripts/agmsg` named in plugin-cmd.sh:15's `printf 'bash %q'` hint).
A file-level analyzer cannot do better on these without function-level reachability or knowledge of the
configuration under test.

## Patterns the analyzer cannot (fully) resolve

Counts are lines (from `patterns.py`, full-line comments skipped) unless stated; "product" = `scripts/**`,
`bin/*`, `install.sh`, `setup.sh`, `uninstall.sh`; "tests" = `tests/*.bats`, `tests/test_helper.bash`, `tests/*.mjs`.
Every matching line is in `patterns.tsv`; analyzer-side flags are in `unresolved.tsv`.

| # | pattern | count | examples | what the analyzer does / what remains |
|---|---|---|---|---|
| 1 | dynamic `source` of a variable that holds the whole path | 7 lines / 4 files | storage.sh:244 `. "$found"`, storage.sh:721 `. "$file"`, peek.sh:67 `. "$hook"`, codex-shim.sh:189 `source "$daemon_state_lib"`, uninstall.sh:36/60 `. "$AGMSG_INSTALL_OP_RECOVERY_SOURCE"` | resolved through the variable's assignments when they are paths (peek.sh, codex-shim.sh); storage.sh: wildcard over all drivers; uninstall.sh's env var: unresolvable (61 analyzer `dynamic-source` rows in all, most of them inline `bash -c 'source "$1"'`) |
| 2 | path built from a runtime dir plus a variable name | 9 lines / 8 files | storage.sh:226 `file="$base/partition/$name.sh"`, storage.sh:715 `$base/storage/$name.sh`, doctor.sh:752 `$SKILL_DIR/scripts/drivers/types/$type/_delivery.sh` | variable -> `*`, kept while <= 25 matches: every driver variant becomes a dep (precision cost: `storage/jsonl.sh` in 129 static closures, opened by 1 of 67 traced files) |
| 3 | per-type / per-driver hook sourced from a directory chosen at runtime | 19 lines / 13 files | delivery.sh:514 `. "$tdir/_delivery.sh"`, join.sh:47 `. "$_AGMSG_JOIN_TYPE_DIR/_join.sh"`, boot-command.sh:49, bridge-read-guard.sh:77, terminal-registry.sh:287/320/533/567 `. "$dir/ops.sh"` | suffix match on the hook name -> all of them (11 `_delivery.sh`, 6 `ops.sh`) |
| 4 | registry directories and key=value manifests (sourcing by data) | 5 lines / 3 files loops; 32 lines / 17 files manifest reads; 2 keys name files | type-registry.sh:41 `for dir in "$base"/types/*/`, terminal-registry.sh:158, driver-registry.sh:179; type-registry.sh:130-138 `agmsg_type_template_path` = dir + `template=` from type.conf (10 types); `spawn_wrapper=codex-shim.sh` | loops = all entries; manifest rule links the dereferencing functions' callers to the named files (5 sites). Bases also come from `db/plugin-sources` and `$AGMSG_PLUGIN_DIRS` (driver-registry.sh:53-66): plugin dirs outside the repo cannot be known |
| 5 | interpreter held in a variable | 19 lines / 14 files | daemon.sh:695 `"$running_node" "$SCRIPT_DIR/daemon/status.mjs"`, daemon.sh:1103, agmsgd-launch.sh:141 `exec -a agmsgd "$NODE_PATH" "$SCRIPT_DIR/agmsgd"`, jsonl.sh:183 `"$node" "$helper"` | a command word `$<name>` matching node/python/bash/_bin counts as an interpreter -> `exec` (before this rule `status.mjs`'s 5 imports were missed in test_agmsgd_switch) |
| 6 | script path handed to a shell function that runs it later | 2 lines / 2 files | actas-claim.sh:324 and session-start.sh:339 `agmsg_sync_autostart "$SKILL_DIR/scripts/remote.sh" ...` -> sync-autostart.sh runs `"$remote_sh"` | `call` edge; strict mode misses remote.sh's libs (2 traced files); call mode follows every function argument, which also follows paths that are only matched against, e.g. `spawn_decoy_with_cmdline "$SCRIPTS/watch.sh"` (test_helper.bash:732) |
| 7 | function called with a bare script name | 17 lines / 1 file | dispatch.sh:203-245 `run_script inbox.sh\|send.sh\|history.sh\|...` -> dispatch.sh:98 `bash "$SCRIPT_DIR/../$script"` | call-site words substituted for `$1..$3` of the enclosing function (same file only) |
| 8 | inline `bash -c 'source "$1"' _ PATH` in tests | 84 lines / 23 files | test_agmsg_command.bats:62 `bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" ...`, test_install_op_lock.bats:20, test_agmsgd_daemon_sh.bats:538 | the `source "$1"` itself is unresolved; the path is still found because the trailing argument is a path expression or a variable assigned one (call edge) |
| 9 | still unresolved after all rules | 3 sites (`dyn-too-broad`) | test_local_quoting.bats:76/99 `$BATS_TEST_DIRNAME/../scripts/$1` (43 candidates), test_delivery.bats:2852 `$SCRIPTS/$LEGACY_PRE1248_NOTES_PATH` | dropped (more than 25 candidates); a selector must cover these by the per-test strace set |
| 10 | `eval` | product 17 lines / 6 files; tests 49 lines / 19 files | bridge-read-guard.sh:86-87 `eval "$(declare -f storage_mark_read_batch \| sed ...)"` (copies a function under a new name at runtime), close-fds.sh:41/47, remote.sh:2022 (saved traps), sqlite-sync.sh:1000 (jq output); test_codex_bridge_launcher.bats:959 `eval "$(sed -n "$pattern" "$1")"` | not interpreted. No product eval loads a file, so no file dep hides behind them; test evals of `sed` extracts read their file argument, which is resolved as data |
| 11 | node/js | dynamic import/require: 0; spawn on a computed `path.join`: 4 lines / 3 files; analyzer `js-computed-path` rows: 23 | codex-bridge.js:343 `spawnSync(BASH_BIN, [path.join(SCRIPTS_DIR, script), ...])` with codex-bridge.js:352 `runScript("identities.sh")`; antigravity_tui_supervisor.test.mjs:883 `path.join(install, 'scripts', script)`; node's own `package.json` lookup | relative imports, `new URL(...)`, `join()` over `__dirname`/`import.meta.*` and bare `'x.sh'` literals are resolved; a variable last component is not; node's implicit `package.json` read is visible only to strace |
| 12 | files read as data by name | 166 lines / 70 files | daemon/db.mjs:10 `join(dirname(fileURLToPath(import.meta.url)), "schema.sql")`, jsonl.sh:331 `jsonl-read-cursor.jq`, skill-render.sh:15 `scripts/skill-base.md`, bin/agmsg.js:46 `package.json` | literal names resolve (as `data` leaves); names computed from data (template path) need the manifest rule |
| 13 | files generated at test time | SKILL.md mentioned on 112 lines / 10 files; install-manifest/hooks/commands files on 153 lines / 17 files | install.sh:1046 renders `$SKILL_DIR/SKILL.md` from scripts/skill-base.md + types/<t>/template.md (skill-render.sh); test_agmsgd_daemon_sh.bats:61-82 builds `run/install-manifest.json` by digesting every file under scripts/ | `$SK/SKILL.md` is matched by suffix to the repo's SKILL.md (the wrong source, harmless); the real sources arrive through install.sh -> skill-render.sh; digests are content-insensitive reads of every script |
| 14 | tests asserting on repository-wide content | 18 static scan sites; git grep: 1 lines / 1 file; grep -r: 5 lines / 5 files; copy/digest: 5 lines / 3 files | test_capability_docs.bats:32 `git grep -- .`; test_instance_id.bats:889, test_storage.bats:357-358, test_remote_sync.bats:1513/1524, test_spawn_fd_guard.bats:32-53, test_watch.bats:2016 (grep -r over scripts/); test_cmdline_path_match.bats:102 (`"$SCRIPTS"/*.sh`); test_ci_sharding.bats:59 + shard-tests.sh:102 (`find tests -name '*.bats'`); `.github/scripts/check-*.sh` (`find "$SCAN_DIR" -name '*.sh'` + embedded python `rglob`); agmsgd_status_display.test.mjs:15 `cpSync(join(repo,'scripts'), ...)` | scan expansion makes them depend on everything they scan (resolved); copy/digest walks inside node are not seen statically -> whole-tree trigger |
| 15 | workflow and CI files read by tests | 31 lines / 10 files | test_ci_workflow.bats:4 `.github/workflows/tests.yml`, test_ci_sharding.bats:11 `shard-tests.sh`, test_ci_forensics.bats:13 `pipe-holders.awk`, test_app_release_signing.bats:11 `app-release.yml` | resolved as data deps (10 test files) |
| 16 | documentation read by tests | 65 lines / 17 files | sync_cipher.test.mjs:13 `docs/spec/vectors/age-v1-vectors.json`, test_remote_setup_doc.bats, test_capability_docs.bats:41 `$ROOT/SKILL.md` | resolved as data deps (17 test files); a docs edit selects them |
| 17 | OS-conditional branches | 78 lines / 28 files | install.sh:754 `case "$(uname -s ...)"`, daemon.sh:252, bin/agmsg.js:163 `process.platform === 'win32'` | static keeps both sides; a Linux trace never shows the macOS side (mac-process-info.py, plain/adapters/*.applescript, launchd code), so strace alone cannot drive the macOS jobs |
| 18 | existence-only checks | 39 lines / 18 files | actas-claim.sh:157 `[ -r "$SKILL_DIR/scripts/lib/daemon-state.sh" ]`, install.sh:987 `[ -x "$SKILL_DIR/scripts/remote.sh" ]` | static counts them (right for rename/delete); `openat` tracing cannot see `stat` |
| 19 | tests that rewrite their sandbox copy of a script | 67 lines / 22 files | test_agmsgd_switch.bats:136/144-151 (appends to lib/daemon-state.sh, replaces identities.sh with a wrapper), test_codex_bridge_launcher.bats:61 (replaces codex-bridge.js with a fake), test_agmsgd_entrypoint.bats:156/214 | the dep is kept; for a fully replaced file the repo version never runs (over-approximation) |

## Shared files: fan-in, and what it does to impact selection

| file | test files depending on it, static call (of 155) | strace: opened by (of 67 traced, non-whole-tree) | strace: of 38 traced setup_test_env users | selecting it costs (share of CI s) |
|---|---|---|---|---|
| `tests/test_helper.bash` | 121 | 45 | 38 | 121 files, 97.9% |
| `scripts/internal/init-db.sh` | 129 | 38 | 38 | 130 files, 96.6% |
| `scripts/lib/storage.sh` | 129 | 36 | 31 | 130 files, 96.6% |
| `scripts/lib/compat.sh` | 129 | 42 | 38 | 130 files, 96.6% |
| `scripts/lib/validate.sh` | 129 | 42 | 38 | 130 files, 96.6% |
| `scripts/lib/sqlpath.sh` | 132 | 45 | 38 | 133 files, 96.6% |
| `scripts/lib/driver-registry.sh` | 131 | 31 | 27 | 132 files, 96.6% |
| `scripts/lib/plugin-cmd.sh` | 131 | 31 | 27 | 132 files, 96.6% |
| `scripts/drivers/storage/sqlite.sh` | 130 | 12 | 10 | 131 files, 96.6% |
| `scripts/drivers/storage/jsonl.sh` | 129 | 1 | 1 | 130 files, 96.6% |
| `scripts/lib/instance-id.sh` | 129 | 29 | 26 | 130 files, 96.6% |
| `scripts/lib/registry-lock.sh` | 129 | 29 | 27 | 130 files, 96.6% |
| `scripts/lib/actas-lock.sh` | 101 | 25 | 22 | 102 files, 91.8% |
| `scripts/lib/type-registry.sh` | 97 | 26 | 22 | 99 files, 91.5% |
| `scripts/lib/resolve-project.sh` | 91 | 25 | 23 | 93 files, 89.6% |
| `scripts/lib/terminal-registry.sh` | 93 | 21 | 19 | 94 files, 89.2% |
| `scripts/join.sh` | 69 | 19 | 19 | 74 files, 89.1% |
| `scripts/send.sh` | 86 | 12 | 11 | 88 files, 88.0% |
| `scripts/watch.sh` | 72 | 6 | 4 | 74 files, 75.4% |
| `scripts/delivery.sh` | 68 | 8 | 6 | 70 files, 72.8% |
| `scripts/remote.sh` | 68 | 4 | 4 | 70 files, 72.8% |
| `install.sh` | 9 | 0 | 0 | 9 files, 15.2% |
| `SKILL.md` | 11 | 2 | 0 | 11 files, 13.6% |
| `CHANGELOG.md` | 8 | 1 | 0 | 8 files, 12.8% |

The pattern is: whatever `setup_test_env` touches is read by every one of its 107 users, so those files are
"always run" in practice; `storage.sh` and the drivers are statically in 129-131 closures because of file-level
granularity (strace shows `drivers/storage/sqlite.sh` opened by only 12 of the 67 traced files:
storage drivers load lazily on the first storage call, which `init-db.sh` never makes).

**Replay of 300 main commits** (`a32136d` 2026-07-30 .. `551764e` 2026-11-03, first-parent, closures computed at
HEAD, cost = `macos_max + ubuntu_max` per test file from run 41607512279, 7195 s + 4069 s = 11264 s per full run):

| selector | mean share of CI s | median | p75 | commits >= 80% | commits >= 95% | run-all commits |
|---|---|---|---|---|---|---|
| static strict | 54.1% | 54.2% | 96.6% | 41% | 26% | 24 |
| static call | 60.1% | 77.5% | 96.6% | 43% | 27% | 24 |
| static call + strace (recommended) | 60.2% | 77.5% | 96.6% | 43% | 27% | 24 |

Share of commits by selected fraction ("call+strace"): 0-10%: 56, 10-20%: 48, 20-30%: 5, 30-40%: 3, 40-50%: 2, 50-60%: 0, 60-70%: 0, 70-80%: 56, 80-90%: 4, 90-100%: 126.
"Run-all" are 20 commits that touch `.github/workflows/tests.yml` / `run-bats-timed.sh` / `shard-tests.sh` and 4 that
touch code files which no longer exist at HEAD. On the 66 traced (non-whole-tree) test files only
(2762 CI s), a hypothetical strace-only selector would pick 32.5% of their CI seconds on average
(median 14.2%) against 54.6% (median 56.3%) for the static call closure: that gap is
the price of static over-approximation, and it is the most a better analyzer could win back on those files.

## What a robust selector should use

1. **Union of the static "call" closure and the strace read-set** (`static_closure.tsv` plus `survey/strace/reads`
   re-extracted with `extract_reads_norm.py`). The static side is needed because strace is Linux-only (78 product
   lines branch on `Darwin`/`MINGW`/`process.platform`), cannot see existence checks, and sees only the driver/type
   variants the fixture happens to select; the dynamic side catches implicit reads (node module resolution) and
   anything a future idiom hides from the regexes. Today the union adds 0.1 files per test file over
   "call" alone on the traced files.
2. **Always-run triggers** (cheap, and they cover what neither side can see):
   * `.github/workflows/tests.yml`, `.github/scripts/run-bats-timed.sh`, `.github/scripts/shard-tests.sh`,
     the bats/node/bash versions -> everything (they change how every test runs);
   * any file added, deleted or renamed under `scripts/`, `tests/`, `bin/`, or a top-level installer -> everything
     (registries, globs and scanners pick up new files; no closure computed before the change contains them);
   * any change under `scripts/` -> the whole-tree readers (`test_agmsgd_daemon_sh`, `test_agmsgd_entrypoint`, `test_agmsgd_status`, `test_capability_docs`, `test_enforced_assertions`, `test_herdr_cli_routing`, `test_unguarded_env_reads`): git grep, CI scanners over
     `scripts/` and `tests/`, node fixtures that copy or digest `scripts/` (together 317 s macOS + 166 s ubuntu = 4.3% of a full run;
     `test_agmsgd_daemon_sh` alone is 220 s macOS + 92 s ubuntu);
   * `tests/test_helper.bash` -> all 121 files that `load` it (already in the closures, listed for clarity);
   * `package.json` -> every test file that runs node (node reads it to choose ESM/CJS; invisible statically).
3. **Treat the storage core as "run all".** `scripts/internal/init-db.sh`, `scripts/lib/{storage,compat,validate,sqlpath,driver-registry,plugin-cmd,instance-id,name-encode,registry-lock}.sh`,
   `scripts/drivers/storage/*.sh`, `scripts/drivers/partition/*.sh` and `tests/test_helper.bash` each select
   121-133 test files (97%-98% of CI seconds); computing a selection for them is wasted work.
4. **Expect the saving to come from non-product commits.** On the replay, the selector saves ~40% of CI
   seconds on average, almost all of it on the 35% of commits that touch only docs, `app/`, `site/`, `server/`,
   individual test files or release metadata (<20% selected). Commits that touch the busiest product scripts
   (the ones changed most often in the replay: `delivery.sh`, `remote.sh`, `watch.sh`, `session-start.sh`,
   `check-inbox.sh`, `codex-monitor.sh`, `codex-bridge.js`, `remote-sync.mjs`) select 70-74 test files (73%-76% of CI seconds); the storage core, `test_helper.bash`, `type-registry.sh`, `join.sh`, `send.sh`,
   `terminal-registry.sh`, `resolve-project.sh`, `actas-lock.sh` select 74-133 test files (88%-98% of CI seconds).
5. **Optional precision work, in order of payoff:** keep strace read-sets fresh in CI (they are what makes the
   selection tighter on Linux; 32.5% vs 54.6% above), split `setup_test_env` so that tests which never
   touch the database do not run `init-db.sh` (that is what puts the storage core in 107 closures), and give the
   analyzer the configuration under test (default storage driver = sqlite) to drop the jsonl/sqlite-sync variants.

## Reproduce

```
S=/tmp/claude-0/-home-user/76c8e075-7b25-518a-94e1-6a50cdb7199d/scratchpad
python3 -I $S/survey/deps/static_deps.py /home/user/agmsg $S/survey/deps
python3 -I $S/survey/deps/patterns.py    /home/user/agmsg $S/survey/deps
python3 -I $S/survey/deps/compare.py     $S
python3 -I $S/survey/deps/select_sim.py  /home/user/agmsg $S 300
python3 -I $S/survey/deps/fill_readme.py $S
```

The strace sweep was still running when this was written (72/155 files). Re-running the last three commands
after it finishes refreshes every number here; files traced after `keep_traces.sh` was stopped use the sweep's own
extraction (with the `..` gap). To get normalized read-sets for them, run `keep_traces.sh` alongside the sweep, or
fix `tools/extract_reads.py` to `posixpath.normpath()` before mapping and re-run it.
