# Single-copy ciphertext in pull apply

## Scope and result

Baseline: `0444bae` (the fetched `main` on 2026-09-05), including the earlier lookup indexes. The implementation replaces repeated ciphertext literals with one `UPDATE` of a connection-local TEMP singleton per message. All ten consumers read that value using scalar subqueries. The issue title says nine copies; the current baseline's captured importable-message batch contains **ten**, and the changed batch contains **one**.

The byte reduction is deterministic. Captured CLI-batch time and C-API preparation cost fall for the largest blobs, while C-API step time increases. **The measurements do not establish a consistent improvement in complete adapter latency, nor explain latency on a production store.** The 4 KiB adapter median is slightly worse after the change and the ranges overlap substantially. No production store, message, or key was inspected.

## Controlled adapter measurements

macOS system `sqlite3` 3.51.0, source ID `2025-06-12 13:14:41 f0ca7bba1c5e232e5d279fad6338121ab55af0c8c68c84cdfb18ba5114dcaapl`; Python's fixture SQLite also reports 3.51.0. Five repetitions per variant and size, alternating before/after order. No other test or harness launched by this investigation ran during this measurement; unrelated activity on the shared machine was not controlled.

Each seed has 1,000 imported messages with 4,096-byte blobs and 100 pending messages. Incoming projection bodies stay at 120 bytes. Only incoming blob width changes. Each run receives a fresh backup and invokes the actual storage adapter with an already-evaluated importable page. Fixture construction and validation are outside the timers. Blobs are synthetic storage fixtures, not valid age ciphertext.

| Incoming blob bytes | SQL bytes before | SQL bytes after | Reduction | Adapter ms/message before | Adapter ms/message after | SQLite batch ms/message before | SQLite batch ms/message after |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 120 | 1,166,517 | 1,104,726 | 5.3% | 17.923 | 14.665 | 0.425 | 0.422 |
| 4,096 | 5,142,517 | 1,502,326 | 70.8% | 18.623 | 19.130 | 0.677 | 0.607 |
| 16,384 | 17,430,517 | 2,731,126 | 84.3% | 31.679 | 30.138 | 1.219 | 0.642 |

Times are medians. Adapter ranges before/after, in ms/message: 120 bytes `[15.065,18.834]` / `[13.923,17.972]`; 4,096 bytes `[17.621,29.124]` / `[16.428,20.389]`; 16,384 bytes `[28.340,42.372]` / `[27.850,31.683]`. The small-blob improvement is not evidence of a size-dependent speedup: that case saves only 61,791 SQL bytes and the experiment is noisy. The large-blob CLI batch median falls about 47%, but it remains a small part of complete apply time.

The adapter timer is unwrapped. SQL capture is separate and untimed. The SQLite timer replays captured SQL through the actual CLI on another fresh seed: it includes process startup, parsing, execution, and commit, not just parsing. Every timed adapter run is followed by an untimed idempotent replay and exact blob/count/mirror checks. Every CLI replay is also verified. Raw observations: `957-apply-results.jsonl`.

## Compilation versus execution

An additional 20 repetitions per variant and size execute captured statements in order through the C API of `/usr/lib/libsqlite3.dylib`, using `ctypes`. The library has the same version and source ID as the CLI. The CLI does not dynamically link that library according to `otool -L`, so this is a **separate matching-source library experiment**, not an in-process profile of the CLI or proof of identical build options.

| Blob bytes | Prepare ms/page before | Prepare ms/page after | Step ms/page before | Step ms/page after |
|---:|---:|---:|---:|---:|
| 120 | 18.178 | 19.934 | 10.821 | 11.385 |
| 4,096 | 18.963 | 16.579 | 9.910 | 9.980 |
| 16,384 | 37.388 | 19.981 | 16.985 | 19.186 |

These are medians for 100 messages, **not per-message times**. Prepare includes SQL parsing, planning, and bytecode generation; step includes execution and commit. Finalize is measured separately in `957-profile-results.jsonl`. Foreign-function call overhead is included; Python loop overhead, connection open/close, fixture setup, and SQL file reads are excluded. The changed batch has 1,505 statements versus 1,403: two singleton setup statements plus one update per message. That overhead is visible for short blobs. With 16 KiB blobs, compilation falls about 47% while execution rises modestly. Even the baseline's roughly 0.374 ms/message compilation time is small beside the adapter's roughly 31.7 ms/message; these results do not support calling repeated-literal parsing the dominant cost in this fixture.

The profiled final run was serialized after the other jobs. An earlier overlapping exploratory profile and a failed shared-library version check are excluded.

## Correctness and review

- Added three regression tests: one SQL copy and exact bytes across replay; pending-to-imported transition with an interleaved roster record and cursor-only page; changed blobs rejected against both quarantine and mappings.
- Inputs cover an 8 KiB blob, apostrophe, newline, backslash, shell-looking text, UTF-8, an empty blob, and a distinct later blob. Legacy mirror IDs and body equality are checked.
- The existing related suites pass: `test_remote_sync.bats`, `test_legacy_mirror.bats`, `test_remote_sync_driver_input.bats`, and `test_sqlite_sync_jq_binary.bats` (65 tests), plus the three new tests (68 total). Existing minimum-Bats-version warnings remain unchanged.
- Existing coverage includes transactional rollback after a failed insert, sequence conflicts, mapped echoes, roster acknowledgement, and invalid input handling.
- The real encrypted `#917` unlock scenario, 100 messages with 3,072-byte bodies, imports all 100 before and after. Single-run `unlock.reprocess` readings were 118.92 and 129.39 ms/message respectively. These are functional coverage, **not evidence of a speedup**: there was only one run per variant, and the baseline run overlapped the exploratory library profile.
- `bash -n` and `git diff --check` pass. Static review cleared the production change and new regression file; the production patch's stable patch ID is `9ab7b0a7aec5b058af46a0085840e18189b1e8c0`, and the regression file SHA-256 is `1d76fd5b56da9f61b91f2089eb7fbcfc2ec837300a39ee45577091f1e3a57012`.

## Risks and unchanged behavior

No persistent schema, wire format, cursor policy, conflict policy, or encryption logic changes. The same quoting function still escapes the blob. A TEMP row is created within the existing transaction and overwritten before every message's common SQL, including messages followed by a roster `continue`. It survives only for the apply CLI connection. Conditional legacy mirroring still inserts its message immediately before reading `last_insert_rowid()`; the earlier TEMP insert cannot replace that ID. A statement failure still stops at `-bail` before commit and rolls the page back.

The tradeoff is one extra UPDATE per message, ten scalar lookups, and TEMP storage for one blob. Short-blob compilation/step overhead can increase, and overall adapter improvement is not established by this shared-machine experiment. The change is justified as bounded repeated-input/SQL work, not as a demonstrated fix for the historical production reprocess ratio. Platform CI and a review tied to the eventual committed head are still required before landing; no commit, push, or main merge was performed during this investigation.

## Reproduce

Create a separate checkout/archive of baseline `0444bae`, then run from the changed checkout:

```sh
python3 tests/perf/apply-blob.py --baseline /path/to/baseline --out /tmp/apply-blob-run --repetitions 5
python3 tests/perf/profile-apply-sql.py --run /tmp/apply-blob-run --library /usr/lib/libsqlite3.dylib --out /tmp/apply-sql-profile --repetitions 20
bats tests/test_remote_sync_apply_blob.bats tests/test_remote_sync.bats tests/test_legacy_mirror.bats tests/test_remote_sync_driver_input.bats tests/test_sqlite_sync_jq_binary.bats
bash tests/perf/join-harness.sh --scenario unlock --messages 100 --body-bytes 3072 --out /tmp/apply-unlock-run
```

Do not run those commands concurrently when using their timings. The shared-library path is platform-specific. The original run directories are `/tmp/agmsg-957-measured`, `/tmp/agmsg-957-profile-final`, and `/tmp/agmsg-957-unlock-{before,after}`; all contain synthetic data only.
