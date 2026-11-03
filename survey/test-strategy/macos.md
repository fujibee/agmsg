# macOS necessity survey: which bats files can catch what ubuntu cannot

Scope: every `tests/*.bats` file in /home/user/agmsg (main @ 551764e), 155 files. Timings are from CI run 41607512279 (main @ 64723d6; `S/timings-41607512279.tsv`, column `macos_max`), which totals **7195 s of macOS bats time** and 4069 s on ubuntu.

Runner facts read from that run's logs: macOS = `macos-26-arm64`, `bash` on PATH = `3.2.57(1)-release (arm64-apple-darwin25)`, sqlite3 3.50.6; ubuntu = `ubuntu-26.04`, bash 5.3.9, sqlite3 3.46.1. Bats 1.13.0 on both.

## Answer in one paragraph

Under the conservative rule (`no` only with positive evidence that nothing OS-specific and nothing bash-3.2-sensitive is reached), **119 files are `yes` (6975 s, 97% of macOS time), 17 `uncertain` (193 s) and 19 `no` (27 s)**. Of the `yes` files, 110 reach Darwin/BSD-divergent code (axis A, 6793 s) and 9 are `yes` only because of bash 3.2 (axis B with no or only weak axis-A evidence, 182 s) -- those could move to a Linux bash-3.2 job. Dropping only the `no`/`uncertain`/B-only files saves about 402 s (6%). The bigger lever is that axis-A reach is mostly *incidental*: a **24-file subset (2257 s, 31% of today's macOS time) still exercises every one of the 58 OS-divergent product functions any test reaches** (see "Coverage-preserving macOS subset" below), provided axis B moves to a Linux bash-3.2 job.

## Counts and macOS seconds per class

| macos_needed | files | macOS s | share | ubuntu s |
|---|---:|---:|---:|---:|
| yes | 119 | 6975 | 97% | 3916 |
| uncertain | 17 | 193 | 3% | 136 |
| no | 19 | 27 | 0% | 17 |

| axis_a | files | macOS s |   | axis_b | files | macOS s |
|---|---:|---:|---|---|---:|---:|
| darwin_branch | 90 | 5561 |   | bash32_sensitive | 108 | 6885 |
| bsd_userland | 16 | 331 |   | uncertain | 21 | 221 |
| skips_on_os | 5 | 904 |   | none | 26 | 89 |
| uncertain | 10 | 272 |   |  |  |  |
| none | 34 | 127 |   |  |  |  |

Strength of the axis-A evidence (column `strength` in `classification-detail.json`):

| strength | meaning | files | macOS s |
|---|---|---:|---:|
| direct | the test is ABOUT Darwin-divergent code: tests that run only on macOS in CI, a real `uname`/`/proc` branch in the test itself, or a Darwin branch within 2 calls of a script/function the test invokes | 37 | 3638 |
| direct-userland | same distance, but only BSD-vs-GNU userland (ps fields, stat -f/-c, base64 -d ...) | 10 | 1023 |
| via-shared-lib | OS-divergent code is reached only deeper, through shared libraries (ps liveness probes, compat.sh, terminal dispatch) | 63 | 2132 |
| B-only | no axis-A signal; bash-3.2-sensitive constructs only | 5 | 73 |
| B+A-uncertain | bash-3.2-sensitive, plus only weak (tier-2) axis-A signals | 4 | 109 |
| none | no tier-1 axis-A evidence (the `uncertain`/`no` rows) | 35 | 217 |
| all-skipped | every test in the file skips on both OSes in CI (test_compat.bats: MSYS-only) | 1 | 3 |

## Tests skipped on only one OS (CI history, run 41607512279)

Counted straight from `S/logs/41607512279/logs.zip` by `logskips.py` (TAP `# skip`, one bats run per file). Totals: 90 skips on macOS, 100 on ubuntu, 84 tests skipped on both (mostly `age not installed`), **16 tests run only on macOS** (skipped on ubuntu) in 5 files, and **6 run only on ubuntu** in 3 files. Full list: `one-os-skips.tsv`.

| file | tests | runs only on | reason printed by the skip |
|---|---|---|---|
| test_agmsgd_daemon_sh.bats | 13,14,15,16,24,29,30,31,32,33 | macOS | this test's fake stands in for launchd specifically |
| test_antigravity_transport.bats | 10 | macOS | macOS libproc layout check |
| test_antigravity_transport.bats | 11 | macOS | this asserts the behaviour on a host that is NOT Linux |
| test_compat_posix.bats | 5 | macOS | this platform's ps reports a bare comm ([]); the space-splitting path is unreachable here |
| test_delivery.bats | 24 | ubuntu | the Linux boot id |
| test_install.bats | 12,16 | ubuntu | Antigravity TUI monitor is Linux-only |
| test_local_quoting.bats | 2,5 | macOS | /bin/bash is 5.3.9(1)-release; the 3.2 replacement-backslash difference cannot appear here |
| test_remote_status_liveness.bats | 42,43,44 | ubuntu | ps here does not truncate args to COLUMNS |
| test_spawn.bats | 55 | macOS | launch_macos_terminal() is Darwin-only |

## Coverage-preserving macOS subset

`subset.py` keeps every file with macOS-only CI tests or a real per-OS branch in the test, then greedily adds the cheapest files (by macOS seconds) until every OS-divergent product function that any test reaches is reached by a kept file -- directly (the kept file's own subject reaches it within two calls) wherever some file does so, otherwise incidentally. Result: **24 files, 2257 s** of macOS bats time (31% of 7195 s). Under the model, nothing that today's macOS run exercises on the Darwin/BSD side is lost; bash-3.2 coverage must then come from the Linux bash-3.2 job.

| file | macOS s | strength | why it is kept |
|---|---:|---|---|
| test_spawn.bats | 653 | direct | must-keep (macOS-only CI tests [55]) |
| test_watch.bats | 384 | direct | must-keep (real uname//proc branch in test L[419]) |
| test_delivery.bats | 306 | direct | must-keep (real uname//proc branch in test L[444, 466]) |
| test_codex_bridge_launcher.bats | 268 | direct | must-keep (real uname//proc branch in test L[76]) |
| test_agmsgd_daemon_sh.bats | 220 | direct | must-keep (macOS-only CI tests [13, 14, 15, 16, 24, 29, 30, 31, 32, 33]) |
| test_remote_status_liveness.bats | 95 | direct | covers directly: s/remote.sh:_remote_systemd_engine_status |
| test_dispatch.bats | 67 | direct-userland | covers directly: s/windows/dispatch.sh:<top> |
| test_session_start_claude_code_native_channel.bats | 55 | direct | must-keep (real uname//proc branch in test L[35]) |
| test_self_proof.bats | 47 | direct-userland | covers directly: s/lib/self-proof.sh:_agmsg_proof_ancestry, s/lib/self-proof.sh:_agmsg_proof_identify |
| test_watch_agmsgd_note.bats | 37 | direct | must-keep (real uname//proc branch in test L[108]) |
| test_antigravity_transport.bats | 28 | direct | must-keep (macOS-only CI tests [10, 11]) |
| test_delivery_cli.bats | 21 | direct | must-keep (real uname//proc branch in test L[25]) |
| test_helper_stop_pid.bats | 19 | via-shared-lib | only incidental cover for: tests/test_helper.bash:_pid_gone |
| test_agmsgd_switch.bats | 16 | direct | must-keep (real uname//proc branch in test L[248, 282]) |
| test_codex_own_pane.bats | 15 | direct | covers directly: s/lib/codex-own-pane.sh:_agmsg_cop_cwd_of, s/lib/codex-own-pane.sh:_agmsg_cop_no_other_resume, s/lib/codex-own-pane.sh:_agmsg_cop_sca |
| test_plugin_registry.bats | 10 | direct | covers directly: s/ext-tool.sh:_ext_tool_read_clipboard |
| test_require_python3.bats | 4 | direct | covers directly: s/lib/require-python3.sh:agmsg_python3_usable |
| test_capability_docs.bats | 3 | direct | covers directly: s/drivers/terminals/tmux/ops.sh:terminal_team_input_ready |
| test_teardown_reap.bats | 3 | via-shared-lib | only incidental cover for: tests/test_helper.bash:_pids_referencing_dir, tests/test_helper.bash:_reap_test_skill_dir_procs |
| test_compat_posix.bats | 2 | direct | must-keep (macOS-only CI tests [5]) |
| test_daemon_offer.bats | 2 | direct | must-keep (real uname//proc branch in test L[19]) |
| test_local_quoting.bats | 1 | direct | must-keep (macOS-only CI tests [2, 5]) |
| test_agmsgd_claude_code_queue.bats | 1 | direct | covers directly: s/daemon/channels/codex-queue.mjs:<top>, s/daemon/channels/process-group.mjs:<top>, s/daemon/executor.mjs:<top> |
| test_node_resolve.bats | 0 | direct | covers directly: s/lib/node.sh:agmsg_resolve_node |

Residual risk of the subset: "reached" is static/dynamic reachability, not "asserted on"; a Darwin branch reached incidentally in a dropped file may be the only place a particular input reaches it. The 85 files without an strace read-set use the static closure, which over-approximates, so their claimed coverage is optimistic -- re-run once the sweep finishes (see Method). A leaner variant (`subset.py ... --lean`, written to `macos-subset-lean.tsv`) keeps outright only the files with macOS-only CI tests and treats each genuine per-OS test branch as one coverage item, so the real-boot-id fixture duplicated across files is covered once: 24 files, 1838 s (adds test_storage.bats, test_instance_id.bats, test_codex_monitor.bats, test_cmdline_path_match.bats; drops test_watch.bats, test_session_start_claude_code_native_channel.bats, test_watch_agmsgd_note.bats, test_delivery_cli.bats). A cheap mitigation is to run the full suite on macOS on pushes to `main` (or nightly) and only the subset on PR pushes.

## Files that need macOS for axis A (one-line reasons)

Sorted by strength, then macOS seconds. Reason = the strongest axis-A evidence row (paths shortened: `s/` = `scripts/`). Full evidence, including the axis-B part, is in `classification.tsv`.

| file | macOS s | axis_a | strength | reason |
|---|---:|---|---|---|
| test_install.bats | 764 | darwin_branch | direct | CI: test(s) 12,16 skip on macOS; s/daemon.sh:404 _service_registered darwin_word |
| test_spawn.bats | 653 | skips_on_os | direct | CI: test(s) 55 run ONLY on macOS (skip on ubuntu); s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_watch.bats | 384 | darwin_branch | direct | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/instance-id.sh:465 agmsg_grok_instance_id ps_fields |
| test_delivery.bats | 306 | darwin_branch | direct | CI: test(s) 24 skip on macOS; s/check-inbox.sh:94 timeout_cmd |
| test_codex_bridge_launcher.bats | 268 | darwin_branch | direct | s/drivers/types/codex/codex-bridge-launcher.sh:527 _start_token linux_only_path; s/drivers/types/codex/codex-bridge.js:1179 js_proc |
| test_agmsgd_daemon_sh.bats | 220 | skips_on_os | direct | CI: test(s) 13,14,15,16,24,29,30,31,32,33 run ONLY on macOS (skip on ubuntu); s/daemon.sh:404 _service_registered darwin_word |
| test_team.bats | 212 | darwin_branch | direct | s/ext-tool.sh:202 _ext_tool_read_clipboard linux_only_path; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_codex_bridge.bats | 145 | darwin_branch | direct | s/drivers/types/codex/codex-bridge.js:1179 js_proc |
| test_inbox.bats | 95 | darwin_branch | direct | s/check-inbox.sh:94 timeout_cmd; s/lib/compat.sh:224 compat_file_mtime platform_macos_token |
| test_remote_status_liveness.bats | 95 | darwin_branch | direct | CI: test(s) 42,43,44 skip on macOS; s/lib/compat.sh:129 compat_get_cmdline ps_fields |
| test_messaging.bats | 82 | darwin_branch | direct | s/check-inbox.sh:94 timeout_cmd; s/lib/compat.sh:224 compat_file_mtime platform_macos_token |
| test_agmsgd_entrypoint.bats | 76 | darwin_branch | direct | s/daemon.sh:404 _service_registered darwin_word; s/daemon.sh:413 _start_registered_service darwin_word |
| test_session_start_claude_code_native_channel.bats | 55 | darwin_branch | direct | s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s; s/drivers/types/codex/codex-bridge.js:1179 js_proc |
| test_ext_tool.bats | 43 | darwin_branch | direct | s/ext-tool.sh:202 _ext_tool_read_clipboard linux_only_path; s/ext-tool.sh:173 _ext_tool_clipboard_try mac_tool |
| test_watch_agmsgd_note.bats | 37 | darwin_branch | direct | s/lib/compat.sh:175 compat_uuidgen linux_only_path; s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s |
| test_storage.bats | 35 | darwin_branch | direct | s/check-inbox.sh:94 timeout_cmd; s/lib/compat.sh:224 compat_file_mtime platform_macos_token |
| test_type_registry.bats | 30 | darwin_branch | direct | s/spawn.sh:505 uname_s; s/lib/compat.sh:35 compat_get_ppid ps_fields |
| test_antigravity_transport.bats | 28 | skips_on_os | direct | CI: test(s) 10,11 run ONLY on macOS (skip on ubuntu); s/drivers/types/antigravity/antigravity-tui-supervisor.py:42 py_libproc |
| test_delivery_cli.bats | 21 | darwin_branch | direct | s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_agmsgd_switch.bats | 16 | darwin_branch | direct | s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s; s/daemon.sh:404 _service_registered darwin_word |
| test_codex_monitor.bats | 15 | darwin_branch | direct | s/drivers/types/codex/_seat-key.sh:124 _agmsg_codex_seat_witness linux_only_path; s/drivers/types/codex/codex-bridge-launcher.sh:527 _start_token linux_only_path |
| test_codex_own_pane.bats | 15 | darwin_branch | direct | s/lib/codex-own-pane.sh:229 agmsg_codex_own_pane ps_fields; s/lib/codex-own-pane.sh:66 _agmsg_cop_under_managed_daemon ps_fields |
| test_agmsgd_status.bats | 10 | darwin_branch | direct | s/daemon/channels/codex-queue.mjs:266 js_platform_darwin_linux; s/daemon/channels/process-group.mjs:13 js_platform_darwin_linux |
| test_plugin_registry.bats | 10 | darwin_branch | direct | s/ext-tool.sh:202 _ext_tool_read_clipboard linux_only_path; s/ext-tool.sh:173 _ext_tool_clipboard_try mac_tool |
| test_agmsgd_main.bats | 4 | darwin_branch | direct | s/daemon/channels/codex-queue.mjs:266 js_platform_darwin_linux; s/daemon/channels/process-group.mjs:13 js_platform_darwin_linux |
| test_require_python3.bats | 4 | darwin_branch | direct | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; Darwin path also forced on Linux via stub (test_require_python3.bats:34) |
| test_agmsgd_codex_queue.bats | 3 | darwin_branch | direct | s/daemon/channels/codex-queue.mjs:266 js_platform_darwin_linux; s/daemon/channels/process-group.mjs:13 js_platform_darwin_linux |
| test_capability_docs.bats | 3 | darwin_branch | direct | s/drivers/terminals/plain/ops.sh:383 terminal_peek mac_tool; s/drivers/terminals/plain/ops.sh:400 terminal_poke mac_tool |
| test_cmdline_path_match.bats | 2 | darwin_branch | direct | s/lib/compat.sh:175 compat_uuidgen linux_only_path; s/lib/compat.sh:224 compat_file_mtime platform_macos_token |
| test_compat_posix.bats | 2 | skips_on_os | direct | CI: test(s) 5 run ONLY on macOS (skip on ubuntu); s/lib/compat.sh:164 compat_get_comm ps_fields |
| test_daemon_offer.bats | 2 | darwin_branch | direct | s/daemon.sh:404 _service_registered darwin_word; s/daemon.sh:413 _start_registered_service darwin_word |
| test_agmsgd_claude_code_queue.bats | 1 | darwin_branch | direct | s/daemon/channels/codex-queue.mjs:266 js_platform_darwin_linux; s/daemon/channels/process-group.mjs:13 js_platform_darwin_linux |
| test_close_fds.bats | 1 | darwin_branch | direct | s/drivers/types/codex/codex-bridge-launcher.sh:527 _start_token linux_only_path; s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s |
| test_local_quoting.bats | 1 | skips_on_os | direct | CI: test(s) 2,5 run ONLY on macOS (skip on ubuntu); test documents a measured 3.2-only behaviour test_local_quoting.bats:10 |
| test_agmsgd_executor.bats | 0 | darwin_branch | direct | s/daemon/executor.mjs:36 js_platform_darwin_linux |
| test_agmsgd_owner.bats | 0 | darwin_branch | direct | s/daemon/executor.mjs:36 js_platform_darwin_linux |
| test_node_resolve.bats | 0 | darwin_branch | direct | s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_remote.bats | 557 | darwin_branch | direct-userland | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_terminal_registry.bats | 206 | darwin_branch | direct-userland | s/drivers/terminals/herdr/ops.sh:339 terminal_epoch stat_flags; s/lib/self-proof.sh:113 _agmsg_proof_ancestry ps_fields |
| test_dispatch.bats | 67 | darwin_branch | direct-userland | s/windows/dispatch.sh:85 base64_flags; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_resolve_project.bats | 54 | darwin_branch | direct-userland | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/instance-id.sh:465 agmsg_grok_instance_id ps_fields |
| test_self_proof.bats | 47 | darwin_branch | direct-userland | s/drivers/terminals/herdr/ops.sh:339 terminal_epoch stat_flags; s/lib/self-proof.sh:113 _agmsg_proof_ancestry ps_fields |
| test_sync_autostart.bats | 40 | darwin_branch | direct-userland | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/instance-id.sh:465 agmsg_grok_instance_id ps_fields |
| test_instance_id.bats | 26 | darwin_branch | direct-userland | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/instance-id.sh:403 agmsg_grok_ancestor_pid ps_fields |
| test_team_status.bats | 14 | darwin_branch | direct-userland | s/drivers/terminals/tmux/ops.sh:534 terminal_team_input_ready ps_fields; s/drivers/terminals/herdr/ops.sh:339 terminal_epoch stat_flags |
| test_sweep_enumeration.bats | 9 | darwin_branch | direct-userland | s/drivers/terminals/herdr/ops.sh:339 terminal_epoch stat_flags; s/drivers/terminals/tmux/ops.sh:534 terminal_team_input_ready ps_fields |
| test_herdr_cli_routing.bats | 3 | bsd_userland | direct-userland | s/drivers/terminals/herdr/ops.sh:339 terminal_epoch stat_flags |
| test_remote_sync.bats | 273 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_self_name.bats | 193 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_migrate_team_store.bats | 167 | darwin_branch | via-shared-lib | s/lib/node.sh:52 agmsg_resolve_node mac_path; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_roster_journal.bats | 109 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/compat.sh:129 compat_get_cmdline ps_fields |
| test_doctor.bats | 107 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_key.bats | 101 | darwin_branch | via-shared-lib | s/lib/node.sh:52 agmsg_resolve_node mac_path; s/lib/node.sh:43 agmsg_resolve_node sort_flags |
| test_despawn.bats | 99 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_plugin_install.bats | 77 | darwin_branch | via-shared-lib | s/daemon.sh:404 _service_registered darwin_word; s/daemon.sh:413 _start_registered_service darwin_word |
| test_watch_once.bats | 74 | darwin_branch | via-shared-lib | s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_actas_integration.bats | 73 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_self_write.bats | 59 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:67 _plain_adapter_probe darwin_word |
| test_peek_poke.bats | 56 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_remote_engine_start_refusal.bats | 56 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_api.bats | 51 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/compat.sh:35 compat_get_ppid ps_fields |
| test_wait_helpers.bats | 41 | bsd_userland | via-shared-lib | tests/test_helper.bash:538 _pid_gone ps_fields |
| test_actas_lock.bats | 37 | darwin_branch | via-shared-lib | s/lib/compat.sh:175 compat_uuidgen linux_only_path; s/lib/compat.sh:212 compat_file_size platform_macos_token |
| test_watch_install_changed.bats | 37 | darwin_branch | via-shared-lib | s/lib/compat.sh:175 compat_uuidgen linux_only_path; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_self_rename.bats | 36 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:383 terminal_peek mac_tool; s/drivers/terminals/plain/ops.sh:62 _plain_adapter_script mac_tool |
| test_placement_collisions.bats | 30 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_team_list.bats | 30 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_export.bats | 27 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/compat.sh:35 compat_get_ppid ps_fields |
| test_seat_reminder.bats | 24 | darwin_branch | via-shared-lib | s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_codex_shim.bats | 23 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_role_session.bats | 20 | darwin_branch | via-shared-lib | s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_self_fix.bats | 20 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:383 terminal_peek mac_tool; s/drivers/terminals/plain/ops.sh:62 _plain_adapter_script mac_tool |
| test_helper_stop_pid.bats | 19 | bsd_userland | via-shared-lib | tests/test_helper.bash:538 _pid_gone ps_fields |
| test_watch_process_count.bats | 19 | darwin_branch | via-shared-lib | s/lib/compat.sh:175 compat_uuidgen linux_only_path; s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool |
| test_codex_resume.bats | 18 | darwin_branch | via-shared-lib | s/lib/node.sh:52 agmsg_resolve_node mac_path; s/lib/node.sh:43 agmsg_resolve_node sort_flags |
| test_resume_seat_guard.bats | 18 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_registry_lock.bats | 17 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields |
| test_remote_refusal.bats | 17 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_self_write_lock.bats | 17 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; weak B only: glob_range_locale s/lib/instance-id.sh:670 (tier-2: glob_range_locale) |
| test_sqlite_crlf.bats | 14 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_remote_forget.bats | 13 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_reset_role_session.bats | 13 | bsd_userland | via-shared-lib | s/lib/compat.sh:35 compat_get_ppid ps_fields; s/lib/compat.sh:164 compat_get_comm ps_fields |
| test_local_team_ids.bats | 12 | darwin_branch | via-shared-lib | s/lib/node.sh:52 agmsg_resolve_node mac_path; s/lib/node.sh:43 agmsg_resolve_node sort_flags |
| test_remote_sync_engine.bats | 12 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_perf_harness.bats | 11 | darwin_branch | via-shared-lib | s/lib/node.sh:52 agmsg_resolve_node mac_path; s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word |
| test_printed_command_paths.bats | 10 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_plugin_shadow.bats | 9 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_session_start_terminal_line.bats | 8 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_sync_cipher.bats | 8 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_binding_mode.bats | 6 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/compat.sh:35 compat_get_ppid ps_fields |
| test_boot_command.bats | 6 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields |
| test_locator.bats | 6 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_remote_curl_config_paths.bats | 6 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_codex_shim_sync.bats | 5 | darwin_branch | via-shared-lib | s/daemon.sh:404 _service_registered darwin_word; s/daemon.sh:413 _start_registered_service darwin_word |
| test_identity_path_forms.bats | 5 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/compat.sh:35 compat_get_ppid ps_fields |
| test_legacy_mirror.bats | 5 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields; s/lib/compat.sh:35 compat_get_ppid ps_fields |
| test_resurrect_panes.bats | 5 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields |
| test_harness_self_name_off.bats | 4 | darwin_branch | via-shared-lib | s/lib/daemon-state.sh:30 agmsg_daemon_read_state uname_s; tests/test_helper.bash:187 _reap_test_skill_dir_procs mac_path |
| test_install_op_lock.bats | 4 | bsd_userland | via-shared-lib | s/lib/instance-id.sh:194 _agmsg_pid_alive_local ps_fields |
| test_remote_header_sink.bats | 4 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_remote_curl_stderr.bats | 3 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_remote_curl_stderr_get.bats | 3 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_teardown_reap.bats | 3 | darwin_branch | via-shared-lib | tests/test_helper.bash:187 _reap_test_skill_dir_procs mac_path; tests/test_helper.bash:159 _pids_referencing_dir ps_fields |
| test_terminal_context_line.bats | 3 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_where.bats | 3 | darwin_branch | via-shared-lib | s/drivers/terminals/plain/ops.sh:125 terminal_detect mac_tool; s/drivers/terminals/plain/ops.sh:164 terminal_spawn uname_s |
| test_agmsg_command.bats | 2 | darwin_branch | via-shared-lib | s/daemon.sh:404 _service_registered darwin_word; s/daemon.sh:413 _start_registered_service darwin_word |
| test_engine_inherited_fds.bats | 1 | darwin_branch | via-shared-lib | s/lib/node.sh:52 agmsg_resolve_node mac_path; s/lib/node.sh:43 agmsg_resolve_node sort_flags |
| test_remote_sync_ca_bundle.bats | 1 | darwin_branch | via-shared-lib | s/lib/node.sh:52 agmsg_resolve_node mac_path; s/lib/node.sh:43 agmsg_resolve_node sort_flags |
| test_remote_sync_driver_input.bats | 1 | darwin_branch | via-shared-lib | s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word; s/lib/node.sh:52 agmsg_resolve_node mac_path |
| test_setup.bats | 1 | darwin_branch | via-shared-lib | s/daemon/channels/codex-queue.mjs:266 js_platform_darwin_linux; s/lib/require-python3.sh:92 agmsg_python3_usable darwin_word |

## Where the Darwin/BSD-divergent product code is

Tier-1 axis-A sites in product code (scripts/, install.sh, bin/, and the .github/scripts that CI also runs on macOS), by function:

("test files reaching it" is from the reachability model; for files without a read-set it over-approximates, e.g. the plain driver is counted wherever terminal dispatch is reachable.)

| function | patterns | lines | test files reaching it |
|---|---|---|---:|
| s/check-inbox.sh <top> | timeout_cmd | 94,95 | 9 |
| s/daemon.sh _launchd_plist_path | launchd,mac_path | 270 | 15 |
| s/daemon.sh _register | darwin_word | 562 | 15 |
| s/daemon.sh _service_registered | darwin_word | 404 | 15 |
| s/daemon.sh _start_registered_service | darwin_word | 413 | 15 |
| s/daemon.sh _unregister | darwin_word | 571 | 15 |
| s/daemon/channels/codex-queue.mjs <top> | js_platform_darwin_linux | 266 | 9 |
| s/daemon/channels/process-group.mjs <top> | js_platform_darwin_linux,js_proc | 13,15,24,28 | 10 |
| s/daemon/executor.mjs <top> | js_mac_tool,js_platform_darwin_linux,js_proc | 36,41,46,55,61,83 | 13 |
| s/drivers/terminals/herdr/ops.sh terminal_epoch | stat_flags | 339,340 | 67 |
| s/drivers/terminals/plain/ops.sh _plain_adapter_probe | darwin_word,mac_tool,uname_s | 67,71,81 | 65 |
| s/drivers/terminals/plain/ops.sh _plain_adapter_script | mac_tool | 62 | 65 |
| s/drivers/terminals/plain/ops.sh _plain_process_witness_matches | ps_fields | 271,277 | 65 |
| s/drivers/terminals/plain/ops.sh terminal_despawn | darwin_word,mac_tool,uname_s | 346,350,355 | 65 |
| s/drivers/terminals/plain/ops.sh terminal_detect | mac_tool | 125 | 65 |
| s/drivers/terminals/plain/ops.sh terminal_fence | ps_fields | 441,445 | 65 |
| s/drivers/terminals/plain/ops.sh terminal_peek | mac_tool | 383 | 65 |
| s/drivers/terminals/plain/ops.sh terminal_poke | mac_tool | 400 | 65 |
| s/drivers/terminals/plain/ops.sh terminal_spawn | darwin_word,mac_tool,uname_s | 164,165,168,171,172 | 65 |
| s/drivers/terminals/tmux/ops.sh terminal_team_input_ready | ps_fields | 534,537 | 66 |
| s/drivers/types/antigravity/antigravity-monitor.sh <top> | darwin_word,linux_only_path,uname_s | 14,17 | 3 |
| s/drivers/types/antigravity/antigravity-tui-supervisor.py <top> | py_libproc,py_platform,py_proc | 42,50,57,61,65,68 | 6 |
| s/drivers/types/antigravity/bridge-read-guard.mjs <top> | js_platform_darwin_linux,js_proc | 17,27,32,33,68,92 | 7 |
| s/drivers/types/antigravity/mac-process-info.py <top> | py_libproc | 4,20,21,22,25 | 7 |
| s/drivers/types/codex/_seat-key.sh _agmsg_codex_seat_witness | linux_only_path,ps_fields | 124,125,133 | 9 |
| s/drivers/types/codex/codex-bridge-launcher.sh _start_token | linux_only_path,ps_fields | 527,528,536 | 8 |
| s/drivers/types/codex/codex-bridge.js <top> | js_proc | 1179,1183 | 16 |
| s/ext-tool.sh _ext_tool_clipboard_try | linux_only_path,mac_tool | 173,174,175,176 | 8 |
| s/ext-tool.sh _ext_tool_read_clipboard | linux_only_path,mac_tool | 202 | 8 |
| s/lib/codex-own-pane.sh _agmsg_cop_cwd_of | linux_only_path | 92,93 | 55 |
| s/lib/codex-own-pane.sh _agmsg_cop_no_other_resume | ps_fields | 168 | 55 |
| s/lib/codex-own-pane.sh _agmsg_cop_scan | ps_fields | 137 | 55 |
| s/lib/codex-own-pane.sh _agmsg_cop_under_managed_daemon | ps_fields | 66 | 55 |
| s/lib/codex-own-pane.sh agmsg_codex_own_pane | ps_fields | 229,277 | 55 |
| s/lib/compat.sh compat_file_mode | platform_macos_token,stat_flags | 237,238 | 21 |
| s/lib/compat.sh compat_file_mtime | platform_macos_token,stat_flags | 224,225 | 9 |
| s/lib/compat.sh compat_file_size | platform_macos_token,stat_flags | 212,213 | 28 |
| s/lib/compat.sh compat_files_mtime_0 | platform_macos_token,stat_flags | 266,267 | 13 |
| s/lib/compat.sh compat_get_cmdline | ps_fields | 129 | 78 |
| s/lib/compat.sh compat_get_comm | ps_fields | 164 | 72 |
| s/lib/compat.sh compat_get_ppid | ps_fields | 35 | 70 |
| s/lib/compat.sh compat_uuidgen | linux_only_path | 175,176 | 35 |
| s/lib/daemon-state.sh agmsg_daemon_read_state | darwin_word,date_flags,linux_only_path,mac_tool,ps_fields,uname_s | 30,31,32,33,34,41 | 40 |
| s/lib/instance-id.sh _agmsg_pid_alive_local | ps_fields | 194 | 88 |
| s/lib/instance-id.sh agmsg_grok_ancestor_pid | ps_fields | 403,405 | 28 |
| s/lib/instance-id.sh agmsg_grok_instance_id | ps_fields | 465,484 | 28 |
| s/lib/instance-id.sh agmsg_reap_orphan_grok_watchers | ps_fields | 550 | 28 |
| s/lib/node.sh agmsg_resolve_node | mac_path,sort_flags | 43,52 | 53 |
| s/lib/require-python3.sh agmsg_python3_usable | darwin_word,mac_tool | 92,96 | 36 |
| s/lib/self-proof.sh _agmsg_proof_ancestry | ps_fields | 113 | 46 |
| s/lib/self-proof.sh _agmsg_proof_identify | ps_fields | 199 | 46 |
| s/release/update-cask.sh <top> | sed_inplace | 83,100 | 4 |
| s/remote.sh _remote_systemd_engine_status | linux_only_path | 2198 | 35 |
| s/spawn.sh <top> | darwin_word,mac_tool,ps_fields,uname_s | 505,506,518,524 | 7 |
| s/windows/dispatch.sh <top> | base64_flags | 85 | 4 |

Notes on what is and is not macOS-specific:

- Most `uname` calls are **Windows** detection (`MINGW*|MSYS*|CYGWIN*` vs `*`), where macOS and Linux take the same arm; the scanner demotes them (`@win_only_case`, e.g. install.sh:754, spawn.sh:741, windows-elevation.sh:20), as well as code inside Windows-only case arms (`@win_arm`, e.g. compat.sh:107 `/proc` is the MSYS arm, not Linux), pure detector functions (`@detector`: compat.sh:15 `_agmsg_detect_platform`, daemon.sh:252 `_os`) whose consumers carry their own hits, and `Linux|Darwin)` shared arms (antigravity-monitor.sh:7, codex-own-pane.sh:64).
- Several Darwin branches are **also exercised on ubuntu through stubs** (a fake `uname` printing Darwin, fake `osascript`, or a redefined `_agmsg_platform`): tests/test_despawn.bats:258, test_peek_poke.bats:203, test_terminal_registry.bats:735, test_require_python3.bats:34. For those branches macOS adds only real-tool behaviour, not branch coverage.
- Genuine per-OS test logic (a real `uname`/`/proc` probe deciding what a test does) exists in: test_agmsgd_daemon_sh.bats:375, test_agmsgd_switch.bats:248, test_antigravity_transport.bats:168, test_codex_bridge_launcher.bats:76, test_daemon_offer.bats:19, test_delivery.bats:444, test_delivery_cli.bats:25, test_session_start_claude_code_native_channel.bats:35, test_spawn.bats:775, test_watch.bats:419, test_watch_agmsgd_note.bats:108.
- A different sqlite3 (3.50.6 vs 3.46.1) and awk (BWK awk on macOS) are global differences; the scanner records awk use only as a tier-2 signal (`awk_impl`). The sqlite version gap is not BSD-vs-GNU and could be pinned on Linux instead.

## Axis B: bash 3.2 sensitivity

Tier-1 bash-3.2-divergent constructs in product code: `glob_letter_range_locale` 42 sites/21 files; `array_expand_under_nounset` 41 sites/18 files; `source_with_status_guard` 36 sites/10 files; `ifs_read_into_procsubst` 12 sites/1 files; `patsub_repl_backslash_or_amp` 7 sites/2 files; `file_time_compare` 3 sites/3 files; `bash_version_branch` 2 sites/2 files; `coproc` 2 sites/2 files; `read_t_timeout` 2 sites/2 files.

- The repo already guards several of these by hand and documents measured 3.2 behaviour: `${v//\'/...}` replacement backslashes (history.sh:53, inbox.sh:63, sqlpath.sh:29, tests/test_local_quoting.bats), `case` inside `$( )` (tmux/ops.sh:833 and check-inbox.sh:351, rationale at :825/:338 -- the scanner's parser finds only these two, both in the safe `(pat)` form), errexit firing through a sourced file (check-errexit-status-reads.sh's `[source]` kind), `[a-z]` widened by a UTF-8 locale (plugin.sh:229, tests/test_plugin_install.bats:216, tests/test_self_identity.bats:375), whole-second `-nt` (tests/test_watch_install_changed.bats:169), exec redirections relocating fds >= 10 (close-fds.sh:17, tests/test_engine_inherited_fds.bats:60), a read's temporary IFS leaking into `< <(...)` (tests/test_agmsgd_daemon_sh.bats:722), coproc vs FIFO fallback (install-op-lock.sh:80, daemon.sh:136).
- `.github/scripts/check-errexit-status-reads.sh` covers only status reads after `$(...)`/`source`; everything else above is caught only by actually running under 3.2.
- Test-harness side: on 3.2 a non-final `[[ ]]` does not fail a bats test (#670, guarded by check-enforced-assertions.sh), and `$BASHPID` is empty (tests/test_watch.bats:52, test_self_write_lock.bats:240, test_session_start_claude_code_native_channel.bats:358 -- on macOS the last one feeds `AGMSG_AGENT_PID=` and so takes the "explicit empty" branch of resolve-project.sh:493). These change what a macOS run asserts, not what the product does.
- Practically every file that executes product bash reaches at least one tier-1 construct (108 files are `bash32_sensitive`), so B cannot be satisfied by a curated macOS subset; it needs a whole-suite run under 3.2.

## Feasibility: covering axis B on Linux with bash 3.2.57

Goal: run the suite with `bash` = 3.2.57 on ubuntu so macOS can run only the axis-A subset. Two routes:

1. **Docker Hub `bash:3.2`** (official image; tags `3.2`, `3.2.57`, `3.2-alpine3.22`, last pushed 2026-10-24, amd64 and arm64). It is Alpine/musl + BusyBox. The bash binary is musl-linked, so it cannot simply be copied onto the glibc runner, and running the whole suite inside the container means installing sqlite, jq, python3, node, git, curl and GNU coreutils/findutils/procps first -- and accepting a third userland (musl/BusyBox) whose differences are neither macOS's nor ubuntu's. Usable, but heavier and noisier than route 2. (docker-library builds these old versions with `--without-bash-malloc` because musl's brk/sbrk only return ENOMEM, and keeps the 3.x/4.0/4.1 tags on alpine3.22 while 5.3 is on alpine3.24.)
2. **Compile 3.2.57 on ubuntu-latest** (recommended): `bash-3.2.tar.gz` + the 57 official patches (or the `bash-3.2.57` tarball), `./configure --without-bash-malloc --disable-nls --build=x86_64-pc-linux-gnu`, cache the result with `actions/cache` keyed on version + compiler, and put a directory holding it as `bash` first on PATH (every product script uses `#!/usr/bin/env bash`, so they and bats all pick it up). Known issues with modern compilers, to budget for: GCC 14 turns `-Wimplicit-function-declaration`, `-Wimplicit-int`, `-Wincompatible-pointer-types` and `-Wint-conversion` into errors, and GCC 15 defaults to C23 (`()` means `(void)`, `bool` is a keyword), which breaks the K&R-style declarations in bash 3.2 and its bundled readline 5.2. The usual fix is `CFLAGS='-O2 -std=gnu17'` (or `gnu89`) plus `-fpermissive` / `-Wno-error=` for those four; the build-host helpers (mksyntax, bashversion) are compiled with CC_FOR_BUILD and need the same flags. The bundled config.guess predates aarch64 (only matters on arm runners; `--build` sidesteps it). **Not verified here**: building would mean running a downloaded configure/make in this session, which was not asked for and would load a CPU the strace sweep is using; expect about a minute of build time on a runner, near zero once cached.

What a Linux bash-3.2 job would and would not reproduce:

- Reproduces: 4.x-only syntax and builtins, the 3.2 parser (case/while inside `$( )`), patsub backslashes, errexit/source, empty arrays under `set -u`, `-nt` granularity, the fd relocation, `$BASHPID`, and bats' own 3.2 semantics (#670).
- Needs test changes: 14 test files hardcode `/bin/bash` (tests/test_agmsgd_daemon_sh.bats 13x, test_local_quoting.bats 11x, test_plugin_install.bats 3x, ...), which stays 5.3 on ubuntu; test_local_quoting.bats tests 2 and 5 skip unless /bin/bash is 3.2. Parameterise them (`${AGMSG_TEST_SYSTEM_BASH:-/bin/bash}`) rather than replacing the runner's /bin/bash.
- Approximates only: locale-dependent 3.2 behaviour. `[a-z]` widening depends on the libc's collation (macOS libc vs glibc) and on the job's locale -- ubuntu runners default to C.UTF-8, where it does not happen at all. Set `LC_ALL=en_US.UTF-8` (after `locale-gen`) in that job and keep tests/test_plugin_install.bats and tests/test_self_identity.bats on macOS if exactness matters. Apple's /bin/bash is also a vendor build of 3.2.57, not byte-identical GNU 3.2.57.
- Does not reproduce anything on axis A (GNU userland stays) -- that is what the macOS subset is for.
- Cost: a whole-suite ubuntu run is about 4069 s of runner time today (the ubuntu leg), on runners that are not limited to 5 concurrent jobs the way macOS is.

## Method

Scripts (all in this directory, rerunnable; they read the repo and never write to it):

1. `scan.py <repo> scan-hits.tsv` -- line scanner over scripts/, tests/, bin/, .github/scripts/, install.sh, setup.sh, uninstall.sh (bash, bats, mjs/js, py, awk). Comment text is stripped quote-aware; heredoc bodies are scanned as code. Every row has file, line, enclosing function (bash) or `@test#N` (bats), axis, category, pattern, tier (1 = known concrete divergence, 2 = weak/unverified) and reach (`file` for 3.2 parser hazards that bite as soon as a file is sourced, `func` otherwise). Includes a small structural parser for `case`/`while`/comments inside `$( )`, checked against a fixture (`selftest/`). 2123 hits.
2. `classify.py` -- builds (file, function) nodes for bash and file nodes for node/python/awk, with edges for function calls (resolved same-file first, then unique definition, then files the caller names, else every definition -- so dynamic driver dispatch stays reachable) and for repo paths named in an execution context (`bash`/`source`/`.`/`exec`/`node`/command position/assignment; message strings, `case` patterns and prose are excluded). Entries per test: product paths it runs or sources, functions it calls or lifts with `sed -n '/^f() {/,/^}/p'`, `setup_test_env` -> init-db.sh, node `*.test.mjs` imports, and the strace read-set when present. Reach is a BFS with call depth; hits on reached nodes decide the axes. One guarded edge: storage.sh:37-44 sources daemon-state.sh only when `run/install.db` exists, so it is followed only for tests that mention install.db/agmsgd/daemon.
3. `logskips.py` -- one-OS skips from the logs zip. `subset.py` -- the coverage-preserving subset. `gen_readme.py` -- this file.

Strace read-sets: 70 of 155 existed at classification time (the sweep was still running). **They are incomplete by construction**: `tools/extract_reads.py` maps a temp-copy path by its repo suffix without normalising it, so an open through `../` is dropped. Example: scripts/internal/init-db.sh:5 sources `"$SCRIPT_DIR/../lib/storage.sh"` on every setup_test_env, yet `reads/test_hash.tsv` lists init-db.sh and not storage.sh (storage.sh shows up only in read-sets where something sources it by a `../`-free path). `os.path.normpath` on the path before mapping fixes it. The classifier compensates by adding exactly the `../`-sourced files (transitively) to a read-set, and uses the static closure for files without a read-set. Re-run `classify.py`, `subset.py` and `gen_readme.py` after the sweep finishes to tighten the 92 static rows.

Known limits: control flow is not modelled (an env var that disables a branch, e.g. `AGMSG_SELF_NAME=off`, does not prune it), so static reach over-approximates; `yes` means "can reach", not "is asserted on". Tier-2 signals (awk implementation, hash-tool choice, `=~`, digit glob ranges, `%q`) never make a file `yes` on their own; they turn `no` into `uncertain`.

## Outputs

- `classification.tsv` -- the requested table: file, axis_a, axis_b, macos_needed, evidence (file:line).
- `classification-detail.json` -- per file: seconds, strength, OS-divergent functions reached with call depth, B patterns, CI one-OS skips, genuine and stubbed test-side OS lines, documented-3.2 lines.
- `scan-hits.tsv` (raw scanner hits), `one-os-skips.tsv`, `macos-subset.tsv` / `macos-subset-lean.tsv`, `reach.json` (files reached per test), `classification.raw.json` (every reached hit per test, for auditing a row).
