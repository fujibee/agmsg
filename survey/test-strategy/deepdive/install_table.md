| # | title | macOS s | ubuntu s | ratio | driver |
|---|---|---|---|---|---|
| 97 | install: bare --update preserves every renderable type's SKILL.md fla... | 69.5 | 19.3 | 3.6 | 20 install.sh runs: per renderable type (10), fresh `--agent-type t` + bare `--update`, sequential, one HOME (L2129-2142) |
| 94 | install --update: moves removed/overwritten scripts/ files to .trash/... | 40.0 | 16.1 | 2.5 | fresh + 2 `--update`; the newline-named fixture (L2042-2046) stays in scripts/, so both updates fall back to per-file `agmsg_sha256` (518 Perl `shasum` + 257 `cmp` per update; locally 13.6-15.2 s vs 1.5 s for a normal update) **[P1]** |
| 18 | uninstall: removes only the targeted install, leaving a second instal... | 20.7 | 7.1 | 2.9 | 4 installs (5 marker dirs + CODEX_HOME profile), 2 joins, delivery setup, 2 uninstalls; two scenarios in one test |
| 22 | install: --update starts an agmsgd that was turned on again, instead ... | 15.4 | 7.5 | 2.0 | fresh + `--update` that starts a real agmsgd (node) and waits for ready (0.1 s poll), then `daemon.sh stop` (0.1 s poll) **[P1]** |
| 32 | install --update: replaces a running sync engine with one on the new ... | 15.0 | 5.7 | 2.6 | fresh + join + `remote.sh sync start` (fake engine) + `--update` restarting it (fake defers TERM until its `sleep 1` ends, L784-789) + fixed `sleep 1` (L828) + status; teardown TERM + poll **[P1]** |
| 15 | install: Antigravity TUI shim replaces its symlink without writing th... | 13.5 | 2.2 | 6.1 | fresh + bare `--update` (symlinked shim); 6x ubuntu while other 2-run tests are ~7 s: probably single-sample noise **[P1]** |
| 8 | install --update: an owned Codex shim is removed while agmsgd is on, ... | 12.7 | 4.1 | 3.1 | fresh + codex-shim-install + 2 `--update` (daemon intent on, then off) **[P1]** |
| 80 | install: --update --cmd DOES reclaim a Codex shim whose owner install... | 11.5 | 3.9 | 2.9 | 2 fresh (codex) + 2 shim installs + 2 `--update` **[P1]** |
| 107 | install writes a completion manifest, --update carries install_id and... | 11.2 | 3.2 | 3.5 | fresh + 3 `--update` (manifest gen / install_id) + sqlite reads |
| 112 | install cancellation waits for the active writer before clearing its ... | 11.1 | 3.5 | 3.2 | fresh + 2 fault-injected background `--update` (writer stub, 0.02 s polls) + uninstall + recovery `--update` |
| 13 | install: Antigravity TUI shim preserves foreign files and refreshes i... | 10.4 | 4.3 | 2.4 | fresh (`run`) + 2 bare `--update` + second install |
| 34 | install: AGMSG_STORAGE_PATH override works against the installed skill | 9.8 | 2.0 | 4.9 | fresh + 2 joins + send + inbox under AGMSG_STORAGE_PATH (join.sh is ~190 execs) **[P1]** |
| 79 | install: --update --cmd does NOT steal a Codex shim owned by another ... | 9.8 | 2.9 | 3.3 | 2 fresh (codex) + shim install + `--update` **[P1]** |
| 64 | install --update: adds missing Codex run writable_root for existing i... | 9.6 | 2.0 | 4.9 | pre-made ~/.codex/config.toml + fresh + `--update` |
| 9 | install --update: a Codex shim that cannot be put back is reported wi... | 9.5 | 3.6 | 2.6 | fresh + shim install + 2 `--update` **[P1]** |
| 113 | install cancellation before writer pid publication keeps the incomple... | 9.3 | 3.0 | 3.1 | fresh + 3 `--update` (one fault-injected in background) + recovery |
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
| 1 | install: fresh install ships scripts/lib and the commands actually run | 7.0 | 2.7 | 2.6 | fresh + 2 joins + send + inbox (keep as the in-test fresh-install smoke) |
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
| 90 | install: skips Antigravity skill when its markers are absent | 5.0 | 0.9 | 5.4 | fresh only (absence check); 5.4x ubuntu while other 1-run tests are ~3.2 s: probably noise **[P1]** |
| 53 | install: watch.sh self-cleans a prior watcher on re-invocation for th... | 5.0 | 1.7 | 3.0 | fresh + 2 background watch.sh runs (0.1 s pidfile polls) + `_agmsg_kill_confirmed` **[P1]** |

rows=62 cum_macos=608.4 of 762.1 (79.8%)
